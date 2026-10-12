import Foundation

/// One second-order section (biquad) in Direct Form II transposed. `a0` is normalised to 1.
struct Biquad: Equatable {
    let b0, b1, b2, a1, a2: Double

    /// Gain applied to a constant (DC) input — used to initialise the section to steady state.
    private var dcGain: Double { (b0 + b1 + b2) / (1 + a1 + a2) }

    /// Filters a signal, starting from the steady state for `signal.first` so there is no
    /// spurious start-up step. Returns the filtered signal (same length).
    func filter(_ signal: [Double]) -> [Double] {
        guard let first = signal.first else { return signal }
        let g = dcGain
        // States that keep a constant input `first` perfectly steady (SciPy's lfilter_zi idea).
        var z1 = (g - b0) * first
        var z2 = (b2 - a2 * g) * first
        var output = [Double](repeating: 0, count: signal.count)
        for i in 0..<signal.count {
            let x = signal[i]
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            output[i] = y
        }
        return output
    }
}

/// A zero-phase Butterworth band-pass filter.
///
/// Design: the band-pass is a cascade of a Butterworth **high-pass** at the low edge and a
/// Butterworth **low-pass** at the high edge, each of the given `order`. Every second-order
/// section uses the audio-cookbook (RBJ) biquad with the classic Butterworth section quality
/// factors `Q_k = 1 / (2·cos((2k+1)π / 2N))`, which reproduces a maximally-flat passband.
///
/// Zero phase is obtained by forward–backward filtering (à la `filtfilt`): the sequence is
/// filtered, reversed, filtered again and reversed back. Each section is initialised to its
/// steady state, and both ends are odd-reflection padded to suppress edge transients.
///
/// Limitations vs SciPy: SciPy's `butter(N,[lo,hi],'bandpass')` designs a single order-`2N`
/// band-pass, whereas here the high-pass/low-pass cascade is used for clarity; the magnitude
/// responses are equivalent for well-separated edges. The padding length is finite, so a small
/// residual transient can remain for signals only a few periods long.
struct ButterworthBandpass {
    let sections: [Biquad]
    let padLength: Int

    init(order: Int, lowCutoffHz: Double, highCutoffHz: Double, sampleRateHz: Double) {
        precondition(order % 2 == 0 && order >= 2, "order must be even and >= 2")
        var built: [Biquad] = []
        for q in Self.butterworthQualityFactors(order: order) {
            built.append(Self.highpass(cutoffHz: lowCutoffHz, sampleRateHz: sampleRateHz, q: q))
            built.append(Self.lowpass(cutoffHz: highCutoffHz, sampleRateHz: sampleRateHz, q: q))
        }
        sections = built
        // Pad by ~1.5 cycles of the lowest frequency, which is where the longest transient lives.
        padLength = max(order * 3, Int((sampleRateHz / max(lowCutoffHz, 0.01) * 1.5).rounded()))
    }

    /// Zero-phase band-pass filtering.
    func filtfilt(_ signal: [Double]) -> [Double] {
        let n = signal.count
        guard n > 3 else { return signal }
        let pad = min(padLength, n - 1)
        let padded = Self.oddReflectionPad(signal, padLength: pad)

        var forward = padded
        for section in sections { forward = section.filter(forward) }

        var backward = Array(forward.reversed())
        for section in sections { backward = section.filter(backward) }
        backward.reverse()

        return Array(backward[pad..<(pad + n)])
    }

    // MARK: Section design

    static func butterworthQualityFactors(order: Int) -> [Double] {
        (0..<(order / 2)).map { k in
            let theta = Double(2 * k + 1) * .pi / Double(2 * order)
            return 1.0 / (2.0 * cos(theta))
        }
    }

    static func lowpass(cutoffHz: Double, sampleRateHz: Double, q: Double) -> Biquad {
        let w0 = 2 * .pi * cutoffHz / sampleRateHz
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 - cw) / 2) / a0,
            b1: (1 - cw) / a0,
            b2: ((1 - cw) / 2) / a0,
            a1: (-2 * cw) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func highpass(cutoffHz: Double, sampleRateHz: Double, q: Double) -> Biquad {
        let w0 = 2 * .pi * cutoffHz / sampleRateHz
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cw) / 2) / a0,
            b1: (-(1 + cw)) / a0,
            b2: ((1 + cw) / 2) / a0,
            a1: (-2 * cw) / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// Odd (point-symmetric) reflection padding: pad = 2·edge − mirror. Keeps slope continuous.
    static func oddReflectionPad(_ signal: [Double], padLength: Int) -> [Double] {
        guard padLength > 0, let first = signal.first, let last = signal.last else { return signal }
        let n = signal.count
        var result = [Double]()
        result.reserveCapacity(n + 2 * padLength)
        for i in stride(from: padLength, to: 0, by: -1) {
            result.append(2 * first - signal[min(i, n - 1)])
        }
        result.append(contentsOf: signal)
        for i in 1...padLength {
            result.append(2 * last - signal[max(n - 1 - i, 0)])
        }
        return result
    }
}

/// Zero-phase Butterworth low-pass filter used by the automatic heartbeat-template envelope.
///
/// The fourth-power cardiomechanical envelope is low-pass filtered at 3 Hz with a second-order
/// zero-phase Butterworth filter. Keeping this as an explicit filter rather than a moving average
/// makes the preprocessing step reproducible.
struct ButterworthLowpass {
    let sections: [Biquad]
    let padLength: Int

    init(order: Int, cutoffHz: Double, sampleRateHz: Double) {
        precondition(order % 2 == 0 && order >= 2, "order must be even and >= 2")
        precondition(cutoffHz > 0 && cutoffHz < sampleRateHz / 2, "invalid low-pass cutoff")
        sections = ButterworthBandpass.butterworthQualityFactors(order: order).map {
            ButterworthBandpass.lowpass(cutoffHz: cutoffHz, sampleRateHz: sampleRateHz, q: $0)
        }
        padLength = max(order * 3, Int((sampleRateHz / cutoffHz * 1.5).rounded()))
    }

    func filtfilt(_ signal: [Double]) -> [Double] {
        let n = signal.count
        guard n > 3 else { return signal }
        let pad = min(padLength, n - 1)
        let padded = ButterworthBandpass.oddReflectionPad(signal, padLength: pad)

        var forward = padded
        for section in sections { forward = section.filter(forward) }

        var backward = Array(forward.reversed())
        for section in sections { backward = section.filter(backward) }
        backward.reverse()

        return Array(backward[pad..<(pad + n)])
    }
}
