import Foundation

/// Respiratory-rate estimation expressed with the same building blocks used in the course:
///
/// 1. isolate the respiratory band;
/// 2. fit PCA on the band-limited x/y/z signal;
/// 3. estimate the dominant period from the autocorrelation of PC1;
/// 4. use Welch only as a frequency-domain verification / harmonic diagnostic;
/// 5. verify that the same ACF period persists in fixed-duration local windows, so every
///    candidate is judged over the same observation time.
///
/// The implementation keeps the rate decision transparent: autocorrelation provides the primary
/// period, while Welch and local-stationarity checks are used only as consistency diagnostics.
/// No weighted evidence model is used to decide the rate.
struct RespiratoryAnalysis {
    let estimate: RespiratoryEstimate
    let selectedComponentName: String
    let filteredSignal: [Double]
    let componentScores: [String: Double]
    let peakToBandPowerRatio: Double
    let firstToSecondPeakRatio: Double
    let autocorrelationStrength: Double
    let agreementBPM: Double?
    let candidateMargin: Double
    let temporalStability: Double
    let cardiacOverlapPenalty: Double
    let runnerUpRateBPM: Double?
    let harmonicAmbiguity: Bool
    let componentSupport: Int
    let spectrum: Spectrum
}

enum RespiratoryRateEstimator {
    private struct LocalPeak {
        let frequencyHz: Double
        let value: Double
    }

    private enum SpectralSupport {
        case direct
        case harmonic
        case none

        var diagnosticScore: Double {
            switch self {
            case .direct: return 1.0
            case .harmonic: return 0.75
            case .none: return 0.0
            }
        }
    }

    private struct LocalPersistence {
        let agreeingWindows: Int
        let totalWindows: Int

        var fraction: Double {
            totalWindows > 0 ? Double(agreeingWindows) / Double(totalWindows) : 0
        }

        /// A simple majority is deliberately used instead of a tuned floating-point threshold.
        var hasMajority: Bool {
            totalWindows > 0 && agreeingWindows * 2 > totalWindows
        }

        /// Reliability is stricter than reportability: at least two windows and >= 2/3 agreement.
        var isStrong: Bool {
            totalWindows >= 2 && agreeingWindows * 3 >= totalWindows * 2
        }
    }

    private struct ComponentResult {
        let name: String
        let filtered: [Double]
        let spectrum: Spectrum
        let rateBPM: Double?
        let welchRateBPM: Double?
        let autocorrelationRateBPM: Double?
        let autocorrelationStrength: Double
        let temporalStability: Double
        let localAgreeingWindows: Int
        let localTotalWindows: Int
        let spectralSupport: SpectralSupport
        let peakToBandPowerRatio: Double
        let firstToSecondPeakRatio: Double
        let domainAgreementBPM: Double?
        let quality: Double
        let isReportable: Bool
        let isReliable: Bool
    }

    static func analyze(
        components: [SignalComponent],
        sampleRateHz: Double,
        cardiacRateBPM: Double?,
        componentsAreBandLimited: Bool = false
    ) -> RespiratoryAnalysis {
        guard sampleRateHz > 0, !components.isEmpty else { return unreliableAnalysis() }

        let filter = ButterworthBandpass(
            order: SignalProcessingParameters.respirationFilterOrder,
            lowCutoffHz: SignalProcessingParameters.respirationFilterBandHz.lowerBound,
            highCutoffHz: min(SignalProcessingParameters.respirationFilterBandHz.upperBound, 0.45 * sampleRateHz),
            sampleRateHz: sampleRateHz
        )

        // Production supplies x/y/z and PC1 computed after respiratory-band filtering. PC1 is the
        // primary spatial representation; the physical axes are kept as consistency diagnostics,
        // never as independent sensors.
        let preferred = components.filter {
            ["x", "y", "z", "PC1", "PC1-band"].contains($0.name)
        }
        let allowed = preferred.isEmpty ? components : preferred
        let standaloneInput = preferred.isEmpty && components.count == 1

        let results: [ComponentResult] = allowed.compactMap { component in
            let filtered = componentsAreBandLimited
                ? component.samples
                : filter.filtfilt(Statistics.detrendLinear(component.samples))
            return analyzeComponent(name: component.name, filtered: filtered, sampleRateHz: sampleRateHz)
        }
        guard !results.isEmpty else { return unreliableAnalysis() }

        let pca = results.first { $0.name == "PC1-band" || $0.name == "PC1" }
        let physical = results.filter { ["x", "y", "z"].contains($0.name) }

        // Prefer PC1 when it contains a reportable periodicity. If PC1 cannot support a rate,
        // fall back to the best physical-axis consensus. A single physical axis may still provide
        // a cautious value, but it is never labelled reliable without spatial support.
        let selected: ComponentResult?
        if let pca, pca.isReportable {
            selected = pca
        } else if standaloneInput {
            selected = results.first(where: \.isReportable)
        } else {
            selected = bestPhysicalConsensus(physical)
        }

        guard let representative = selected, let finalRate = representative.rateBPM else {
            let bestDiagnostic = results.max { $0.quality < $1.quality }
            return RespiratoryAnalysis(
                estimate: .unreliable,
                selectedComponentName: bestDiagnostic?.name ?? "none",
                filteredSignal: bestDiagnostic?.filtered ?? [],
                componentScores: Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.quality) }),
                peakToBandPowerRatio: bestDiagnostic?.peakToBandPowerRatio ?? 0,
                firstToSecondPeakRatio: bestDiagnostic?.firstToSecondPeakRatio ?? 0,
                autocorrelationStrength: bestDiagnostic?.autocorrelationStrength ?? 0,
                agreementBPM: bestDiagnostic?.domainAgreementBPM,
                candidateMargin: 0,
                temporalStability: bestDiagnostic?.temporalStability ?? 0,
                cardiacOverlapPenalty: 0,
                runnerUpRateBPM: nil,
                harmonicAmbiguity: false,
                componentSupport: 0,
                spectrum: bestDiagnostic?.spectrum ?? emptySpectrum()
            )
        }

        let agreeingPhysical = physical.filter {
            guard let rate = $0.rateBPM else { return false }
            return abs(rate - finalRate) <= rateToleranceBPM(finalRate)
        }
        let physicalSupport = agreeingPhysical.count

        let alternativeResults = results.filter {
            guard $0.name != representative.name, let rate = $0.rateBPM else { return false }
            return abs(rate - finalRate) > rateToleranceBPM(finalRate)
        }
        let runnerUp = alternativeResults
            .max { $0.quality < $1.quality }?
            .rateBPM

        let harmonicAmbiguity = alternativeResults.contains { alternative in
            guard let rate = alternative.rateBPM else { return false }
            return areHarmonicallyRelated(finalRate, rate)
                && alternative.isReliable
                && alternative.temporalStability >= representative.temporalStability
        }

        // Numerical RR and HR can overlap during real rapid breathing, so direct RR≈HR overlap is
        // accepted only when at least two physical axes support the respiratory period. RR≈HR/2 is
        // treated more conservatively: in chest accelerometry it is a plausible cardiomechanical
        // subharmonic, so the value may still be shown but is not labelled reliable.
        let overlapsHeart = cardiacRateBPM.map { heartRate in
            abs(heartRate - finalRate) <= max(
                SignalProcessingParameters.respirationHeartOverlapBPM,
                SignalProcessingParameters.respirationHeartOverlapFraction * max(heartRate, finalRate)
            )
        } ?? false
        let overlapsHeartSubharmonic = cardiacRateBPM.map { heartRate in
            guard finalRate >= SignalProcessingParameters.respirationHeartSubharmonicMinimumRateBPM else {
                return false
            }
            let halfHeart = heartRate / 2.0
            return abs(halfHeart - finalRate) <= max(
                SignalProcessingParameters.respirationHeartSubharmonicBPM,
                SignalProcessingParameters.respirationHeartSubharmonicFraction * max(halfHeart, finalRate)
            )
        } ?? false
        let overlapSupported = !overlapsHeart || physicalSupport >= 2

        let selectedIsPCA = representative.name == "PC1-band" || representative.name == "PC1"
        let spatiallySupported = standaloneInput || selectedIsPCA || physicalSupport >= 2
        let reliable = representative.isReliable
            && spatiallySupported
            && !harmonicAmbiguity
            && overlapSupported
            && !overlapsHeartSubharmonic
        let estimate = RespiratoryEstimate(
            rateBPM: finalRate,
            welchRateBPM: representative.welchRateBPM,
            autocorrelationRateBPM: representative.autocorrelationRateBPM,
            qualityScore: representative.quality,
            isReliable: reliable,
            reliabilityMessage: reliable
                ? "reliability.respiration.reliable"
                : "reliability.respiration.unreliable"
        )

        let secondBestQuality = results
            .filter { $0.name != representative.name }
            .map(\.quality)
            .max() ?? 0

        return RespiratoryAnalysis(
            estimate: estimate,
            selectedComponentName: representative.name,
            filteredSignal: representative.filtered,
            componentScores: Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.quality) }),
            peakToBandPowerRatio: representative.peakToBandPowerRatio,
            firstToSecondPeakRatio: representative.firstToSecondPeakRatio,
            autocorrelationStrength: representative.autocorrelationStrength,
            agreementBPM: representative.domainAgreementBPM,
            candidateMargin: max(0, representative.quality - secondBestQuality),
            temporalStability: representative.temporalStability,
            cardiacOverlapPenalty: ((overlapsHeart && !overlapSupported) || overlapsHeartSubharmonic) ? 1 : 0,
            runnerUpRateBPM: runnerUp,
            harmonicAmbiguity: harmonicAmbiguity,
            componentSupport: physicalSupport,
            spectrum: representative.spectrum
        )
    }

    // MARK: One component = ACF primary, Welch verification, fixed-window persistence

    private static func analyzeComponent(
        name: String,
        filtered: [Double],
        sampleRateHz: Double
    ) -> ComponentResult? {
        guard filtered.count >= SignalProcessingParameters.minimumSampleCount else { return nil }

        let band = SignalProcessingParameters.respirationSearchBandHz
        let grid = WelchPSD.frequencyGrid(
            minHz: band.lowerBound,
            maxHz: band.upperBound,
            points: SignalProcessingParameters.welchFrequencyGridPoints
        )
        let spectrum = WelchPSD.evaluate(
            signal: filtered,
            sampleRateHz: sampleRateHz,
            segmentSeconds: SignalProcessingParameters.welchSegmentSeconds,
            overlapFraction: SignalProcessingParameters.welchOverlapFraction,
            frequenciesHz: grid
        )

        let spectralPeaks = localSpectralPeaks(spectrum)
        let strongestSpectral = spectralPeaks.max { $0.value < $1.value }
        let secondPower = strongestSpectral.map { strongest in
            spectralPeaks
                .filter { abs($0.frequencyHz - strongest.frequencyHz) > SignalProcessingParameters.respirationPeakSeparationHz }
                .map(\.value)
                .max() ?? 0
        } ?? 0

        let acfPeaks = autocorrelationPeaks(filtered, sampleRateHz: sampleRateHz)
        guard let strongestACF = acfPeaks.max(by: { $0.value < $1.value }) else {
            return ComponentResult(
                name: name,
                filtered: filtered,
                spectrum: spectrum,
                rateBPM: nil,
                welchRateBPM: strongestSpectral.map { $0.frequencyHz * 60 },
                autocorrelationRateBPM: nil,
                autocorrelationStrength: 0,
                temporalStability: 0,
                localAgreeingWindows: 0,
                localTotalWindows: 0,
                spectralSupport: .none,
                peakToBandPowerRatio: strongestSpectral.map { peakToAveragePowerRatio(spectrum, peakPower: $0.value) } ?? 0,
                firstToSecondPeakRatio: strongestSpectral.map { $0.value / max(secondPower, .ulpOfOne) } ?? 0,
                domainAgreementBPM: nil,
                quality: 0,
                isReportable: false,
                isReliable: false
            )
        }

        let frequencyHz = strongestACF.frequencyHz
        let rateBPM = frequencyHz * 60
        let durationSeconds = Double(filtered.count) / sampleRateHz
        let observedCycles = durationSeconds * frequencyHz
        let persistence = temporalPersistence(
            filtered,
            sampleRateHz: sampleRateHz,
            targetFrequencyHz: frequencyHz
        )
        let spectralSupport = spectralVerification(
            strongestSpectralFrequencyHz: strongestSpectral?.frequencyHz,
            targetFrequencyHz: frequencyHz
        )

        // Reportability deliberately avoids a fixed ACF-amplitude threshold. The period must be a
        // positive ACF local maximum, enough cycles must be present in the recording, and that same
        // period must recur in a majority of fixed-duration local windows.
        let reportable = strongestACF.value > 0
            && observedCycles >= SignalProcessingParameters.respirationMinimumObservedCycles
            && persistence.hasMajority

        // Reliability is stricter but still binary/interpretable: persistent in >=2/3 of local
        // windows and visible in Welch either at the fundamental or at an integer harmonic.
        let reliable = reportable && persistence.isStrong && spectralSupport != .none

        let spectralDiagnostic = spectralSupport.diagnosticScore
        let quality = min(1, max(0, Statistics.mean([
            min(1, max(0, strongestACF.value)),
            persistence.fraction,
            spectralDiagnostic
        ])))

        let nearestSpectral = spectralPeaks.min {
            abs($0.frequencyHz - frequencyHz) < abs($1.frequencyHz - frequencyHz)
        }
        let domainAgreement = nearestSpectral.map { abs($0.frequencyHz - frequencyHz) * 60 }

        return ComponentResult(
            name: name,
            filtered: filtered,
            spectrum: spectrum,
            rateBPM: reportable ? rateBPM : nil,
            welchRateBPM: strongestSpectral.map { $0.frequencyHz * 60 },
            autocorrelationRateBPM: rateBPM,
            autocorrelationStrength: strongestACF.value,
            temporalStability: persistence.fraction,
            localAgreeingWindows: persistence.agreeingWindows,
            localTotalWindows: persistence.totalWindows,
            spectralSupport: spectralSupport,
            peakToBandPowerRatio: strongestSpectral.map { peakToAveragePowerRatio(spectrum, peakPower: $0.value) } ?? 0,
            firstToSecondPeakRatio: strongestSpectral.map { $0.value / max(secondPower, .ulpOfOne) } ?? 0,
            domainAgreementBPM: domainAgreement,
            quality: quality,
            isReportable: reportable,
            isReliable: reliable
        )
    }

    // MARK: Autocorrelation

    private static func autocorrelationPeaks(_ raw: [Double], sampleRateHz: Double) -> [LocalPeak] {
        let signal = Statistics.removeMean(raw)
        guard signal.count > 4 else { return [] }
        let energy = signal.reduce(0) { $0 + $1 * $1 }
        guard energy > .ulpOfOne else { return [] }

        let band = SignalProcessingParameters.respirationSearchBandHz
        // Expand the integer lag interval by one sample on each side. This lets exact boundary
        // frequencies (6 and 90 acts/min at 100 Hz) be true interior local maxima instead of being
        // accepted/rejected simply because of array-boundary handling.
        let boundaryTolerance = SignalProcessingParameters.respirationBoundaryToleranceFraction
        let expandedUpperHz = band.upperBound * (1 + boundaryTolerance)
        let expandedLowerHz = band.lowerBound * (1 - boundaryTolerance)
        let minLag = max(1, Int(floor(sampleRateHz / expandedUpperHz)) - 1)
        let maxLag = min(signal.count - 2, Int(ceil(sampleRateHz / expandedLowerHz)) + 1)
        guard minLag + 2 < maxLag else { return [] }

        var values = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag where lag > 0 && lag < signal.count {
            values[lag] = Autocorrelation.value(signal, lag: lag, zeroLagEnergy: energy)
        }

        var peaks: [LocalPeak] = []
        for lag in (minLag + 1)..<maxLag {
            let value = values[lag]
            guard value > 0,
                  value >= values[lag - 1],
                  value >= values[lag + 1] else { continue }

            var refinedLag = Double(lag)
            let denominator = values[lag - 1] - 2 * value + values[lag + 1]
            if abs(denominator) > .ulpOfOne {
                refinedLag += 0.5 * (values[lag - 1] - values[lag + 1]) / denominator
            }
            guard refinedLag > 0 else { continue }
            let refinedFrequency = sampleRateHz / refinedLag
            let integerLagFrequency = sampleRateHz / Double(lag)
            let expandedBand = (band.lowerBound * (1 - boundaryTolerance))...(band.upperBound * (1 + boundaryTolerance))
            let candidateFrequency: Double
            if expandedBand.contains(refinedFrequency) {
                candidateFrequency = refinedFrequency
            } else if expandedBand.contains(integerLagFrequency) {
                candidateFrequency = integerLagFrequency
            } else {
                continue
            }
            // The search is expanded only to avoid a numerical cliff at 6/90 acts/min. The reported
            // value remains inside the declared physiological search interval.
            let frequency = min(band.upperBound, max(band.lowerBound, candidateFrequency))
            peaks.append(LocalPeak(
                frequencyHz: frequency,
                value: min(1, max(0, value))
            ))
        }
        return peaks
    }

    private static func temporalPersistence(
        _ signal: [Double],
        sampleRateHz: Double,
        targetFrequencyHz: Double
    ) -> LocalPersistence {
        guard targetFrequencyHz > 0 else {
            return LocalPersistence(agreeingWindows: 0, totalWindows: 0)
        }

        let window = min(
            signal.count,
            max(8, Int((SignalProcessingParameters.respirationLocalWindowSeconds * sampleRateHz).rounded()))
        )
        guard window >= 8 else {
            return LocalPersistence(agreeingWindows: 0, totalWindows: 0)
        }

        let hop = max(1, Int((SignalProcessingParameters.respirationLocalHopSeconds * sampleRateHz).rounded()))
        var total = 0
        var agreeing = 0
        var start = 0
        while start + window <= signal.count {
            total += 1
            let slice = Array(signal[start..<(start + window)])
            let peaks = autocorrelationPeaks(slice, sampleRateHz: sampleRateHz)
            let tolerance = frequencyToleranceHz(targetFrequencyHz)
            if peaks.contains(where: { abs($0.frequencyHz - targetFrequencyHz) <= tolerance }) {
                agreeing += 1
            }
            start += hop
        }

        // If the recording is only just long enough for one fixed-duration window, analyse that
        // window once rather than returning zero support. `isStrong` still requires >=2 windows.
        if total == 0, signal.count >= window {
            total = 1
            let peaks = autocorrelationPeaks(signal, sampleRateHz: sampleRateHz)
            let tolerance = frequencyToleranceHz(targetFrequencyHz)
            if peaks.contains(where: { abs($0.frequencyHz - targetFrequencyHz) <= tolerance }) {
                agreeing = 1
            }
        }

        return LocalPersistence(agreeingWindows: agreeing, totalWindows: total)
    }

    // MARK: Welch verification

    private static func localSpectralPeaks(_ spectrum: Spectrum) -> [LocalPeak] {
        guard !spectrum.power.isEmpty else { return [] }
        if spectrum.power.count == 1 {
            return [LocalPeak(frequencyHz: spectrum.frequenciesHz[0], value: spectrum.power[0])]
        }

        var peaks: [LocalPeak] = []
        for index in spectrum.power.indices {
            let value = spectrum.power[index]
            let left = index > 0 ? spectrum.power[index - 1] : -Double.infinity
            let right = index + 1 < spectrum.power.count ? spectrum.power[index + 1] : -Double.infinity
            if value >= left, value >= right {
                peaks.append(LocalPeak(frequencyHz: spectrum.frequenciesHz[index], value: value))
            }
        }
        return peaks
    }

    private static func spectralVerification(
        strongestSpectralFrequencyHz: Double?,
        targetFrequencyHz: Double
    ) -> SpectralSupport {
        guard let spectral = strongestSpectralFrequencyHz, targetFrequencyHz > 0 else { return .none }
        let tolerance = frequencyToleranceHz(targetFrequencyHz)
        if abs(spectral - targetFrequencyHz) <= tolerance {
            return .direct
        }

        // A non-sinusoidal respiratory waveform may have a stronger second/third harmonic than its
        // fundamental. Welch is therefore a verification, not the primary RR estimator.
        for harmonic in [2.0, 3.0] {
            let expected = harmonic * targetFrequencyHz
            let harmonicTolerance = max(tolerance, frequencyToleranceHz(expected))
            if SignalProcessingParameters.respirationSearchBandHz.contains(expected),
               abs(spectral - expected) <= harmonicTolerance {
                return .harmonic
            }
        }
        return .none
    }

    private static func peakToAveragePowerRatio(_ spectrum: Spectrum, peakPower: Double) -> Double {
        let meanPower = Statistics.mean(spectrum.power)
        return peakPower / max(meanPower, .ulpOfOne)
    }

    // MARK: Tri-axial consistency

    private static func bestPhysicalConsensus(_ physical: [ComponentResult]) -> ComponentResult? {
        let reportable = physical.filter(\.isReportable)
        guard !reportable.isEmpty else { return nil }

        var best: ComponentResult?
        var bestSupport = 0
        for candidate in reportable {
            guard let rate = candidate.rateBPM else { continue }
            let support = reportable.filter {
                guard let otherRate = $0.rateBPM else { return false }
                return abs(otherRate - rate) <= rateToleranceBPM(rate)
            }.count
            if support > bestSupport || (support == bestSupport && candidate.quality > (best?.quality ?? -1)) {
                best = candidate
                bestSupport = support
            }
        }
        return best
    }

    // MARK: Helpers

    private static func frequencyToleranceHz(_ frequencyHz: Double) -> Double {
        max(
            SignalProcessingParameters.respirationDomainAgreementBPM / 60.0,
            SignalProcessingParameters.respirationDomainAgreementFraction * frequencyHz
        )
    }

    private static func rateToleranceBPM(_ rateBPM: Double) -> Double {
        max(
            SignalProcessingParameters.respirationAxisAgreementBPM,
            SignalProcessingParameters.respirationAxisAgreementFraction * rateBPM
        )
    }

    private static func areHarmonicallyRelated(_ lhsBPM: Double, _ rhsBPM: Double) -> Bool {
        let low = min(lhsBPM, rhsBPM)
        let high = max(lhsBPM, rhsBPM)
        guard low > 0 else { return false }
        return abs(high / low - 2.0) <= SignalProcessingParameters.respirationHarmonicRatioTolerance
    }

    private static func emptySpectrum() -> Spectrum {
        Spectrum(frequenciesHz: [], power: [])
    }

    private static func unreliableAnalysis() -> RespiratoryAnalysis {
        RespiratoryAnalysis(
            estimate: .unreliable,
            selectedComponentName: "none",
            filteredSignal: [],
            componentScores: [:],
            peakToBandPowerRatio: 0,
            firstToSecondPeakRatio: 0,
            autocorrelationStrength: 0,
            agreementBPM: nil,
            candidateMargin: 0,
            temporalStability: 0,
            cardiacOverlapPenalty: 0,
            runnerUpRateBPM: nil,
            harmonicAmbiguity: false,
            componentSupport: 0,
            spectrum: emptySpectrum()
        )
    }
}
