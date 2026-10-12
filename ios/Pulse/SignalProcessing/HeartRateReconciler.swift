import Foundation

/// Course-aligned consistency check for the beat-to-beat template detector.
///
/// Primary estimate:
///     template -> NCC peaks -> IBI -> HR
///
/// Independent *methodological view of the same signal*:
///     cardiomechanical energy envelope -> autocorrelation -> dominant period
///
/// The autocorrelation is not another sensor and is never averaged into a large evidence score.
/// It has only two roles:
/// 1. confirm that the IBI-derived rate is compatible with the global periodicity;
/// 2. expose f-vs-2f ambiguity. When the two views are harmonically inconsistent and no physical
///    axis gives a direct agreement, the estimator abstains instead of forcing one interpretation.
enum HeartRateReconciler {
    struct Selection {
        let name: String
        let analysis: HeartAnalysis
        let periodicityRateBPM: Double?
        let periodicitySupportedAxes: Int
        let harmonicResolution: String
    }

    private struct AxisPeriodicity {
        let name: String
        let rateBPM: Double
        let strength: Double
        /// Fraction of overlapping local windows whose ACF period agrees with the full-recording period.
        /// This is a direct stationarity/persistence check, not a weighted confidence score.
        let localAgreementFraction: Double
        let localWindowCount: Int
    }

    private struct PeriodicityCluster {
        var axes: [AxisPeriodicity]
        var centerBPM: Double { Statistics.median(axes.map(\.rateBPM)) }
        var meanStrength: Double { Statistics.mean(axes.map(\.strength)) }
        var meanLocalAgreement: Double { Statistics.mean(axes.map(\.localAgreementFraction)) }
    }

    static func select(
        analyses: [(name: String, analysis: HeartAnalysis)],
        filteredPhysicalComponents: [SignalComponent],
        sampleRateHz: Double
    ) -> Selection {
        let templateDefault = HeartRateEstimator.selectBestPhysicalAxis(analyses)
        let periodicities = filteredPhysicalComponents.compactMap {
            axisPeriodicity(name: $0.name, filtered: $0.samples, sampleRateHz: sampleRateHz)
        }
        guard !periodicities.isEmpty else {
            return Selection(
                name: templateDefault.name,
                analysis: templateDefault.analysis,
                periodicityRateBPM: nil,
                periodicitySupportedAxes: 0,
                harmonicResolution: "no-acf"
            )
        }

        // ACF periodicity is also checked locally. This follows the course discussion of local
        // stationarity: a full-recording ACF peak is not enough if that period disappears across
        // shorter windows. The local check is deliberately binary/transparent, not a weighted score.
        let stablePeriodicities = periodicities.filter {
            $0.localWindowCount > 0
                && $0.localAgreementFraction >= SignalProcessingParameters.heartACFMinimumLocalAgreementFraction
        }

        struct SupportedTemplate {
            let name: String
            let analysis: HeartAnalysis
            let rateBPM: Double
            let supportingAxes: [AxisPeriodicity]
        }

        // Primary path: the template/NCC detector gives an IBI-derived HR and ACF asks whether the
        // same global period is visible in the physical accelerometer axes. A reliable template
        // does not need ACF to generate its beat times; ACF is only a consistency check.
        let supported: [SupportedTemplate] = analyses.compactMap { item in
            guard let rate = item.analysis.estimate.baselineRateBPM else { return nil }
            let axes = periodicities.filter { ratesAgree(rate, $0.rateBPM) }
            guard !axes.isEmpty else { return nil }
            return SupportedTemplate(name: item.name, analysis: item.analysis, rateBPM: rate, supportingAxes: axes)
        }.sorted { left, right in
            if left.supportingAxes.count != right.supportingAxes.count {
                return left.supportingAxes.count > right.supportingAxes.count
            }
            if left.analysis.estimate.isReliable != right.analysis.estimate.isReliable {
                return left.analysis.estimate.isReliable && !right.analysis.estimate.isReliable
            }
            if abs(left.analysis.validIntervalFraction - right.analysis.validIntervalFraction) > 1e-9 {
                return left.analysis.validIntervalFraction > right.analysis.validIntervalFraction
            }
            let lc = left.analysis.estimate.medianTemplateCorrelation ?? 0
            let rc = right.analysis.estimate.medianTemplateCorrelation ?? 0
            if abs(lc - rc) > 1e-9 { return lc > rc }
            return (left.analysis.estimate.interBeatVariability ?? .infinity)
                < (right.analysis.estimate.interBeatVariability ?? .infinity)
        }

        if let chosen = supported.first {
            let meanStrength = Statistics.mean(chosen.supportingAxes.map(\.strength))
            let meanRate = Statistics.median(chosen.supportingAxes.map(\.rateBPM))

            // If a high-rate sequence is perfectly regular but alternates between two clearly
            // different morphologies, the accelerometer alone cannot decide whether these are
            // consecutive beats or two complexes of one lower-rate cardiac cycle.
            if chosen.rateBPM / 2.0 >= SignalProcessingParameters.minimumHeartRateBPM,
               let component = filteredPhysicalComponents.first(where: { $0.name == chosen.name }),
               alternatingMorphologyAmbiguity(
                    signal: component.samples,
                    beatTimes: chosen.analysis.beatTimesSeconds,
                    sampleRateHz: sampleRateHz
               ) {
                return Selection(
                    name: chosen.name,
                    analysis: cautiousCopy(of: chosen.analysis),
                    periodicityRateBPM: meanRate,
                    periodicitySupportedAxes: chosen.supportingAxes.count,
                    harmonicResolution: "alternating-morphology-ambiguity"
                )
            }

            let analysis = confirmedAnalysis(
                chosen.analysis,
                rateBPM: chosen.rateBPM,
                autocorrelationStrength: meanStrength,
                supportingAxes: chosen.supportingAxes.count
            )
            return Selection(
                name: chosen.name,
                analysis: analysis,
                periodicityRateBPM: meanRate,
                periodicitySupportedAxes: chosen.supportingAxes.count,
                harmonicResolution: "ibi-acf-agreement"
            )
        }

        let acfClusters = buildClusters(stablePeriodicities).sorted {
            if $0.axes.count != $1.axes.count { return $0.axes.count > $1.axes.count }
            if abs($0.meanLocalAgreement - $1.meanLocalAgreement) > 1e-9 {
                return $0.meanLocalAgreement > $1.meanLocalAgreement
            }
            return $0.meanStrength > $1.meanStrength
        }
        let bestStableACF = acfClusters.first

        // Secondary path: if beat-to-beat localisation fails its own quality criteria on *every*
        // physical axis, do not keep publishing that failed template rate. A window-averaged HR may
        // still be estimated from autocorrelation when the same period is present on at least two
        // axes and persists across overlapping local windows. This uses only autocorrelation and
        // local stationarity, without introducing a second beat detector.
        let hasReliableTemplate = analyses.contains { $0.analysis.estimate.isReliable }
        if !hasReliableTemplate,
           let acf = bestStableACF,
           acf.axes.count >= SignalProcessingParameters.heartACFMinimumSupportingAxes,
           acf.meanStrength >= SignalProcessingParameters.heartACFMinimumStrength,
           acf.meanLocalAgreement >= SignalProcessingParameters.heartACFMinimumLocalAgreementFraction {
            let representativeAxis = acf.axes.max {
                ($0.strength * $0.localAgreementFraction) < ($1.strength * $1.localAgreementFraction)
            }?.name ?? templateDefault.name
            let base = analyses.first(where: { $0.name == representativeAxis })?.analysis ?? templateDefault.analysis
            return Selection(
                name: representativeAxis,
                analysis: periodicityOnlyAnalysis(
                    base: base,
                    rateBPM: acf.centerBPM,
                    autocorrelationStrength: acf.meanStrength,
                    localAgreement: acf.meanLocalAgreement
                ),
                periodicityRateBPM: acf.centerBPM,
                periodicitySupportedAxes: acf.axes.count,
                harmonicResolution: "windowed-acf-average-rate"
            )
        }

        // If a reliable template and a stable ACF disagree by a factor of two, the data do not
        // identify f versus 2f robustly enough: abstain instead of hard-coding a preferred range.
        if let templateRate = templateDefault.analysis.estimate.baselineRateBPM,
           let acf = bestStableACF,
           areHarmonicallyRelated(templateRate, acf.centerBPM) {
            return Selection(
                name: templateDefault.name,
                analysis: cautiousCopy(of: templateDefault.analysis),
                periodicityRateBPM: acf.centerBPM,
                periodicitySupportedAxes: acf.axes.count,
                harmonicResolution: "harmonic-ambiguity"
            )
        }

        // Important semantic correction from v5.1: a failed consistency check must not leave a
        // reportable HR in `rateBPM`. The rejected candidate remains only in `baselineRateBPM` for
        // diagnostics. This prevents the UI from showing a numerically plausible but unsupported HR.
        if templateDefault.analysis.estimate.baselineRateBPM != nil {
            return Selection(
                name: templateDefault.name,
                analysis: cautiousCopy(of: templateDefault.analysis),
                periodicityRateBPM: bestStableACF?.centerBPM,
                periodicitySupportedAxes: bestStableACF?.axes.count ?? 0,
                harmonicResolution: "disagreement"
            )
        }

        return Selection(
            name: templateDefault.name,
            analysis: templateDefault.analysis,
            periodicityRateBPM: bestStableACF?.centerBPM,
            periodicitySupportedAxes: bestStableACF?.axes.count ?? 0,
            harmonicResolution: "no-template-rate"
        )
    }

    private static func alternatingMorphologyAmbiguity(
        signal: [Double], beatTimes: [Double], sampleRateHz: Double
    ) -> Bool {
        guard beatTimes.count >= 8 else { return false }
        let beatSamples = beatTimes.map { Int(($0 * sampleRateHz).rounded()) }
        let intervals = zip(beatSamples.dropFirst(), beatSamples).map {
            Double($0.0 - $0.1) / sampleRateHz
        }
        guard !intervals.isEmpty else { return false }
        let center = Statistics.median(intervals)
        guard center > 0 else { return false }
        let intervalCV = Statistics.medianAbsoluteDeviation(intervals) / center
        guard intervalCV <= SignalProcessingParameters.heartAmbiguousUniformIntervalCV else { return false }

        let pre = max(1, Int((0.06 * sampleRateHz).rounded()))
        let post = max(2, Int((0.16 * sampleRateHz).rounded()))
        var even: [[Double]] = [], odd: [[Double]] = []
        for (index, beat) in beatSamples.enumerated() {
            let lower = beat - pre, upper = beat + post
            guard lower >= 0, upper < signal.count else { continue }
            let raw = Array(signal[lower...upper])
            let mean = Statistics.mean(raw)
            let centered = raw.map { $0 - mean }
            let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm > .ulpOfOne else { continue }
            let unit = centered.map { $0 / norm }
            if index.isMultiple(of: 2) { even.append(unit) } else { odd.append(unit) }
        }
        guard even.count >= 3, odd.count >= 3 else { return false }

        func within(_ windows: [[Double]]) -> Double {
            var values: [Double] = []
            for i in 0..<windows.count {
                for j in (i + 1)..<windows.count {
                    values.append(Statistics.correlation(windows[i], windows[j]))
                }
            }
            return values.isEmpty ? 0 : Statistics.median(values)
        }
        let evenWithin = within(even), oddWithin = within(odd)
        var cross: [Double] = []
        for e in even { for o in odd { cross.append(Statistics.correlation(e, o)) } }
        let crossMedian = cross.isEmpty ? 0 : Statistics.median(cross)
        return evenWithin >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && oddWithin >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && crossMedian < min(evenWithin, oddWithin)
    }

    // MARK: ACF periodicity

    private static func axisPeriodicity(
        name: String,
        filtered: [Double],
        sampleRateHz: Double
    ) -> AxisPeriodicity? {
        guard !filtered.isEmpty, sampleRateHz > 0 else { return nil }

        // Local RMS envelope describes the intensity of the 7...30 Hz cardiomechanical activity
        // without imposing a preferred HR. The period itself is obtained only from ACF.
        let windowSamples = max(
            1,
            Int((SignalProcessingParameters.heartRMSEnvelopeWindowSeconds * sampleRateHz).rounded())
        )
        var squaredPrefix = [Double](repeating: 0, count: filtered.count + 1)
        for index in filtered.indices {
            squaredPrefix[index + 1] = squaredPrefix[index] + filtered[index] * filtered[index]
        }
        let half = windowSamples / 2
        var rms = [Double](repeating: 0, count: filtered.count)
        for index in filtered.indices {
            let lower = max(0, index - half)
            let upper = min(filtered.count, lower + windowSamples)
            let count = max(1, upper - lower)
            let meanSquare = (squaredPrefix[upper] - squaredPrefix[lower]) / Double(count)
            rms[index] = max(0, meanSquare).squareRoot()
        }
        let envelope = Statistics.removeMean(rms)

        func estimateACFPeriod(_ values: [Double]) -> (rateBPM: Double, strength: Double)? {
            guard values.count >= SignalProcessingParameters.minimumSampleCount else { return nil }
            let centered = Statistics.removeMean(values)
            let energy = centered.reduce(0) { $0 + $1 * $1 }
            guard energy > .ulpOfOne else { return nil }

            let minLag = max(
                1,
                Int((60.0 * sampleRateHz / SignalProcessingParameters.maximumHeartRateBPM).rounded())
            )
            let maxLag = min(
                centered.count - 2,
                Int((60.0 * sampleRateHz / SignalProcessingParameters.minimumHeartRateBPM).rounded())
            )
            guard minLag < maxLag else { return nil }

            var acf = [Double](repeating: 0, count: maxLag + 2)
            for lag in max(1, minLag - 1)...min(centered.count - 1, maxLag + 1) {
                acf[lag] = Autocorrelation.value(centered, lag: lag, zeroLagEnergy: energy)
            }

            var peaks: [(lag: Int, strength: Double)] = []
            for lag in minLag...maxLag {
                let c = acf[lag]
                if c > 0, c >= acf[lag - 1], c >= acf[lag + 1] {
                    peaks.append((lag, c))
                }
            }
            guard !peaks.isEmpty else { return nil }
            let strongest = peaks.map(\.strength).max() ?? 0
            let minimumStrength = max(
                SignalProcessingParameters.heartACFMinimumStrength,
                SignalProcessingParameters.heartACFSignificantPeakFraction * strongest
            )

            // Shortest sufficiently strong positive-lag maximum: for a non-sinusoidal periodic
            // waveform this avoids automatically selecting a stronger 2T maximum and halving HR.
            guard let selected = peaks
                .filter({ $0.strength >= minimumStrength })
                .min(by: { $0.lag < $1.lag }) else { return nil }

            var refinedLag = Double(selected.lag)
            let denominator = acf[selected.lag - 1]
                - 2 * acf[selected.lag]
                + acf[selected.lag + 1]
            if abs(denominator) > .ulpOfOne {
                refinedLag += 0.5
                    * (acf[selected.lag - 1] - acf[selected.lag + 1])
                    / denominator
            }
            guard refinedLag > 0 else { return nil }
            let rate = 60.0 * sampleRateHz / refinedLag
            guard rate >= SignalProcessingParameters.minimumHeartRateBPM,
                  rate <= SignalProcessingParameters.maximumHeartRateBPM else { return nil }
            return (rate, selected.strength)
        }

        guard let global = estimateACFPeriod(envelope) else { return nil }

        // Local-stationarity check: repeat exactly the same ACF period estimation in overlapping
        // windows and ask only whether it agrees with the full-recording period. No HR hypothesis
        // is used to place peaks, and no weighted evidence score is introduced.
        let localWindow = min(
            envelope.count,
            max(
                SignalProcessingParameters.minimumSampleCount,
                Int((SignalProcessingParameters.heartACFLocalWindowSeconds * sampleRateHz).rounded())
            )
        )
        let localHop = max(
            1,
            Int((SignalProcessingParameters.heartACFLocalHopSeconds * sampleRateHz).rounded())
        )
        var localRates: [Double] = []
        if localWindow <= envelope.count {
            var start = 0
            while start + localWindow <= envelope.count {
                if let local = estimateACFPeriod(Array(envelope[start..<(start + localWindow)])) {
                    localRates.append(local.rateBPM)
                }
                start += localHop
            }
        }
        let agreeingLocal = localRates.filter { ratesAgree($0, global.rateBPM) }.count
        let localAgreement = localRates.isEmpty
            ? 0
            : Double(agreeingLocal) / Double(localRates.count)

        return AxisPeriodicity(
            name: name,
            rateBPM: global.rateBPM,
            strength: global.strength,
            localAgreementFraction: localAgreement,
            localWindowCount: localRates.count
        )
    }

    private static func buildClusters(_ values: [AxisPeriodicity]) -> [PeriodicityCluster] {
        var clusters: [PeriodicityCluster] = []
        for value in values {
            if let index = clusters.firstIndex(where: { ratesAgree($0.centerBPM, value.rateBPM) }) {
                clusters[index].axes.append(value)
            } else {
                clusters.append(PeriodicityCluster(axes: [value]))
            }
        }
        return clusters
    }

    // MARK: Final rate reliability

    private static func confirmedAnalysis(
        _ analysis: HeartAnalysis,
        rateBPM: Double,
        autocorrelationStrength: Double,
        supportingAxes: Int
    ) -> HeartAnalysis {
        let correlation = analysis.estimate.medianTemplateCorrelation ?? 0
        let enoughBeatEvidence = analysis.validIntervalFraction >= SignalProcessingParameters.heartConfirmedMinimumValidIntervalFraction
            && correlation >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && analysis.estimate.detectedBeatCount >= SignalProcessingParameters.heartMinimumBeatCount
        let enoughPeriodicityEvidence = autocorrelationStrength >= SignalProcessingParameters.heartACFMinimumStrength
            && supportingAxes >= SignalProcessingParameters.heartACFMinimumSupportingAxes
        let reliable = analysis.estimate.isReliable || (enoughBeatEvidence && enoughPeriodicityEvidence)
        let quality = min(1, max(0,
            (analysis.validIntervalFraction + correlation + min(1, autocorrelationStrength)) / 3
        ))

        let estimate = HeartEstimate(
            rateBPM: reliable ? rateBPM : nil,
            baselineRateBPM: rateBPM,
            detectedBeatCount: analysis.estimate.detectedBeatCount,
            interBeatVariability: analysis.estimate.interBeatVariability,
            medianTemplateCorrelation: analysis.estimate.medianTemplateCorrelation,
            qualityScore: quality,
            isReliable: reliable,
            reliabilityMessage: reliable ? "reliability.heart.reliable" : "reliability.heart.unreliable"
        )
        return HeartAnalysis(
            estimate: estimate,
            beatTimesSeconds: analysis.beatTimesSeconds,
            normalizedSignal: analysis.normalizedSignal,
            sampleRateHz: analysis.sampleRateHz,
            validIntervalFraction: analysis.validIntervalFraction,
            baselineAgreement: autocorrelationStrength
        )
    }

    private static func periodicityOnlyAnalysis(
        base: HeartAnalysis,
        rateBPM: Double,
        autocorrelationStrength: Double,
        localAgreement: Double
    ) -> HeartAnalysis {
        // This is an average-rate estimate, not beat-to-beat localisation. Therefore beat markers,
        // IBI variability and template correlation are deliberately not fabricated.
        let quality = min(1, max(0, min(autocorrelationStrength, localAgreement)))
        let estimate = HeartEstimate(
            rateBPM: rateBPM,
            baselineRateBPM: rateBPM,
            detectedBeatCount: 0,
            interBeatVariability: nil,
            medianTemplateCorrelation: nil,
            qualityScore: quality,
            isReliable: true,
            reliabilityMessage: "reliability.heart.reliable"
        )
        return HeartAnalysis(
            estimate: estimate,
            beatTimesSeconds: [],
            normalizedSignal: base.normalizedSignal,
            sampleRateHz: base.sampleRateHz,
            validIntervalFraction: 0,
            baselineAgreement: autocorrelationStrength
        )
    }

    private static func cautiousCopy(of analysis: HeartAnalysis) -> HeartAnalysis {
        let baseline = analysis.estimate.baselineRateBPM
        let estimate = HeartEstimate(
            rateBPM: nil,
            baselineRateBPM: baseline,
            detectedBeatCount: analysis.estimate.detectedBeatCount,
            interBeatVariability: analysis.estimate.interBeatVariability,
            medianTemplateCorrelation: analysis.estimate.medianTemplateCorrelation,
            qualityScore: analysis.estimate.qualityScore,
            isReliable: false,
            reliabilityMessage: "reliability.heart.unreliable"
        )
        return HeartAnalysis(
            estimate: estimate,
            beatTimesSeconds: analysis.beatTimesSeconds,
            normalizedSignal: analysis.normalizedSignal,
            sampleRateHz: analysis.sampleRateHz,
            validIntervalFraction: analysis.validIntervalFraction,
            baselineAgreement: analysis.baselineAgreement
        )
    }

    private static func ratesAgree(_ lhs: Double, _ rhs: Double) -> Bool {
        let tolerance = max(
            SignalProcessingParameters.heartACFAgreementBPM,
            SignalProcessingParameters.heartACFAgreementFraction * max(lhs, rhs)
        )
        return abs(lhs - rhs) <= tolerance
    }

    private static func areHarmonicallyRelated(_ lhs: Double, _ rhs: Double) -> Bool {
        let low = min(lhs, rhs)
        let high = max(lhs, rhs)
        guard low > 0 else { return false }
        return abs(high / low - 2.0) <= SignalProcessingParameters.heartHarmonicRatioTolerance
    }
}
