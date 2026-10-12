import Foundation

/// Everything the user chose before a measurement. Immutable and value-typed so it can be
/// carried across concurrency domains and stored verbatim in `metadata.json`.
struct MeasurementConfiguration: Codable, Sendable, Equatable {
    /// Optional free-text subject label (e.g. "S01"). Never required.
    var subjectIdentifier: String?
    var breathingMode: BreathingMode
    var plannedDurationSeconds: Double
    var notes: String?

    static let `default` = MeasurementConfiguration(
        subjectIdentifier: nil,
        breathingMode: .free,
        plannedDurationSeconds: 90,
        notes: nil
    )
}
