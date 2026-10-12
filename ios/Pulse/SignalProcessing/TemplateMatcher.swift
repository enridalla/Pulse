import Foundation

/// Builds a representative beat template from the signal itself (no external reference) and
/// provides the amplitude-independent matched filtering used for beat detection.
enum TemplateMatcher {
    /// Local maxima above `threshold`, thinned so that no two peaks are closer than
    /// `minDistance` samples (the taller peak wins). Returned sorted by position.
    static func findPeaks(_ signal: [Double], minDistance: Int, threshold: Double) -> [Int] {
        guard signal.count > 2, minDistance >= 1 else { return [] }
        var candidates: [(index: Int, value: Double)] = []
        for i in 1..<(signal.count - 1) {
            let v = signal[i]
            if v >= threshold && v >= signal[i - 1] && v >= signal[i + 1] {
                candidates.append((i, v))
            }
        }
        candidates.sort { $0.value > $1.value }

        var accepted: [Int] = []
        for candidate in candidates {
            if accepted.allSatisfy({ abs($0 - candidate.index) >= minDistance }) {
                accepted.append(candidate.index)
            }
        }
        return accepted.sorted()
    }

    /// Median beat template around the candidate indices. Windows that fit fully are normalised
    /// (zero mean, unit norm); a preliminary median template is used to keep only the windows
    /// that resemble it, then the final median template is returned. `nil` if there is not
    /// enough consistent material.
    static func buildTemplate(
        signal: [Double],
        candidates: [Int],
        preSamples: Int,
        postSamples: Int
    ) -> [Double]? {
        let length = preSamples + postSamples
        guard length > 3 else { return nil }

        var windows: [[Double]] = []
        for center in candidates {
            let start = center - preSamples
            let end = center + postSamples
            guard start >= 0, end <= signal.count else { continue }
            if let normalized = normalize(Array(signal[start..<end])) {
                windows.append(normalized)
            }
        }
        guard windows.count >= 3 else { return nil }

        let preliminary = elementwiseMedian(windows, length: length)
        // Keep windows most similar to the preliminary template.
        let scored = windows.map { (window: $0, similarity: Statistics.correlation($0, preliminary)) }
        let keepThreshold = max(0.3, Statistics.median(scored.map(\.similarity)))
        let kept = scored.filter { $0.similarity >= keepThreshold }.map(\.window)
        let base = kept.count >= 3 ? kept : windows

        return normalize(elementwiseMedian(base, length: length))
    }

    /// Amplitude-independent matched filter: Pearson correlation of the template against each
    /// aligned window of the signal. Output index `i` corresponds to the template starting at `i`.
    static func normalizedCrossCorrelation(signal: [Double], template: [Double]) -> [Double] {
        let n = signal.count
        let L = template.count
        guard n >= L, L > 1 else { return [Double](repeating: 0, count: n) }
        let templateMean = Statistics.mean(template)
        let centeredTemplate = template.map { $0 - templateMean }
        let templateNorm = centeredTemplate.reduce(0) { $0 + $1 * $1 }.squareRoot()

        var output = [Double](repeating: 0, count: n)
        guard templateNorm > .ulpOfOne else { return output }

        for i in 0...(n - L) {
            var mean = 0.0
            for k in 0..<L { mean += signal[i + k] }
            mean /= Double(L)
            var dot = 0.0
            var norm = 0.0
            for k in 0..<L {
                let s = signal[i + k] - mean
                dot += s * centeredTemplate[k]
                norm += s * s
            }
            let denominator = norm.squareRoot() * templateNorm
            output[i] = denominator > .ulpOfOne ? dot / denominator : 0
        }
        return output
    }

    // MARK: Helpers

    private static func normalize(_ window: [Double]) -> [Double]? {
        let mean = Statistics.mean(window)
        let centered = window.map { $0 - mean }
        let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > .ulpOfOne else { return nil }
        return centered.map { $0 / norm }
    }

    private static func elementwiseMedian(_ windows: [[Double]], length: Int) -> [Double] {
        guard !windows.isEmpty else { return [Double](repeating: 0, count: length) }
        return (0..<length).map { k in Statistics.median(windows.map { $0[k] }) }
    }
}
