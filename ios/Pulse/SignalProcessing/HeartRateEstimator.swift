import Foundation

/// Full heart analysis for one already heart-band-filtered accelerometer component.
struct HeartAnalysis {
    let estimate: HeartEstimate
    /// Accepted beat times (seconds from the start of the analysed signal).
    let beatTimesSeconds: [Double]
    /// Robustly normalised heart-band signal (for the preview window).
    let normalizedSignal: [Double]
    let sampleRateHz: Double
    let validIntervalFraction: Double
    /// Template-repeatability diagnostic retained for the technical report.
    let baselineAgreement: Double
}

/// ECG-free heartbeat detection from the smartphone accelerometer.
///
/// The estimator uses the physiologically interpretable direction of inference:
///
///     cardiomechanical waveform -> heartbeat locations -> IBIs -> heart rate
///
/// rather than generating an HR/period hypothesis first and then forcing peaks onto that grid.
/// A reliable 10 s region is identified from a fourth-power low-pass envelope, a representative
/// heartbeat template is selected automatically, normalized cross-correlation (NCC) is computed
/// against the complete recording, and heartbeat locations are obtained from NCC peaks.
///
/// Two additional checks handle the declared operating range up to 180 bpm:
///
/// - the minimum NCC peak distance is derived from HR_max, never from a preferred HR;
/// - a data-driven odd/even test can collapse two different mechanical complexes from one cardiac
///   cycle, while a midpoint test marks unresolved f-vs-2f cases as unreliable rather than forcing
///   either interpretation.
///
/// Autocorrelation, Welch peaks and f/2-f-2f voting are intentionally absent from the final HR
/// decision in this estimator.
enum HeartRateEstimator {
    private struct TemplateSelection {
        let template: [Double]
        let peakOffsetSamples: Int
        let preliminaryIBIMeanAbsoluteDeviationSeconds: Double
    }

    private struct NCCPeak {
        let index: Int
        let value: Double
        let prominence: Double
    }

    private struct SequenceResolution {
        let beatSamples: [Int]
        let correlations: [Double]
    }

    static func analyze(filtered: [Double], sampleRateHz: Double) -> HeartAnalysis {
        guard filtered.count >= SignalProcessingParameters.minimumSampleCount,
              sampleRateHz > 0 else {
            return unreliable(normalized: [], sampleRateHz: sampleRateHz)
        }

        let centered = Statistics.removeMean(filtered)
        let robustScale = max(Statistics.medianAbsoluteDeviation(centered), .ulpOfOne)
        let normalized = centered.map { $0 / robustScale }

        guard let selection = automaticTemplateSelection(normalized, sampleRateHz: sampleRateHz) else {
            return unreliable(normalized: normalized, sampleRateHz: sampleRateHz)
        }

        let ncc = TemplateMatcher.normalizedCrossCorrelation(
            signal: normalized,
            template: selection.template
        )

        let physiologicalMinimumIBI = 60.0 / SignalProcessingParameters.maximumHeartRateBPM
        let minimumPeakDistanceSeconds =
            SignalProcessingParameters.heartNCCMinimumPeakDistanceFractionOfMinimumIBI
            * physiologicalMinimumIBI
        let minimumPeakDistanceSamples = max(
            1,
            Int((minimumPeakDistanceSeconds * sampleRateHz).rounded())
        )

        let rawPeaks = prominentPeaks(
            ncc,
            minimumDistanceSamples: minimumPeakDistanceSamples,
            minimumHeight: SignalProcessingParameters.heartNCCMinimumCorrelation,
            minimumProminence: SignalProcessingParameters.heartNCCMinimumProminence
        )
        guard rawPeaks.count >= SignalProcessingParameters.heartMinimumBeatCount else {
            return unreliable(normalized: normalized, sampleRateHz: sampleRateHz)
        }

        let rawBeatSamples = rawPeaks.map {
            min(normalized.count - 1, $0.index + selection.peakOffsetSamples)
        }
        let rawCorrelations = rawPeaks.map(\.value)

        let resolved = resolveAlternatingMechanicalComplexes(
            signal: normalized,
            beatSamples: rawBeatSamples,
            correlations: rawCorrelations,
            sampleRateHz: sampleRateHz
        )

        guard resolved.beatSamples.count >= SignalProcessingParameters.heartMinimumBeatCount else {
            return unreliable(normalized: normalized, sampleRateHz: sampleRateHz)
        }

        let intervalResult = intervalDiagnostics(
            beatSamples: resolved.beatSamples,
            sampleRateHz: sampleRateHz
        )
        guard intervalResult.validIntervals.count >= SignalProcessingParameters.heartMinimumBeatCount - 1 else {
            return unreliable(normalized: normalized, sampleRateHz: sampleRateHz)
        }

        let representativeIBI = robustCentralInterval(
            intervalResult.validIntervals,
            sampleRateHz: sampleRateHz
        )
        guard representativeIBI > 0 else {
            return unreliable(normalized: normalized, sampleRateHz: sampleRateHz)
        }
        let rawRateBPM = 60.0 / representativeIBI

        // Near a declared physiological boundary, finite observation time and sample quantisation
        // can move an otherwise correct estimate by a fraction of one beat/min.  The tolerance is
        // not a preferred HR: it is the one-event frequency resolution of the observed beat span.
        let observedBeatSpanSeconds = max(
            Double((resolved.beatSamples.last ?? 0) - (resolved.beatSamples.first ?? 0)) / sampleRateHz,
            1.0
        )
        let boundaryResolutionBPM = 60.0 / observedBeatSpanSeconds
        let minimumHeartRate = SignalProcessingParameters.minimumHeartRateBPM
        let maximumHeartRate = SignalProcessingParameters.maximumHeartRateBPM
        let inRange = rawRateBPM >= minimumHeartRate - boundaryResolutionBPM
            && rawRateBPM <= maximumHeartRate + boundaryResolutionBPM
        let rateBPM = min(max(rawRateBPM, minimumHeartRate), maximumHeartRate)

        let midpointAmbiguity = hasSystematicMidpointMatches(
            ncc: ncc,
            beatSamples: resolved.beatSamples,
            acceptedCorrelations: resolved.correlations,
            peakOffsetSamples: selection.peakOffsetSamples,
            sampleRateHz: sampleRateHz,
            currentRateBPM: rateBPM
        )

        let medianCorrelation = Statistics.median(resolved.correlations)
        let regularity = min(
            1,
            max(0, 1 - intervalResult.robustCoefficientOfVariation
                / max(SignalProcessingParameters.heartMaximumIBIVariability, .ulpOfOne))
        )
        let qualityScore = min(1, max(0,
            0.45 * medianCorrelation
            + 0.30 * intervalResult.validFraction
            + 0.25 * regularity
        ))

        let isReliable = inRange
            && !midpointAmbiguity
            && intervalResult.validFraction >= SignalProcessingParameters.heartMinimumValidIntervalFraction
            && intervalResult.robustCoefficientOfVariation <= SignalProcessingParameters.heartMaximumIBIVariability
            && medianCorrelation >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && qualityScore >= SignalProcessingParameters.heartReliableQualityThreshold

        let estimate = HeartEstimate(
            rateBPM: isReliable ? rateBPM : nil,
            baselineRateBPM: rawRateBPM,
            detectedBeatCount: resolved.beatSamples.count,
            interBeatVariability: intervalResult.robustCoefficientOfVariation,
            medianTemplateCorrelation: medianCorrelation,
            qualityScore: qualityScore,
            isReliable: isReliable,
            reliabilityMessage: isReliable ? "reliability.heart.reliable" : "reliability.heart.unreliable"
        )

        // A bounded measure of how clean the template-selection window was. It is not a
        // probability and is not used to decide the HR.
        let templateRepeatability = min(1, max(0,
            1 - selection.preliminaryIBIMeanAbsoluteDeviationSeconds
                / max(SignalProcessingParameters.heartTemplateMaximumIBIMeanAbsoluteDeviationSeconds, .ulpOfOne)
        ))

        return HeartAnalysis(
            estimate: estimate,
            beatTimesSeconds: resolved.beatSamples.map { Double($0) / sampleRateHz },
            normalizedSignal: normalized,
            sampleRateHz: sampleRateHz,
            validIntervalFraction: intervalResult.validFraction,
            baselineAgreement: templateRepeatability
        )
    }

    /// Selects one *physical accelerometer axis* as the final SCG representation.
    ///
    /// This is intentionally not a frequency vote. x/y/z are three views of the same sensor and
    /// derived quantities such as |a|, PC1 and PC2 are not independent observations. The axis is
    /// chosen only after beat-to-beat detection, using predeclared signal-quality criteria:
    /// reliability, fraction of physiologically valid IBIs, IBI repeatability, then NCC similarity.
    static func selectBestPhysicalAxis(
        _ analyses: [(name: String, analysis: HeartAnalysis)]
    ) -> (name: String, analysis: HeartAnalysis) {
        guard !analyses.isEmpty else {
            return ("none", unreliable(normalized: [], sampleRateHz: 0))
        }

        let physical = analyses.filter { ["x", "y", "z"].contains($0.name) }
        let pool = physical.isEmpty ? analyses : physical

        return pool.sorted { left, right in
            let l = left.analysis
            let r = right.analysis

            if l.estimate.isReliable != r.estimate.isReliable {
                return l.estimate.isReliable && !r.estimate.isReliable
            }
            if abs(l.validIntervalFraction - r.validIntervalFraction) > 1e-9 {
                return l.validIntervalFraction > r.validIntervalFraction
            }

            let lCV = l.estimate.interBeatVariability ?? .infinity
            let rCV = r.estimate.interBeatVariability ?? .infinity
            if abs(lCV - rCV) > 1e-9 { return lCV < rCV }

            let lCorrelation = l.estimate.medianTemplateCorrelation ?? -1
            let rCorrelation = r.estimate.medianTemplateCorrelation ?? -1
            if abs(lCorrelation - rCorrelation) > 1e-9 { return lCorrelation > rCorrelation }

            return l.estimate.qualityScore > r.estimate.qualityScore
        }.first ?? pool[0]
    }

    // MARK: Automatic template selection

    private static func automaticTemplateSelection(
        _ signal: [Double],
        sampleRateHz: Double
    ) -> TemplateSelection? {
        let requested = max(1, Int((SignalProcessingParameters.heartTemplateWindowSeconds * sampleRateHz).rounded()))
        let minimum = max(1, Int((SignalProcessingParameters.heartTemplateMinimumWindowSeconds * sampleRateHz).rounded()))
        guard signal.count >= minimum else { return nil }

        let pre = max(1, Int((SignalProcessingParameters.heartTemplatePreSeconds * sampleRateHz).rounded()))
        let post = max(1, Int((SignalProcessingParameters.heartTemplatePostSeconds * sampleRateHz).rounded()))
        let lowpass = ButterworthLowpass(
            order: SignalProcessingParameters.heartTemplateEnvelopeLowpassOrder,
            cutoffHz: SignalProcessingParameters.heartTemplateEnvelopeLowpassHz,
            sampleRateHz: sampleRateHz
        )

        var start = 0
        while start < signal.count {
            let end = min(start + requested, signal.count)
            guard end - start >= minimum else { break }
            let segment = Array(signal[start..<end])

            // Template-selection envelope: x^4 -> 3 Hz zero-phase Butterworth -> normalize.
            let fourthPower = segment.map { sample -> Double in
                let square = sample * sample
                return square * square
            }
            var envelope = lowpass.filtfilt(fourthPower)
            let maximum = envelope.map(abs).max() ?? 0
            guard maximum > .ulpOfOne else {
                start += requested
                continue
            }
            envelope = envelope.map { $0 / maximum }

            let preliminary = prominentPeaks(
                envelope,
                minimumDistanceSamples: 1,
                minimumHeight: -Double.infinity,
                minimumProminence: SignalProcessingParameters.heartTemplateEnvelopePeakProminence
            ).map(\.index)

            guard preliminary.count >= SignalProcessingParameters.heartTemplateMinimumPeaks else {
                start += requested
                continue
            }

            let preliminaryIBIs = zip(preliminary.dropFirst(), preliminary).map {
                Double($0.0 - $0.1) / sampleRateHz
            }
            let ibiMean = Statistics.mean(preliminaryIBIs)
            let meanAbsoluteDeviation = preliminaryIBIs.isEmpty ? .infinity :
                Statistics.mean(preliminaryIBIs.map { abs($0 - ibiMean) })

            // One sampling period is added to the 335 ms variability limit because at ~100 Hz
            // peak quantisation alone contributes about 10 ms.
            let variabilityLimit =
                SignalProcessingParameters.heartTemplateMaximumIBIMeanAbsoluteDeviationSeconds
                + 1.0 / sampleRateHz
            guard meanAbsoluteDeviation <= variabilityLimit else {
                start += requested
                continue
            }

            var candidateWindows: [(peak: Int, samples: [Double])] = []
            for peak in preliminary {
                let lower = peak - pre
                let upper = peak + post
                guard lower >= 0, upper < segment.count else { continue }
                let raw = Array(segment[lower...upper])
                if let unit = unitNorm(raw) {
                    candidateWindows.append((peak, unit))
                }
            }
            guard candidateWindows.count >= SignalProcessingParameters.heartTemplateMinimumPeaks else {
                start += requested
                continue
            }

            var bestIndex: Int?
            var bestRepresentativeness = -Double.infinity
            for index in candidateWindows.indices {
                var correlations: [Double] = []
                correlations.reserveCapacity(candidateWindows.count - 1)
                for other in candidateWindows.indices where other != index {
                    correlations.append(
                        Statistics.correlation(
                            candidateWindows[index].samples,
                            candidateWindows[other].samples
                        )
                    )
                }
                guard !correlations.isEmpty else { continue }
                let average = Statistics.mean(correlations)
                let standardDeviation = Statistics.standardDeviation(correlations)
                let representativeness = average / max(standardDeviation, 1e-6)
                if representativeness > bestRepresentativeness {
                    bestRepresentativeness = representativeness
                    bestIndex = index
                }
            }

            if let bestIndex {
                // Start from the most representative heartbeat, then reduce template noise by
                // taking the pointwise median of morphologically consistent candidates around that
                // medoid. This selection does not use HR or period.
                let medoid = candidateWindows[bestIndex].samples
                var clustered = candidateWindows.map(\.samples).filter {
                    Statistics.correlation(medoid, $0)
                        >= SignalProcessingParameters.heartTemplateClusterMinimumCorrelation
                }
                if clustered.count < 3 {
                    clustered = candidateWindows.map(\.samples)
                        .sorted {
                            Statistics.correlation(medoid, $0)
                                > Statistics.correlation(medoid, $1)
                        }
                        .prefix(min(5, candidateWindows.count))
                        .map { $0 }
                }
                let medianTemplate = elementwiseMedian(clustered)
                guard let finalTemplate = unitNorm(medianTemplate) else {
                    start += requested
                    continue
                }

                return TemplateSelection(
                    template: finalTemplate,
                    peakOffsetSamples: pre,
                    preliminaryIBIMeanAbsoluteDeviationSeconds: meanAbsoluteDeviation
                )
            }

            start += requested
        }
        return nil
    }

    // MARK: Beat-sequence model checks

    /// If the NCC detector alternates between two different mechanical complexes from the same
    /// heartbeat, intervals become short-long-short-long while every-other-event intervals become
    /// much more regular. Only then, and only when odd/even waveform morphology differs, is the
    /// two-complex interpretation accepted.
    private static func resolveAlternatingMechanicalComplexes(
        signal: [Double],
        beatSamples: [Int],
        correlations: [Double],
        sampleRateHz: Double
    ) -> SequenceResolution {
        guard beatSamples.count >= 8, beatSamples.count == correlations.count else {
            return SequenceResolution(
                beatSamples: beatSamples,
                correlations: correlations
            )
        }

        let intervals = zip(beatSamples.dropFirst(), beatSamples).map {
            Double($0.0 - $0.1) / sampleRateHz
        }
        guard intervals.count >= 6 else {
            return SequenceResolution(
                beatSamples: beatSamples,
                correlations: correlations
            )
        }

        let evenIntervals = stride(from: 0, to: intervals.count, by: 2).map { intervals[$0] }
        let oddIntervals = stride(from: 1, to: intervals.count, by: 2).map { intervals[$0] }
        guard !evenIntervals.isEmpty, !oddIntervals.isEmpty else {
            return SequenceResolution(
                beatSamples: beatSamples,
                correlations: correlations
            )
        }

        let evenMedian = Statistics.median(evenIntervals)
        let oddMedian = Statistics.median(oddIntervals)
        let intervalCenter = max((evenMedian + oddMedian) / 2, .ulpOfOne)
        let relativeAlternation = abs(evenMedian - oddMedian) / intervalCenter

        let rawCV = robustCoefficientOfVariation(intervals)
        let pairedIntervals = (0..<(beatSamples.count - 2)).map {
            Double(beatSamples[$0 + 2] - beatSamples[$0]) / sampleRateHz
        }
        let pairedMedian = Statistics.median(pairedIntervals)
        let pairedCV = robustCoefficientOfVariation(pairedIntervals)
        let pairedRate = pairedMedian > 0 ? 60.0 / pairedMedian : 0

        let morphology = oddEvenMorphology(
            signal: signal,
            beatSamples: beatSamples,
            sampleRateHz: sampleRateHz
        )
        let heartRateRange = SignalProcessingParameters.minimumHeartRateBPM...SignalProcessingParameters.maximumHeartRateBPM
        let rateInRange = heartRateRange.contains(pairedRate)
        let timingSupportsPairing =
            relativeAlternation >= SignalProcessingParameters.heartAlternatingIntervalMinimumRelativeDifference
            && pairedCV <= SignalProcessingParameters.heartAlternatingPairMaximumRobustCV
            && pairedCV <= SignalProcessingParameters.heartAlternatingPairDispersionImprovementFactor
                * max(rawCV, 1e-6)
        // No fixed correlation-gap threshold: the two alternating event classes must each be
        // more self-similar than they are similar to the opposite class.  Timing still has to
        // independently show a strong short-long alternation and a much more regular paired cycle.
        let morphologySupportsPairing =
            morphology.evenWithin >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && morphology.oddWithin >= SignalProcessingParameters.heartMinimumTemplateCorrelation
            && morphology.crossParity < min(morphology.evenWithin, morphology.oddWithin)

        guard rateInRange, timingSupportsPairing, morphologySupportsPairing else {
            return SequenceResolution(
                beatSamples: beatSamples,
                correlations: correlations
            )
        }

        let evenCorrelations = stride(from: 0, to: correlations.count, by: 2).map { correlations[$0] }
        let oddCorrelations = stride(from: 1, to: correlations.count, by: 2).map { correlations[$0] }
        let keepEven = Statistics.median(evenCorrelations) >= Statistics.median(oddCorrelations)
        let keptIndices = stride(
            from: keepEven ? 0 : 1,
            to: beatSamples.count,
            by: 2
        )

        return SequenceResolution(
            beatSamples: keptIndices.map { beatSamples[$0] },
            correlations: keptIndices.map { correlations[$0] }
        )
    }

    /// Detects unresolved systematic half-rate ambiguity without automatically preferring f or 2f.
    /// If template-like events appear near the midpoint of most accepted IBIs and the expanded
    /// sequence itself is physiologically regular, the single-axis estimate is declared ambiguous.
    private static func hasSystematicMidpointMatches(
        ncc: [Double],
        beatSamples: [Int],
        acceptedCorrelations: [Double],
        peakOffsetSamples: Int,
        sampleRateHz: Double,
        currentRateBPM: Double
    ) -> Bool {
        guard beatSamples.count >= 7,
              currentRateBPM * 2 <= SignalProcessingParameters.maximumHeartRateBPM,
              !acceptedCorrelations.isEmpty else {
            return false
        }

        let acceptedMedian = Statistics.median(acceptedCorrelations)
        let minimumMidpointCorrelation = max(
            SignalProcessingParameters.heartNCCMinimumCorrelation,
            SignalProcessingParameters.heartMidpointCorrelationFractionOfAcceptedMedian * acceptedMedian
        )

        var supportedMidpoints: [Int] = []
        for index in 0..<(beatSamples.count - 1) {
            let left = beatSamples[index]
            let right = beatSamples[index + 1]
            let ibi = right - left
            guard ibi > 2 else { continue }

            let midpoint = (left + right) / 2
            let radius = max(
                1,
                Int((SignalProcessingParameters.heartMidpointSearchFractionOfIBI * Double(ibi)).rounded())
            )
            let expectedNCCIndex = midpoint - peakOffsetSamples
            let lower = max(0, expectedNCCIndex - radius)
            let upper = min(ncc.count - 1, expectedNCCIndex + radius)
            guard lower <= upper else { continue }

            var bestIndex = lower
            var bestValue = ncc[lower]
            if lower < upper {
                for candidate in (lower + 1)...upper where ncc[candidate] > bestValue {
                    bestValue = ncc[candidate]
                    bestIndex = candidate
                }
            }
            if bestValue >= minimumMidpointCorrelation {
                supportedMidpoints.append(bestIndex + peakOffsetSamples)
            }
        }

        let supportFraction = Double(supportedMidpoints.count)
            / Double(max(beatSamples.count - 1, 1))
        guard supportFraction >= SignalProcessingParameters.heartMidpointMinimumSupportFraction else {
            return false
        }

        let expanded = Array(Set(beatSamples + supportedMidpoints)).sorted()
        guard expanded.count > beatSamples.count else { return false }
        let expandedIntervals = zip(expanded.dropFirst(), expanded).map {
            Double($0.0 - $0.1) / sampleRateHz
        }
        let expandedMedian = Statistics.median(expandedIntervals)
        guard expandedMedian > 0 else { return false }
        let expandedRate = 60.0 / expandedMedian
        let expandedCV = robustCoefficientOfVariation(expandedIntervals)

        return expandedRate <= SignalProcessingParameters.maximumHeartRateBPM
            && expandedRate >= SignalProcessingParameters.minimumHeartRateBPM
            && expandedCV <= SignalProcessingParameters.heartMidpointExpandedMaximumRobustCV
    }

    private static func oddEvenMorphology(
        signal: [Double],
        beatSamples: [Int],
        sampleRateHz: Double
    ) -> (evenWithin: Double, oddWithin: Double, crossParity: Double) {
        // Short local windows compare the mechanical event itself, not the entire cardiac period.
        let pre = max(1, Int((0.06 * sampleRateHz).rounded()))
        let post = max(2, Int((0.16 * sampleRateHz).rounded()))

        var even: [[Double]] = []
        var odd: [[Double]] = []
        for (index, beat) in beatSamples.enumerated() {
            let lower = beat - pre
            let upper = beat + post
            guard lower >= 0, upper < signal.count,
                  let window = unitNorm(Array(signal[lower...upper])) else { continue }
            if index.isMultiple(of: 2) { even.append(window) } else { odd.append(window) }
        }
        guard even.count >= 2, odd.count >= 2 else { return (0, 0, 0) }

        let evenWithin = medianPairwiseCorrelation(even)
        let oddWithin = medianPairwiseCorrelation(odd)
        var cross: [Double] = []
        cross.reserveCapacity(even.count * odd.count)
        for e in even {
            for o in odd { cross.append(Statistics.correlation(e, o)) }
        }
        return (
            evenWithin: evenWithin,
            oddWithin: oddWithin,
            crossParity: Statistics.median(cross)
        )
    }

    // MARK: Interval / peak helpers

    private static func intervalDiagnostics(
        beatSamples: [Int],
        sampleRateHz: Double
    ) -> (validIntervals: [Double], validFraction: Double, robustCoefficientOfVariation: Double) {
        guard beatSamples.count >= 2 else { return ([], 0, .infinity) }
        let intervals = zip(beatSamples.dropFirst(), beatSamples).map {
            Double($0.0 - $0.1) / sampleRateHz
        }
        // At ~100 Hz, a physiological period rarely lands on an integer sample. One-sample
        // tolerance prevents quantisation alone from rejecting true boundary-rate beats.
        let sampleTolerance = 1.0 / sampleRateHz
        let minimumIBI = 60.0 / SignalProcessingParameters.maximumHeartRateBPM - sampleTolerance
        let maximumIBI = 60.0 / SignalProcessingParameters.minimumHeartRateBPM + sampleTolerance
        let valid = intervals.filter { $0 >= minimumIBI && $0 <= maximumIBI }
        let fraction = Double(valid.count) / Double(max(intervals.count, 1))
        return (valid, fraction, robustCoefficientOfVariation(valid))
    }

    private static func robustCentralInterval(
        _ values: [Double],
        sampleRateHz: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let center = Statistics.median(values)
        let robustScale = max(
            Statistics.medianAbsoluteDeviation(values),
            1.0 / max(sampleRateHz, .ulpOfOne)
        )
        let retained = values.filter { abs($0 - center) <= 3.0 * robustScale }
        guard !retained.isEmpty else { return center }
        return Statistics.mean(retained)
    }

    private static func robustCoefficientOfVariation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .infinity }
        let center = Statistics.median(values)
        guard center > .ulpOfOne else { return .infinity }
        return Statistics.medianAbsoluteDeviation(values) / center
    }

    private static func prominentPeaks(
        _ signal: [Double],
        minimumDistanceSamples: Int,
        minimumHeight: Double,
        minimumProminence: Double
    ) -> [NCCPeak] {
        guard signal.count >= 3 else { return [] }
        var candidates: [NCCPeak] = []

        for index in 1..<(signal.count - 1) {
            let value = signal[index]
            guard value >= minimumHeight,
                  value >= signal[index - 1],
                  value >= signal[index + 1] else { continue }

            var leftMinimum = value
            var cursor = index - 1
            while true {
                leftMinimum = min(leftMinimum, signal[cursor])
                if signal[cursor] > value || cursor == 0 { break }
                cursor -= 1
            }

            var rightMinimum = value
            cursor = index + 1
            while true {
                rightMinimum = min(rightMinimum, signal[cursor])
                if signal[cursor] > value || cursor == signal.count - 1 { break }
                cursor += 1
            }

            let prominence = value - max(leftMinimum, rightMinimum)
            if prominence >= minimumProminence {
                candidates.append(NCCPeak(index: index, value: value, prominence: prominence))
            }
        }

        // Match findpeaks-style distance suppression: retain the stronger local maximum whenever
        // two candidates violate the refractory distance.
        let ranked = candidates.sorted {
            if abs($0.value - $1.value) > 1e-12 { return $0.value > $1.value }
            return $0.prominence > $1.prominence
        }
        var accepted: [NCCPeak] = []
        let distance = max(1, minimumDistanceSamples)
        for candidate in ranked {
            if accepted.allSatisfy({ abs($0.index - candidate.index) >= distance }) {
                accepted.append(candidate)
            }
        }
        return accepted.sorted { $0.index < $1.index }
    }

    private static func unitNorm(_ values: [Double]) -> [Double]? {
        guard values.count > 2 else { return nil }
        let centered = Statistics.removeMean(values)
        let norm = centered.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > .ulpOfOne else { return nil }
        return centered.map { $0 / norm }
    }


    private static func elementwiseMedian(_ windows: [[Double]]) -> [Double] {
        guard let length = windows.first?.count, length > 0,
              windows.allSatisfy({ $0.count == length }) else { return [] }
        return (0..<length).map { index in
            Statistics.median(windows.map { $0[index] })
        }
    }

    private static func medianPairwiseCorrelation(_ windows: [[Double]]) -> Double {
        guard windows.count >= 2 else { return 0 }
        var values: [Double] = []
        for i in 0..<(windows.count - 1) {
            for j in (i + 1)..<windows.count {
                values.append(Statistics.correlation(windows[i], windows[j]))
            }
        }
        return Statistics.median(values)
    }

    private static func unreliable(normalized: [Double], sampleRateHz: Double) -> HeartAnalysis {
        HeartAnalysis(
            estimate: .unreliable,
            beatTimesSeconds: [],
            normalizedSignal: normalized,
            sampleRateHz: sampleRateHz,
            validIntervalFraction: 0,
            baselineAgreement: 0
        )
    }
}
