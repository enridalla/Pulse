import Foundation

/// Objective description of how regular the sampling actually was. Derived only from the
/// per-sample timestamps, never assumed to be exactly the requested rate.
struct SamplingDiagnostics: Codable, Sendable, Equatable {
    let estimatedSamplingFrequencyHz: Double
    let medianIntervalSeconds: Double
    let meanIntervalSeconds: Double
    let standardDeviationIntervalSeconds: Double
    let minimumIntervalSeconds: Double
    let maximumIntervalSeconds: Double
    let duplicateTimestampCount: Int
    let nonIncreasingTimestampCount: Int
    let anomalousIntervalCount: Int
    /// Whether the signal was resampled onto a uniform grid before analysis.
    let wasResampled: Bool
}
