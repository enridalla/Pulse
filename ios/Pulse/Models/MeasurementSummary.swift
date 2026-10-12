import Foundation

/// Lightweight row for the Home and History lists. Stored in `index.json` so the app need not
/// open every session folder on launch.
struct MeasurementSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    let folderName: String
    let startedAt: Date
    let durationSeconds: Double
    let breathingMode: BreathingMode
    let respiratoryRateBPM: Double?
    let respiratoryReliable: Bool
    let heartRateBPM: Double?
    let overallQuality: MeasurementQuality
    let isComplete: Bool

    init(metadata: RecordingMetadata, result: MeasurementResult, folderName: String) {
        id = metadata.id
        self.folderName = folderName
        startedAt = metadata.startedAt
        durationSeconds = result.durationSeconds
        breathingMode = metadata.configuration.breathingMode
        respiratoryRateBPM = result.respiratoryEstimate.isReliable ? result.respiratoryEstimate.rateBPM : nil
        respiratoryReliable = result.respiratoryEstimate.isReliable
        heartRateBPM = result.heartEstimate.isReliable ? result.heartEstimate.rateBPM : nil
        overallQuality = result.overallQuality
        isComplete = metadata.isComplete
    }
}
