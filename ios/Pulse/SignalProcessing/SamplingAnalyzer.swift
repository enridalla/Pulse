import Foundation

/// Tri-axial signal on a (near-)uniform time base, plus the diagnostics that describe how
/// regular the original sampling was.
struct AnalyzedSignal {
    let times: [Double]
    let x: [Double]
    let y: [Double]
    let z: [Double]
    let sampleRateHz: Double
    let diagnostics: SamplingDiagnostics
}

/// Cleans the raw timestamps, measures the true sampling regularity and — only if the jitter is
/// large — resamples onto a uniform grid by linear interpolation.
enum SamplingAnalyzer {
    static func analyze(
        times rawTimes: [Double],
        x rawX: [Double],
        y rawY: [Double],
        z rawZ: [Double]
    ) throws -> AnalyzedSignal {
        precondition(rawTimes.count == rawX.count && rawX.count == rawY.count && rawY.count == rawZ.count)
        guard rawTimes.count >= SignalProcessingParameters.minimumSampleCount else {
            throw MeasurementError.insufficientSamples
        }

        // 1. Drop non-finite samples and enforce strictly increasing time, counting problems.
        var times = [Double](), x = [Double](), y = [Double](), z = [Double]()
        var duplicateCount = 0
        var nonIncreasingCount = 0
        for i in 0..<rawTimes.count {
            let t = rawTimes[i]
            guard t.isFinite, rawX[i].isFinite, rawY[i].isFinite, rawZ[i].isFinite else { continue }
            if let last = times.last {
                if t == last { duplicateCount += 1; continue }
                if t < last { nonIncreasingCount += 1; continue }
            }
            times.append(t); x.append(rawX[i]); y.append(rawY[i]); z.append(rawZ[i])
        }

        guard times.count >= SignalProcessingParameters.minimumSampleCount else {
            throw MeasurementError.invalidTimestamps
        }

        // 2. Interval statistics.
        var intervals = [Double]()
        intervals.reserveCapacity(times.count - 1)
        for i in 1..<times.count { intervals.append(times[i] - times[i - 1]) }

        let medianInterval = Statistics.median(intervals)
        guard medianInterval > .ulpOfOne else { throw MeasurementError.invalidTimestamps }
        let meanInterval = Statistics.mean(intervals)
        let stdInterval = Statistics.standardDeviation(intervals)
        let robustSigma = Statistics.medianAbsoluteDeviation(intervals)
        let threshold = max(
            SignalProcessingParameters.anomalousIntervalRobustSigmaFactor * robustSigma,
            SignalProcessingParameters.anomalousIntervalRelativeFloor * medianInterval
        )
        let anomalousCount = intervals.reduce(0) { abs($1 - medianInterval) > threshold ? $0 + 1 : $0 }

        let estimatedFs = 1.0 / medianInterval

        // 3. Decide whether to resample. DFT/filtering/autocorrelation assume a uniform discrete
        // time base. A single dropped sample can be hidden by a small global jitter statistic, so
        // an isolated interval larger than 1.5 Ts (or smaller than 0.5 Ts) also triggers
        // interpolation onto the median-Ts grid.
        let jitter = stdInterval / medianInterval
        let hasLargeGap = intervals.contains { $0 > 1.5 * medianInterval || $0 < 0.5 * medianInterval }
        let shouldResample = jitter > SignalProcessingParameters.resamplingJitterThreshold || hasLargeGap

        var outTimes = times, outX = x, outY = y, outZ = z
        var outFs = estimatedFs
        if shouldResample {
            let (gt, gx, gy, gz) = resampleUniform(times: times, x: x, y: y, z: z, sampleRateHz: estimatedFs)
            outTimes = gt; outX = gx; outY = gy; outZ = gz
            outFs = estimatedFs
        }

        let diagnostics = SamplingDiagnostics(
            estimatedSamplingFrequencyHz: estimatedFs,
            medianIntervalSeconds: medianInterval,
            meanIntervalSeconds: meanInterval,
            standardDeviationIntervalSeconds: stdInterval,
            minimumIntervalSeconds: intervals.min() ?? 0,
            maximumIntervalSeconds: intervals.max() ?? 0,
            duplicateTimestampCount: duplicateCount,
            nonIncreasingTimestampCount: nonIncreasingCount,
            anomalousIntervalCount: anomalousCount,
            wasResampled: shouldResample
        )

        return AnalyzedSignal(times: outTimes, x: outX, y: outY, z: outZ, sampleRateHz: outFs, diagnostics: diagnostics)
    }

    /// Linear interpolation of every axis onto a uniform grid at `sampleRateHz`.
    static func resampleUniform(
        times: [Double],
        x: [Double],
        y: [Double],
        z: [Double],
        sampleRateHz: Double
    ) -> ([Double], [Double], [Double], [Double]) {
        guard let firstTime = times.first, let lastTime = times.last, lastTime > firstTime else {
            return (times, x, y, z)
        }
        let dt = 1.0 / sampleRateHz
        let count = Int(((lastTime - firstTime) / dt).rounded(.down)) + 1

        var gt = [Double](repeating: 0, count: count)
        var gx = [Double](repeating: 0, count: count)
        var gy = [Double](repeating: 0, count: count)
        var gz = [Double](repeating: 0, count: count)

        var lower = 0
        for i in 0..<count {
            let t = firstTime + Double(i) * dt
            while lower < times.count - 2 && times[lower + 1] < t { lower += 1 }
            let upper = min(lower + 1, times.count - 1)
            let span = times[upper] - times[lower]
            let fraction = span > .ulpOfOne ? (t - times[lower]) / span : 0
            gt[i] = t
            gx[i] = x[lower] + (x[upper] - x[lower]) * fraction
            gy[i] = y[lower] + (y[upper] - y[lower]) * fraction
            gz[i] = z[lower] + (z[upper] - z[lower]) * fraction
        }
        return (gt, gx, gy, gz)
    }
}
