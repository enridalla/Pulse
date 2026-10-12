import Foundation

/// Stages reported to the UI as the pipeline progresses (real stages, not a fake timer).
enum ProcessingStage: Int, Sendable, CaseIterable {
    case signalCheck
    case heart
    case respiration
    case quality
}

/// Raw tri-axial input for the processor.
struct RawSignal: Sendable {
    let times: [Double]
    let x: [Double]
    let y: [Double]
    let z: [Double]
}

/// Orchestrates the whole DSP pipeline. Pure and Foundation-only: given raw samples and the
/// configuration it returns a complete `MeasurementResult`. All UI progress is reported through
/// the optional `progress` closure so this stays free of any UI dependency.
enum CardiorespiratoryProcessor {
    static func process(
        signal raw: RawSignal,
        configuration: MeasurementConfiguration,
        id: UUID,
        startedAt: Date,
        rawCSVFileName: String,
        metadataFileName: String,
        appVersion: String,
        progress: (@Sendable (ProcessingStage) -> Void)? = nil
    ) throws -> MeasurementResult {
        // 1. Timestamps → uniform-ish signal + diagnostics.
        progress?(.signalCheck)
        let analyzed = try SamplingAnalyzer.analyze(times: raw.times, x: raw.x, y: raw.y, z: raw.z)
        let fs = analyzed.sampleRateHz
        let duration = (analyzed.times.last ?? 0) - (analyzed.times.first ?? 0)

        // 2. Trim transients from both ends.
        let range = try SignalPreprocessor.usableRange(
            sampleCount: analyzed.x.count,
            sampleRateHz: fs,
            trimBeginningSeconds: SignalProcessingParameters.trimBeginningSeconds,
            trimEndingSeconds: SignalProcessingParameters.trimEndingSeconds
        )
        let tx = Array(analyzed.x[range])
        let ty = Array(analyzed.y[range])
        let tz = Array(analyzed.z[range])

        // 3. Band-specific spatial candidates. Filtering precedes PCA so slow posture drift and
        // respiration cannot determine the cardiac projection, and high-frequency SCG energy
        // cannot determine the respiratory projection.
        let heartCandidateSet = ComponentSelector.bandLimitedCandidates(
            x: tx,
            y: ty,
            z: tz,
            targetBand: SignalProcessingParameters.heartSignalBandHz,
            order: SignalProcessingParameters.heartFilterOrder,
            sampleRateHz: fs
        )
        let respiratoryCandidateSet = ComponentSelector.bandLimitedCandidates(
            x: tx,
            y: ty,
            z: tz,
            targetBand: SignalProcessingParameters.respirationFilterBandHz,
            order: SignalProcessingParameters.respirationFilterOrder,
            sampleRateHz: fs
        )
        // Course-aligned RR uses the three physical axes plus PC1 after respiratory-band filtering.
        // PC1 is an auxiliary projection, not an additional sensor; magnitude and PC2 do not vote.
        let respiratoryCandidates = respiratoryCandidateSet.components.filter {
            ["x", "y", "z", "PC1-band"].contains($0.name)
        }
        let pcaWeights = respiratoryCandidateSet.pcaWeights

        // 4. Heart: template matching localises beats, IBIs provide HR, and autocorrelation of the
        // cardiomechanical energy envelope is used only as a global consistency/harmonic check.
        // Only x/y/z are eligible cardiac representations.
        progress?(.heart)
        let heartPhysicalCandidates = heartCandidateSet.components.filter {
            ["x", "y", "z"].contains($0.name)
        }
        let heartAnalyses = heartPhysicalCandidates.map { component in
            (name: component.name,
             analysis: HeartRateEstimator.analyze(filtered: component.samples, sampleRateHz: fs))
        }
        let heartSelection = HeartRateReconciler.select(
            analyses: heartAnalyses,
            filteredPhysicalComponents: heartPhysicalCandidates,
            sampleRateHz: fs
        )
        let heart = heartSelection.analysis

        // 5. Respiration. PC1 after respiratory-band filtering is the primary spatial projection;
        // autocorrelation estimates its period, Welch verifies the frequency/harmonics, and local
        // ACF windows expressed in respiratory cycles verify persistence.
        progress?(.respiration)
        let respiratory = RespiratoryRateEstimator.analyze(
            components: respiratoryCandidates,
            sampleRateHz: fs,
            cardiacRateBPM: heart.estimate.isReliable ? heart.estimate.rateBPM : nil,
            componentsAreBandLimited: true
        )

        // 6. Quality.
        progress?(.quality)
        let magnitude = zip(zip(tx, ty), tz).map { pair, zv -> Double in
            let (xv, yv) = pair
            return (xv * xv + yv * yv + zv * zv).squareRoot()
        }
        let qualityWindowSeconds = 2.0
        let timeline = SignalQualityEvaluator.stabilityTimeline(
            magnitude: magnitude, sampleRateHz: fs, windowSeconds: qualityWindowSeconds
        )
        let motionArtifactFraction = SignalQualityEvaluator.motionArtifactFraction(timeline)
        let overall = SignalQualityEvaluator.overall(
            respiratory: respiratory.estimate, heart: heart.estimate, motionArtifactFraction: motionArtifactFraction
        )

        // 7. Preview + technical report.
        let preview = buildPreview(
            respirationFiltered: respiratory.filteredSignal,
            heart: heart,
            timeline: timeline,
            qualityWindowSeconds: qualityWindowSeconds,
            sampleRateHz: fs
        )
        let technical = TechnicalReport(
            selectedRespiratoryComponent: respiratory.selectedComponentName,
            selectedHeartComponent: heartSelection.name,
            respiratoryComponentScores: respiratory.componentScores,
            principalComponentWeights: pcaWeights,
            respiratoryPeakToBandPowerRatio: respiratory.peakToBandPowerRatio,
            respiratoryFirstToSecondPeakRatio: respiratory.firstToSecondPeakRatio,
            respiratoryAutocorrelationPeak: respiratory.autocorrelationStrength,
            welchAutocorrelationAgreementBPM: respiratory.agreementBPM,
            respiratoryCandidateMargin: respiratory.candidateMargin,
            respiratoryTemporalStability: respiratory.temporalStability,
            respiratoryCardiacOverlapPenalty: respiratory.cardiacOverlapPenalty,
            heartValidIntervalFraction: heart.validIntervalFraction,
            motionArtifactFraction: motionArtifactFraction
        )

        return MeasurementResult(
            id: id,
            startedAt: startedAt,
            durationSeconds: duration,
            configuration: configuration,
            samplingDiagnostics: analyzed.diagnostics,
            respiratoryEstimate: respiratory.estimate,
            heartEstimate: heart.estimate,
            overallQuality: overall.quality,
            excludedBeginningSeconds: SignalProcessingParameters.trimBeginningSeconds,
            excludedEndingSeconds: SignalProcessingParameters.trimEndingSeconds,
            technical: technical,
            preview: preview,
            algorithmVersion: SignalProcessingParameters.algorithmVersion,
            appVersion: appVersion,
            rawCSVFileName: rawCSVFileName,
            metadataFileName: metadataFileName
        )
    }

    // MARK: Preview

    private static func buildPreview(
        respirationFiltered: [Double],
        heart: HeartAnalysis,
        timeline: [Double],
        qualityWindowSeconds: Double,
        sampleRateHz: Double
    ) -> SignalPreview {
        // Respiration waveform, downsampled to ~600 points and normalised to [-1, 1].
        let respirationTarget = 600
        let respirationStride = max(1, respirationFiltered.count / respirationTarget)
        var respirationWaveform = stride(from: 0, to: respirationFiltered.count, by: respirationStride).map { respirationFiltered[$0] }
        respirationWaveform = normalizeForDisplay(respirationWaveform)
        let respirationSampleRate = sampleRateHz / Double(respirationStride)

        // Heart preview over the same analysed interval as respiration.  The persisted field names
        // keep their historical "heartWindow" wording for backwards compatibility, but new
        // recordings store the complete analysed heart-band trace rather than a six-second crop.
        // This is display-only: it does not alter beat detection or the HR estimate.
        let heartTarget = 1600
        let heartStride = max(1, heart.normalizedSignal.count / heartTarget)
        let heartWaveform = normalizeForDisplay(
            stride(from: 0, to: heart.normalizedSignal.count, by: heartStride).map { heart.normalizedSignal[$0] }
        )
        let heartDuration = Double(heart.normalizedSignal.count) / sampleRateHz
        let beatOffsets = heart.beatTimesSeconds.filter { $0 >= 0 && $0 <= heartDuration }

        return SignalPreview(
            respirationWaveform: respirationWaveform,
            respirationSampleRateHz: respirationSampleRate,
            heartWindowWaveform: heartWaveform,
            heartWindowSampleRateHz: heart.normalizedSignal.isEmpty ? 0 : sampleRateHz / Double(heartStride),
            heartWindowStartSeconds: 0,
            heartBeatOffsetsSeconds: beatOffsets,
            qualityTimeline: timeline,
            qualityWindowSeconds: qualityWindowSeconds
        )
    }

    private static func normalizeForDisplay(_ values: [Double]) -> [Double] {
        let maxAbs = values.map(abs).max() ?? 0
        guard maxAbs > .ulpOfOne else { return values }
        return values.map { $0 / maxAbs }
    }
}
