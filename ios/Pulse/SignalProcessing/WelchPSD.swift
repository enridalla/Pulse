import Foundation

/// A power spectrum sampled on an explicit frequency grid.
struct Spectrum: Equatable {
    let frequenciesHz: [Double]
    let power: [Double]

    /// Index and interpolated frequency of the strongest bin inside `[range]` (Hz).
    /// Uses local parabolic interpolation to refine the peak between grid points.
    func peak(in range: ClosedRange<Double>) -> (frequencyHz: Double, power: Double)? {
        var bestIndex = -1
        var bestPower = -Double.infinity
        for (i, f) in frequenciesHz.enumerated() where range.contains(f) {
            if power[i] > bestPower {
                bestPower = power[i]
                bestIndex = i
            }
        }
        guard bestIndex >= 0 else { return nil }

        // Parabolic interpolation around the peak (needs both neighbours).
        if bestIndex > 0, bestIndex < power.count - 1 {
            let yl = power[bestIndex - 1]
            let yc = power[bestIndex]
            let yr = power[bestIndex + 1]
            let denominator = (yl - 2 * yc + yr)
            if abs(denominator) > .ulpOfOne {
                let delta = 0.5 * (yl - yr) / denominator
                let step = frequenciesHz[bestIndex] - frequenciesHz[bestIndex - 1]
                let refined = frequenciesHz[bestIndex] + delta * step
                return (refined, yc)
            }
        }
        return (frequenciesHz[bestIndex], bestPower)
    }

    /// Power of the second-highest, well-separated local maximum in `[range]`.
    func secondPeakPower(in range: ClosedRange<Double>, separationHz: Double) -> Double {
        guard let main = peak(in: range) else { return 0 }
        var best = 0.0
        for (i, f) in frequenciesHz.enumerated() where range.contains(f) {
            if abs(f - main.frequencyHz) < separationHz { continue }
            best = max(best, power[i])
        }
        return best
    }

    /// Approximate integral of the PSD inside `[range]` using the trapezoidal rule.
    /// This is a power estimate (PSD x Hz), not a raw sum of spectral samples.
    func bandPower(in range: ClosedRange<Double>) -> Double {
        let indices = frequenciesHz.indices.filter { range.contains(frequenciesHz[$0]) }
        guard indices.count >= 2 else { return 0 }
        var total = 0.0
        for pair in zip(indices.dropFirst(), indices) {
            let right = pair.0
            let left = pair.1
            let df = frequenciesHz[right] - frequenciesHz[left]
            total += 0.5 * (power[left] + power[right]) * df
        }
        return total
    }
}

/// Welch's averaged periodogram.
///
/// The signal is split into overlapping segments; each segment is mean-removed, Hann-windowed
/// and its periodogram is evaluated **directly** on the requested frequency grid (a band-limited
/// discrete Fourier transform). The periodograms are then averaged. Evaluating on a fine grid
/// interpolates the spectrum for a smoother display — it does not add physical resolution, which
/// is set by the segment length.
enum WelchPSD {
    static func evaluate(
        signal: [Double],
        sampleRateHz: Double,
        segmentSeconds: Double,
        overlapFraction: Double,
        frequenciesHz: [Double]
    ) -> Spectrum {
        let n = signal.count
        guard n > 1, sampleRateHz > 0, !frequenciesHz.isEmpty else {
            return Spectrum(frequenciesHz: frequenciesHz, power: [Double](repeating: 0, count: frequenciesHz.count))
        }

        let requestedSegment = Int((segmentSeconds * sampleRateHz).rounded())
        let segmentLength = max(8, min(requestedSegment, n))
        let step = max(1, Int(Double(segmentLength) * (1 - overlapFraction)))

        var starts: [Int] = []
        var start = 0
        while start + segmentLength <= n {
            starts.append(start)
            start += step
        }
        if starts.isEmpty { starts = [0] }

        let window = hannWindow(length: segmentLength)
        let windowPower = window.reduce(0) { $0 + $1 * $1 }
        let scale = 1.0 / (sampleRateHz * max(windowPower, .ulpOfOne))

        var accumulated = [Double](repeating: 0, count: frequenciesHz.count)
        for segmentStart in starts {
            let end = min(segmentStart + segmentLength, n)
            var segment = Array(signal[segmentStart..<end])
            if segment.count < segmentLength {
                segment.append(contentsOf: [Double](repeating: 0, count: segmentLength - segment.count))
            }
            let mean = Statistics.mean(Array(segment[0..<min(segment.count, end - segmentStart)]))
            var windowed = [Double](repeating: 0, count: segmentLength)
            for i in 0..<segmentLength {
                windowed[i] = (segment[i] - mean) * window[i]
            }
            let periodogram = bandLimitedPeriodogram(
                windowed,
                sampleRateHz: sampleRateHz,
                frequenciesHz: frequenciesHz,
                scale: scale
            )
            for i in 0..<accumulated.count { accumulated[i] += periodogram[i] }
        }

        let inverseCount = 1.0 / Double(starts.count)
        return Spectrum(
            frequenciesHz: frequenciesHz,
            power: accumulated.map { $0 * inverseCount }
        )
    }

    /// Even linear grid of `points` frequencies over `[minHz, maxHz]`.
    static func frequencyGrid(minHz: Double, maxHz: Double, points: Int) -> [Double] {
        guard points > 1 else { return [minHz] }
        let stepHz = (maxHz - minHz) / Double(points - 1)
        return (0..<points).map { minHz + Double($0) * stepHz }
    }

    static func hannWindow(length: Int) -> [Double] {
        guard length > 1 else { return [Double](repeating: 1, count: max(length, 0)) }
        return (0..<length).map { 0.5 * (1 - cos(2 * .pi * Double($0) / Double(length - 1))) }
    }

    private static func bandLimitedPeriodogram(
        _ windowed: [Double],
        sampleRateHz: Double,
        frequenciesHz: [Double],
        scale: Double
    ) -> [Double] {
        let n = windowed.count
        var result = [Double](repeating: 0, count: frequenciesHz.count)
        for (k, f) in frequenciesHz.enumerated() {
            let omega = 2 * .pi * f / sampleRateHz
            var real = 0.0
            var imaginary = 0.0
            for i in 0..<n {
                let angle = omega * Double(i)
                real += windowed[i] * cos(angle)
                imaginary -= windowed[i] * sin(angle)
            }
            // Positive-frequency, one-sided PSD. The requested grids used by this project are
            // strictly above 0 Hz and below Nyquist, so the negative-frequency contribution is
            // represented by the standard factor two.
            result[k] = 2.0 * (real * real + imaginary * imaginary) * scale
        }
        return result
    }
}
