import Foundation

/// Trimming and detrending. Kept deliberately tiny — each step is applied exactly once by the
/// processor, in order, so the same signal is never filtered twice by accident.
enum SignalPreprocessor {
    /// Index range that remains after removing the first/last seconds. Throws if what is left is
    /// shorter than the minimum usable recording.
    static func usableRange(
        sampleCount: Int,
        sampleRateHz: Double,
        trimBeginningSeconds: Double,
        trimEndingSeconds: Double
    ) throws -> Range<Int> {
        let start = Int((trimBeginningSeconds * sampleRateHz).rounded())
        let end = sampleCount - Int((trimEndingSeconds * sampleRateHz).rounded())
        let minSamples = Int(SignalProcessingParameters.minimumRecordingSeconds * sampleRateHz)
        guard start >= 0, end > start, (end - start) >= minSamples else {
            throw MeasurementError.recordingTooShort
        }
        return start..<end
    }

    static func detrend(_ signal: [Double]) -> [Double] {
        Statistics.detrendLinear(signal)
    }
}
