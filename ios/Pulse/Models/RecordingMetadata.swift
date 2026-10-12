import Foundation

/// Acquisition-time metadata for one session, written as `metadata.json` as soon as the
/// recording stops (before processing). Kept separate from `MeasurementResult` so an
/// interrupted session still has a durable record.
struct RecordingMetadata: Codable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let plannedDurationSeconds: Double
    let actualDurationSeconds: Double
    let requestedSamplingFrequencyHz: Double
    let sampleCount: Int
    /// `false` if the user (or the system) stopped the recording before the planned end.
    let isComplete: Bool
    let configuration: MeasurementConfiguration
    let deviceModel: String
    let systemVersion: String
    let appVersion: String
    /// Schema version, so future changes can migrate old files.
    var metadataVersion: Int = 1
}
