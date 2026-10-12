import Foundation

/// Constants for the course-aligned DSP pipeline.
///
/// The aim of v5 is to keep parameters interpretable: acquisition choices, physiological search
/// bands, window lengths, and a small number of acceptance tolerances. There is intentionally no
/// table of weighted evidence coefficients.
enum SignalProcessingParameters {
    static let algorithmVersion = "5.4.0"

    // MARK: Acquisition / sampling
    static let requestedSamplingFrequencyHz = 100.0
    static let minimumRecordingSeconds = 20.0
    static let minimumSampleCount = 200
    static let anomalousIntervalRobustSigmaFactor = 5.0
    static let anomalousIntervalRelativeFloor = 0.005
    /// Resample when the standard deviation of sample intervals exceeds 2% of their median.
    static let resamplingJitterThreshold = 0.02

    // MARK: Pre-processing
    static let trimBeginningSeconds = 5.0
    static let trimEndingSeconds = 5.0

    // MARK: Physiological bands
    static let respirationSearchBandHz = 0.1...1.5       // 6...90 breaths/min
    // Slightly wider filter passband so the search-band boundaries are not placed exactly at the
    // filter cut-offs. Frequency estimation is still restricted to 0.1...1.5 Hz.
    static let respirationFilterBandHz = 0.08...1.65
    static let heartSignalBandHz = 7.0...30.0            // cardiomechanical/SCG band
    static let minimumHeartRateBPM = 40.0
    static let maximumHeartRateBPM = 180.0

    // The production app keeps the zero-phase Butterworth implementation used throughout the
    // project. Filter theory follows the course material; the cut-offs define the physiological
    // frequency ranges used by this pipeline.
    static let respirationFilterOrder = 4
    static let heartFilterOrder = 4

    // MARK: Welch PSD
    static let welchSegmentSeconds = 30.0
    static let welchOverlapFraction = 0.5
    static let welchFrequencyGridPoints = 281

    // MARK: Respiration = PCA -> ACF, with Welch + fixed-window local persistence
    // The primary RR period is the strongest positive ACF local maximum of PC1 after
    // respiratory-band filtering. Welch is a verification/harmonic diagnostic, not a hard
    // prerequisite. Local persistence uses one fixed observation time for every candidate.
    static let respirationPeakSeparationHz = 0.05
    static let respirationDomainAgreementBPM = 2.5
    static let respirationDomainAgreementFraction = 0.08
    static let respirationAxisAgreementBPM = 2.5
    static let respirationAxisAgreementFraction = 0.08
    static let respirationHarmonicRatioTolerance = 0.08
    static let respirationMinimumObservedCycles = 3.0
    /// Small numerical guard around the declared 6...90 acts/min ACF-lag boundaries.
    static let respirationBoundaryToleranceFraction = 0.02
    // Local persistence uses one fixed observation window for every candidate so a faster
    // candidate is not rewarded simply because it generates more/shorter validation windows.
    // Thirty seconds still contains three cycles at the lower 6 acts/min search boundary.
    static let respirationLocalWindowSeconds = 30.0
    static let respirationLocalHopSeconds = 15.0
    static let respirationHeartOverlapBPM = 4.0
    static let respirationHeartOverlapFraction = 0.06
    // A high respiratory candidate close to HR/2 is a plausible cardiomechanical subharmonic.
    // Keep the numerical rate for transparency but downgrade reliability when this ambiguity exists.
    static let respirationHeartSubharmonicMinimumRateBPM = 30.0
    static let respirationHeartSubharmonicBPM = 5.0
    static let respirationHeartSubharmonicFraction = 0.08

    // MARK: Heart = template/NCC -> IBI
    // Automatic template-selection parameters. The minimum peak distance is derived from the
    // declared 40...180 bpm operating range.
    static let heartTemplateWindowSeconds = 10.0
    static let heartTemplateMinimumWindowSeconds = 8.0
    static let heartTemplateEnvelopeLowpassHz = 3.0
    static let heartTemplateEnvelopeLowpassOrder = 2
    static let heartTemplateEnvelopePeakProminence = 0.25
    static let heartTemplateMinimumPeaks = 5
    static let heartTemplateClusterMinimumCorrelation = 0.30
    static let heartTemplateMaximumIBIMeanAbsoluteDeviationSeconds = 0.335
    static let heartTemplatePreSeconds = 0.20
    static let heartTemplatePostSeconds = 0.50

    static let heartNCCMinimumCorrelation = 0.50
    static let heartNCCMinimumProminence = 0.50
    static let heartNCCMinimumPeakDistanceFractionOfMinimumIBI = 0.90
    static let heartMinimumBeatCount = 6
    static let heartMinimumTemplateCorrelation = 0.50
    static let heartMinimumValidIntervalFraction = 0.72
    static let heartMaximumIBIVariability = 0.24
    static let heartReliableQualityThreshold = 0.56

    // Two mechanical complexes inside one beat can produce a short-long interval alternation.
    // These checks operate on observed beat intervals/morphology; they do not encode a preferred HR.
    static let heartAlternatingIntervalMinimumRelativeDifference = 0.20
    static let heartAlternatingPairDispersionImprovementFactor = 0.60
    static let heartAlternatingPairMaximumRobustCV = 0.18

    // Existing midpoint diagnostic used inside the template detector. An unresolved systematic
    // midpoint pattern makes the single-axis estimate unreliable instead of forcing f or 2f.
    static let heartMidpointMinimumSupportFraction = 0.60
    static let heartMidpointCorrelationFractionOfAcceptedMedian = 0.85
    static let heartMidpointSearchFractionOfIBI = 0.16
    static let heartMidpointExpandedMaximumRobustCV = 0.18

    // MARK: Heart ACF consistency check
    /// The first ACF peak that is at least 60% of the strongest physiological-lag peak is considered
    /// a supported fundamental-period candidate. The IBI estimate still has to agree with it.
    static let heartRMSEnvelopeWindowSeconds = 0.10
    static let heartACFSignificantPeakFraction = 0.60
    static let heartACFMinimumStrength = 0.15
    static let heartACFAgreementBPM = 4.0
    static let heartACFAgreementFraction = 0.08
    static let heartACFMinimumSupportingAxes = 2
    static let heartACFLocalWindowSeconds = 15.0
    static let heartACFLocalHopSeconds = 7.5
    static let heartACFMinimumLocalAgreementFraction = 0.60
    static let heartConfirmedMinimumValidIntervalFraction = 0.80
    static let heartHarmonicRatioTolerance = 0.10
    static let heartAmbiguousUniformIntervalCV = 0.12
}
