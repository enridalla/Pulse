import Foundation

/// The full outcome of processing one recording. Persisted verbatim as `result.json`.
struct MeasurementResult: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Double
    let configuration: MeasurementConfiguration
    let samplingDiagnostics: SamplingDiagnostics
    let respiratoryEstimate: RespiratoryEstimate
    let heartEstimate: HeartEstimate
    let overallQuality: MeasurementQuality
    let excludedBeginningSeconds: Double
    let excludedEndingSeconds: Double
    /// Extra numbers surfaced only in the "Technical details" section.
    let technical: TechnicalReport
    /// Small, display-only signal snippets (downsampled) so the detail view need not re-read the CSV.
    let preview: SignalPreview
    let algorithmVersion: String
    let appVersion: String
    let rawCSVFileName: String
    let metadataFileName: String

    /// Signed error (estimate − target) for guided sessions, in breaths/min.
    var respiratoryErrorBPM: Double? {
        guard respiratoryEstimate.isReliable,
              let target = configuration.breathingMode.targetBreathsPerMinute,
              let estimate = respiratoryEstimate.rateBPM else { return nil }
        return estimate - target
    }
}

/// Numbers that matter for scientific transparency but should not dominate the consumer UI.
struct TechnicalReport: Codable, Sendable, Equatable {
    let selectedRespiratoryComponent: String
    let selectedHeartComponent: String
    let respiratoryComponentScores: [String: Double]
    let principalComponentWeights: [Double]
    let respiratoryPeakToBandPowerRatio: Double
    let respiratoryFirstToSecondPeakRatio: Double
    let respiratoryAutocorrelationPeak: Double
    let welchAutocorrelationAgreementBPM: Double?
    /// Difference in score between the winning respiratory hypothesis and its closest rival.
    let respiratoryCandidateMargin: Double?
    /// Agreement of the selected respiratory frequency across overlapping time windows (0...1).
    let respiratoryTemporalStability: Double?
    /// Penalty applied when a rapid respiratory candidate overlaps a reliable cardiac rate (0...1).
    let respiratoryCardiacOverlapPenalty: Double?
    let heartValidIntervalFraction: Double
    let motionArtifactFraction: Double
}

/// Downsampled, display-only excerpts of the processed signal.
struct SignalPreview: Codable, Sendable, Equatable {
    /// Band-pass filtered respiration waveform (normalised), for the main consumer chart.
    let respirationWaveform: [Double]
    let respirationSampleRateHz: Double
    /// Heart-band preview with detected beat markers. New recordings cover the complete analysed
    /// interval so its time axis matches respiration. The historical property names are retained
    /// to keep previously persisted JSON files decodable.
    let heartWindowWaveform: [Double]
    let heartWindowSampleRateHz: Double
    let heartWindowStartSeconds: Double
    let heartBeatOffsetsSeconds: [Double]
    /// Per-window stability score in 0...1 across the whole session (1 = stable).
    let qualityTimeline: [Double]
    let qualityWindowSeconds: Double

    static let empty = SignalPreview(
        respirationWaveform: [],
        respirationSampleRateHz: 0,
        heartWindowWaveform: [],
        heartWindowSampleRateHz: 0,
        heartWindowStartSeconds: 0,
        heartBeatOffsetsSeconds: [],
        qualityTimeline: [],
        qualityWindowSeconds: 0
    )
}
