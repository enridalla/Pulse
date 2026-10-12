import Foundation

/// Respiratory-rate estimate. `rateBPM` may be present while `isReliable == false` when several
/// independent signal-processing cues support a cautious value but the strict stability criteria
/// are not met. It is `nil` when even a reportable estimate is unsupported.
struct RespiratoryEstimate: Codable, Sendable, Equatable {
    let rateBPM: Double?
    let welchRateBPM: Double?
    let autocorrelationRateBPM: Double?
    /// Heuristic 0...1 confidence index (not a probability).
    let qualityScore: Double
    let isReliable: Bool
    let reliabilityMessage: String

    static let unreliable = RespiratoryEstimate(
        rateBPM: nil,
        welchRateBPM: nil,
        autocorrelationRateBPM: nil,
        qualityScore: 0,
        isReliable: false,
        reliabilityMessage: "reliability.respiration.unreliable"
    )
}

/// Heart-rate estimate from the cardiomechanical component. The preferred estimate comes from
/// template/NCC heartbeat localisation and IBI analysis. When beat-to-beat localisation fails its
/// own quality checks on every axis, a stable cross-axis autocorrelation period may still provide a
/// reliable *window-averaged* HR. `baselineRateBPM` retains the underlying diagnostic candidate.
struct HeartEstimate: Codable, Sendable, Equatable {
    let rateBPM: Double?
    let baselineRateBPM: Double?
    let detectedBeatCount: Int
    /// Relative variability of inter-beat intervals (coefficient of variation), for the report.
    let interBeatVariability: Double?
    /// Median normalised template-correlation of accepted beats, for the report.
    let medianTemplateCorrelation: Double?
    /// Heuristic 0...1 confidence index (not a probability).
    let qualityScore: Double
    let isReliable: Bool
    let reliabilityMessage: String

    static let unreliable = HeartEstimate(
        rateBPM: nil,
        baselineRateBPM: nil,
        detectedBeatCount: 0,
        interBeatVariability: nil,
        medianTemplateCorrelation: nil,
        qualityScore: 0,
        isReliable: false,
        reliabilityMessage: "reliability.heart.unreliable"
    )
}
