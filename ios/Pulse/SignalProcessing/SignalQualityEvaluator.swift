import Foundation

/// Turns the per-estimator scores and the motion profile into a single, honest category.
/// All numbers here are heuristic indices in 0...1, never probabilities.
enum SignalQualityEvaluator {
    /// Per-window stability of the recording (1 = stable, 0 = strong motion), from the spread of
    /// the acceleration magnitude relative to the quietest part of the session.
    static func stabilityTimeline(
        magnitude: [Double],
        sampleRateHz: Double,
        windowSeconds: Double
    ) -> [Double] {
        let windowSamples = max(1, Int(windowSeconds * sampleRateHz))
        guard magnitude.count >= windowSamples else { return [] }

        var windowStd: [Double] = []
        var start = 0
        while start + windowSamples <= magnitude.count {
            windowStd.append(Statistics.standardDeviation(Array(magnitude[start..<start + windowSamples])))
            start += windowSamples
        }
        guard !windowStd.isEmpty else { return [] }

        // Quiet baseline = 20th percentile of window spreads.
        let sorted = windowStd.sorted()
        let baseline = max(sorted[sorted.count / 5], 1e-4)
        return windowStd.map { min(1, baseline / max($0, 1e-6)) }
    }

    static func motionArtifactFraction(_ timeline: [Double]) -> Double {
        Statistics.fraction(timeline) { $0 < 0.5 }
    }

    /// Overall verdict. Respiration is the primary deliverable, so an unreliable respiratory
    /// estimate caps the overall quality regardless of the heart result.
    static func overall(
        respiratory: RespiratoryEstimate,
        heart: HeartEstimate,
        motionArtifactFraction: Double
    ) -> (quality: MeasurementQuality, score: Double) {
        let motionScore = 1 - min(1, motionArtifactFraction)
        var score = 0.5 * respiratory.qualityScore
            + 0.2 * heart.qualityScore
            + 0.3 * motionScore
        if !respiratory.isReliable {
            // Availability and strict reliability are different decisions. A coherent RR value
            // with reduced confidence is capped at "acceptable"; absence of any defensible value
            // caps the session below "poor".
            score = respiratory.rateBPM != nil ? min(score, 0.59) : min(score, 0.29)
        }
        score = min(1, max(0, score))
        return (MeasurementQuality(score: score), score)
    }
}
