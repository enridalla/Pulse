import Foundation

/// Normalised autocorrelation, used as an independent periodicity check for respiration and as
/// a baseline for the heart-rate envelope.
enum Autocorrelation {
    /// Autocorrelation at a single lag, normalised by the zero-lag energy (so lag 0 = 1).
    static func value(_ signal: [Double], lag: Int, zeroLagEnergy: Double) -> Double {
        guard zeroLagEnergy > .ulpOfOne, lag >= 0, lag < signal.count else { return 0 }
        var sum = 0.0
        for i in 0..<(signal.count - lag) {
            sum += signal[i] * signal[i + lag]
        }
        return sum / zeroLagEnergy
    }

    /// Finds the dominant period between `minPeriodSeconds` and `maxPeriodSeconds`.
    ///
    /// Returns the interpolated period and the autocorrelation strength at that lag (0...1),
    /// which doubles as a periodicity-quality score. Returns `nil` if there is no clear peak.
    static func dominantPeriod(
        _ rawSignal: [Double],
        sampleRateHz: Double,
        minPeriodSeconds: Double,
        maxPeriodSeconds: Double
    ) -> (periodSeconds: Double, strength: Double)? {
        let signal = Statistics.removeMean(rawSignal)
        let n = signal.count
        guard n > 4, sampleRateHz > 0 else { return nil }

        let zeroLagEnergy = signal.reduce(0) { $0 + $1 * $1 }
        guard zeroLagEnergy > .ulpOfOne else { return nil }

        let minLag = max(1, Int((minPeriodSeconds * sampleRateHz).rounded()))
        let maxLag = min(n - 2, Int((maxPeriodSeconds * sampleRateHz).rounded()))
        guard minLag < maxLag else { return nil }

        var correlations = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) where lag >= 1 && lag < n {
            correlations[lag] = value(signal, lag: lag, zeroLagEnergy: zeroLagEnergy)
        }

        // Best local maximum inside the search range.
        var bestLag = -1
        var bestValue = -Double.infinity
        for lag in minLag...maxLag {
            let c = correlations[lag]
            let isLocalMax = c >= correlations[lag - 1] && c >= correlations[lag + 1]
            if isLocalMax && c > bestValue {
                bestValue = c
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }

        // Parabolic interpolation on the lag axis.
        let yl = correlations[bestLag - 1]
        let yc = correlations[bestLag]
        let yr = correlations[bestLag + 1]
        var refinedLag = Double(bestLag)
        let denominator = yl - 2 * yc + yr
        if abs(denominator) > .ulpOfOne {
            refinedLag += 0.5 * (yl - yr) / denominator
        }

        let periodSeconds = refinedLag / sampleRateHz
        return (periodSeconds, max(0, min(1, bestValue)))
    }
}
