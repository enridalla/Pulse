import Charts
import SwiftUI

/// The two signal charts shown after a measurement and in a session's detail.
///
/// Each answers one question and shows nothing else: *was the breathing regular?* and *were the
/// individual heartbeats found?* The vertical axis is deliberately hidden — the waveforms are
/// normalised to ±1, so an amplitude number would be noise, not information. For the same reason
/// there is no scrubbing here: one sample of a filtered signal means nothing on its own.

private struct WavePoint: Identifiable {
    let id: Int
    let time: Double
    let value: Double
}

private func wavePoints(_ samples: [Double], sampleRateHz: Double, startTimeSeconds: Double = 0) -> [WavePoint] {
    guard sampleRateHz > 0 else { return [] }
    return samples.enumerated().map {
        WavePoint(
            id: $0.offset,
            time: startTimeSeconds + (Double($0.offset) / sampleRateHz),
            value: $0.element
        )
    }
}

/// One shared time scale for all result charts. Keeping the tick values explicit prevents Swift
/// Charts from choosing a different spacing for the respiratory and cardiac plots.
private func timeAxisValues(durationSeconds: Double) -> [Double] {
    guard durationSeconds > 0 else { return [0] }

    let end = max(1, durationSeconds)
    let mid = (end / 2).rounded()
    return [0, mid, end.rounded()].removingNearDuplicates()
}

/// Waveforms are normalised to ±1, so a symmetric range keeps the trace centred and gives both
/// charts the same vertical grammar. Legacy results that were not normalised still fit.
private func symmetricDomain(_ samples: [Double]) -> ClosedRange<Double> {
    let bound = max(samples.map(abs).max() ?? 1, 0.001) * 1.08
    return (-bound)...bound
}

private extension Array where Element == Double {
    func removingNearDuplicates(tolerance: Double = 0.5) -> [Double] {
        var output: [Double] = []
        for value in self {
            if output.last.map({ abs($0 - value) < tolerance }) != true {
                output.append(value)
            }
        }
        return output
    }
}

/// Filtered respiration waveform over the analysed portion of the recording: one rise and fall per
/// breath, so the shape alone shows whether the breathing was regular.
struct RespirationChart: View {
    let preview: SignalPreview
    let durationSeconds: Double

    var body: some View {
        let points = wavePoints(preview.respirationWaveform, sampleRateHz: preview.respirationSampleRateHz)

        SignalChartLayout(
            isPlottable: points.count > 2,
            accessibilityLabel: "chart.respiration.accessibility",
            accessibilityValue: Text(Format.durationDescription(durationSeconds))
        ) {
            Chart {
                RuleMark(y: .value(amplitudeLabel, 0))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(PulseColors.hairline)

                ForEach(points) { point in
                    LineMark(
                        x: .value(timeLabel, point.time),
                        y: .value(amplitudeLabel, point.value)
                    )
                    .foregroundStyle(PulseColors.respiration)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                }
            }
            .signalChartAxes(
                durationSeconds: durationSeconds,
                yDomain: symmetricDomain(preview.respirationWaveform)
            )
        }
    }
}

/// Heart-band trace with a marker on every detected beat, over the same time axis as respiration.
struct HeartBeatsChart: View {
    let preview: SignalPreview
    let durationSeconds: Double

    var body: some View {
        let points = wavePoints(
            preview.heartWindowWaveform,
            sampleRateHz: preview.heartWindowSampleRateHz,
            startTimeSeconds: preview.heartWindowStartSeconds
        )

        SignalChartLayout(
            isPlottable: points.count > 2,
            accessibilityLabel: "chart.heart.accessibility",
            accessibilityValue: Text("chart.heart.beats \(beats.count)")
        ) {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value(timeLabel, point.time),
                        y: .value(amplitudeLabel, point.value)
                    )
                    .foregroundStyle(PulseColors.heart.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }

                // A dot on the trace rather than a vertical rule: it reads as "this is the beat
                // that was found here" instead of laying a second grid over the signal.
                ForEach(beats) { beat in
                    PointMark(
                        x: .value(timeLabel, beat.time),
                        y: .value(amplitudeLabel, beat.value)
                    )
                    .foregroundStyle(PulseColors.heart)
                    .symbolSize(beats.count > 90 ? 14 : 26)
                }
            }
            .signalChartAxes(
                durationSeconds: durationSeconds,
                yDomain: symmetricDomain(preview.heartWindowWaveform)
            )
        }
    }

    /// Beats placed on the waveform itself, by sampling the trace at each detected beat time.
    /// Display only: the beat times come straight from the persisted result.
    private var beats: [WavePoint] {
        let rate = preview.heartWindowSampleRateHz
        let waveform = preview.heartWindowWaveform
        guard rate > 0, !waveform.isEmpty else { return [] }

        return preview.heartBeatOffsetsSeconds.enumerated().compactMap { index, offset in
            let sample = Int((offset * rate).rounded())
            guard waveform.indices.contains(sample) else { return nil }
            return WavePoint(
                id: index,
                time: preview.heartWindowStartSeconds + offset,
                value: waveform[sample]
            )
        }
    }
}

// MARK: - Shared chart chrome

private let timeLabel = String(localized: "chart.axis.time")
private let amplitudeLabel = String(localized: "chart.axis.amplitude")

/// Plot plus the spoken summary that replaces it for VoiceOver. Shared so the two charts cannot
/// drift apart.
private struct SignalChartLayout<Content: View>: View {
    let isPlottable: Bool
    let accessibilityLabel: LocalizedStringKey
    let accessibilityValue: Text
    @ViewBuilder let content: Content

    @ScaledMetric(relativeTo: .footnote) private var plotHeight: CGFloat = 150

    var body: some View {
        Group {
            if isPlottable {
                content
            } else {
                // Too few samples to draw anything honest.
                Text("chart.unavailable")
                    .font(PulseTypography.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: plotHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(accessibilityValue)
    }
}

/// Keeps the outermost time labels inside the plot area.
private func edgeAnchor(for index: Int, count: Int) -> UnitPoint {
    if index == 0 { return .topLeading }
    if index == count - 1 { return .topTrailing }
    return .top
}

private extension View {
    /// The axis treatment both signal charts share: time on x, no y labels, light grid.
    func signalChartAxes(durationSeconds: Double, yDomain: ClosedRange<Double>) -> some View {
        chartXScale(domain: 0...max(1, durationSeconds))
            .chartYScale(domain: yDomain)
            .chartYAxis(.hidden)
            .chartXAxis {
                let ticks = timeAxisValues(durationSeconds: durationSeconds)
                AxisMarks(values: ticks) { mark in
                    AxisGridLine()
                    // The first and last labels are pulled inside the plot; centred on the edge
                    // they would be clipped by the card.
                    AxisValueLabel(anchor: edgeAnchor(for: mark.index, count: ticks.count)) {
                        if let seconds = mark.as(Double.self) {
                            Text("chart.axis.seconds \(Int(seconds.rounded()))")
                        }
                    }
                }
            }
    }
}
