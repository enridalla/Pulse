import Charts
import SwiftUI

struct TrendsView: View {
    let viewModel: TrendsViewModel
    let onStart: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty {
                    ContentUnavailableView {
                        Label("trends.empty.title", systemImage: "chart.line.uptrend.xyaxis")
                    } description: {
                        Text("trends.empty.message")
                    } actions: {
                        Button("home.startMeasurement", action: onStart)
                            .buttonStyle(.borderedProminent)
                            .tint(PulseColors.brand)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: PulseSpacing.lg) {
                            summaryCard

                            TrendChartCard(
                                title: "trends.respiration.title",
                                systemImage: "lungs.fill",
                                unit: "unit.bpm.resp",
                                tint: PulseColors.respiration,
                                points: viewModel.respirationPoints,
                                average: viewModel.respirationAverage,
                                hapticsEnabled: viewModel.isHapticFeedbackEnabled
                            )

                            TrendChartCard(
                                title: "trends.heart.title",
                                systemImage: "heart.fill",
                                unit: "unit.bpm",
                                tint: PulseColors.heart,
                                points: viewModel.heartPoints,
                                average: viewModel.heartAverage,
                                hapticsEnabled: viewModel.isHapticFeedbackEnabled
                            )

                            Text("trends.disclaimer")
                                .font(PulseTypography.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, PulseSpacing.xs)
                        }
                        .padding(.horizontal, PulseSpacing.md)
                        .padding(.top, PulseSpacing.xs)
                        .padding(.bottom, PulseSpacing.xl)
                    }
                    .background(PulseColors.canvas)
                }
            }
            .navigationTitle("tab.trends")
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.md) {
            SectionLabel(title: "trends.summary.title", systemImage: "chart.bar.xaxis")

            // Three columns normally; one column per row once the text is large enough that the
            // labels would otherwise be truncated.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: PulseSpacing.sm) {
                    ForEach(Array(summaryMetrics.enumerated()), id: \.offset) { index, metric in
                        if index > 0 { Divider() }
                        summaryMetric(metric)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(summaryMetrics.enumerated()), id: \.offset) { index, metric in
                        if index > 0 { verticalDivider }
                        summaryMetric(metric)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(PulseSpacing.md)
        .appSurface()
    }

    private typealias SummaryMetric = (
        title: LocalizedStringKey, value: String, unit: LocalizedStringKey?, tint: Color
    )

    private var summaryMetrics: [SummaryMetric] {
        [
            ("trends.summary.count", "\(viewModel.count)", nil, PulseColors.brand),
            (
                "trends.summary.respiration",
                viewModel.respirationAverage.map { Format.rate($0) } ?? "—",
                "unit.bpm.resp",
                PulseColors.respiration
            ),
            (
                "trends.summary.heart",
                viewModel.heartAverage.map { Format.integer($0) } ?? "—",
                "unit.bpm",
                PulseColors.heart
            ),
        ]
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(PulseColors.hairline)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, PulseSpacing.sm)
            .accessibilityHidden(true)
    }

    private func summaryMetric(_ metric: SummaryMetric) -> some View {
        let (title, value, unit, tint) = metric
        return VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(PulseTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(PulseTypography.title3)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(PulseTypography.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// One metric over time. Breathing and heart rate share this view, so they share their axes,
/// typography, selection behaviour and empty states — only the tint and the range differ.
private struct TrendChartCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let unit: LocalizedStringResource
    let tint: Color
    let points: [TrendPoint]
    let average: Double?
    let hapticsEnabled: Bool

    /// `scrubbedDate` follows the finger and is cleared by Swift Charts as soon as the gesture
    /// ends; `selectedID` latches the sample it landed on so a quick tap leaves the value on
    /// screen instead of flashing once.
    @State private var scrubbedDate: Date?
    @State private var selectedID: UUID?
    @ScaledMetric(relativeTo: .footnote) private var plotHeight: CGFloat = 148

    var body: some View {
        VStack(alignment: .leading, spacing: PulseSpacing.sm) {
            SectionLabel(title: title, systemImage: systemImage, tint: tint)

            if sorted.isEmpty {
                emptyPlot
            } else {
                readout
                chart

                if sorted.count == 1 {
                    Text("trends.needMore")
                        .font(PulseTypography.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(PulseSpacing.md)
        .appSurface()
        .onChange(of: points.count) { _, _ in
            selectedID = nil
            scrubbedDate = nil
        }
    }

    // MARK: Readout
    //
    /// A fixed line above the plot rather than a floating bubble: it shows the selected sample
    /// once one has been picked and the average until then, so nothing moves, overlaps or clips.
    private var readout: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(readoutValue.map { Format.rate($0) } ?? "—")
                    .font(PulseTypography.title3)
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(PulseTypography.caption)
                    .foregroundStyle(.secondary)
            }

            readoutCaption
                .font(PulseTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var readoutValue: Double? {
        if let selectedPoint { return selectedPoint.value }
        if sorted.count == 1 { return sorted.first?.value }
        return average
    }

    @ViewBuilder
    private var readoutCaption: some View {
        if let date = selectedPoint?.date ?? (sorted.count == 1 ? sorted.first?.date : nil) {
            Text(date, format: .dateTime.day().month(.abbreviated).year().hour().minute())
        } else {
            Text("trends.average")
        }
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            // A line only exists once there are two samples: a single measurement must never be
            // drawn as a trend.
            if sorted.count > 1 {
                // The tinted wash under the line carries no extra number; it gives the series a
                // body so the card still reads as "this metric" at a glance.
                ForEach(sorted) { point in
                    AreaMark(
                        x: .value(dateLabel, point.date),
                        y: .value(valueLabel, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [tint.opacity(0.22), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityHidden(true)
                }

                ForEach(sorted) { point in
                    LineMark(
                        x: .value(dateLabel, point.date),
                        y: .value(valueLabel, point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .accessibilityLabel(Text(point.date, format: .dateTime.day().month().year().hour().minute()))
                    .accessibilityValue(Text(Format.rate(point.value)) + Text(verbatim: " ") + Text(unit))
                }
            }

            if let average, sorted.count > 1 {
                RuleMark(y: .value(averageLabel, average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }

            if showsSymbols {
                ForEach(sorted) { point in
                    PointMark(
                        x: .value(dateLabel, point.date),
                        y: .value(valueLabel, point.value)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(36)
                    .accessibilityLabel(Text(point.date, format: .dateTime.day().month().year().hour().minute()))
                    .accessibilityValue(Text(Format.rate(point.value)) + Text(verbatim: " ") + Text(unit))
                }
            }

            if let selectedPoint {
                RuleMark(x: .value(dateLabel, selectedPoint.date))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                    .accessibilityHidden(true)

                // A ring, not just a colour change: the selected sample stays identifiable with
                // Increase Contrast, in grayscale and for colour-blind users.
                PointMark(
                    x: .value(dateLabel, selectedPoint.date),
                    y: .value(valueLabel, selectedPoint.value)
                )
                .foregroundStyle(tint)
                .symbol {
                    Circle()
                        .fill(tint)
                        .frame(width: 11, height: 11)
                        .overlay {
                            Circle().stroke(PulseColors.surface, lineWidth: 2.5)
                        }
                }
                .accessibilityHidden(true)
            }
        }
        // Selection follows the whole plot width, so the nearest sample is picked from anywhere
        // along the x axis instead of asking for a direct hit on a 7 pt dot.
        .chartXSelection(value: $scrubbedDate)
        .onChange(of: scrubbedDate) { _, date in
            guard let date, let nearest = nearest(to: date), nearest.id != selectedID else { return }
            selectedID = nearest.id
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel(format: xAxisFormat, centered: false)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        Text(Format.rate(rate))
                    }
                }
            }
        }
        .chartPlotStyle { $0.clipped() }
        .frame(height: plotHeight)
        .sensoryFeedback(.selection, trigger: selectedID) { previous, current in
            hapticsEnabled && current != nil && previous != current
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var emptyPlot: some View {
        VStack(spacing: PulseSpacing.xs) {
            IconBadge(systemImage: "chart.line.uptrend.xyaxis", tint: tint, size: 40)
            Text("trends.needMore")
                .font(PulseTypography.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }

    // MARK: Data

    private var sorted: [TrendPoint] {
        points.sorted { $0.date < $1.date }
    }

    /// Individual samples stay visible while they can be told apart; beyond that the line alone
    /// carries the trend and the x axis is left uncluttered.
    private var showsSymbols: Bool {
        sorted.count <= 14
    }

    private var selectedPoint: TrendPoint? {
        guard let selectedID else { return nil }
        return sorted.first { $0.id == selectedID }
    }

    /// Selection lands on the closest sample to wherever the finger is, so the whole plot width is
    /// the hit area instead of the 7 pt dots.
    private func nearest(to date: Date) -> TrendPoint? {
        sorted.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    /// Padded so the first and last samples are never drawn on the frame. Sessions recorded at the
    /// same instant (or a single session) would collapse the scale, hence the synthetic window.
    private var xDomain: ClosedRange<Date> {
        guard let first = sorted.first?.date, let last = sorted.last?.date else {
            let now = Date.now
            return now.addingTimeInterval(-3600)...now.addingTimeInterval(3600)
        }
        let span = last.timeIntervalSince(first)
        let padding = span > 0 ? max(span * 0.06, 60) : 6 * 3600
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    /// Never starts below zero: a rate cannot be negative, which also keeps a “−0” tick off the
    /// axis when the padding would otherwise cross zero.
    private var yDomain: ClosedRange<Double> {
        let values = sorted.map(\.value)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...1 }
        let padding = max((maximum - minimum) * 0.25, 2)
        return max(0, minimum - padding)...(maximum + padding)
    }

    /// Whole-number ticks, so two rounded labels can never read the same value.
    private var yTicks: [Double] {
        let lower = yDomain.lowerBound
        let upper = yDomain.upperBound
        let step = max(1, ((upper - lower) / 3).rounded())
        var ticks: [Double] = []
        var value = (lower / step).rounded(.up) * step
        while value <= upper && ticks.count < 8 {
            ticks.append(value)
            value += step
        }
        return ticks
    }

    /// Granularity follows the range that is actually on screen: clock time within a day, days
    /// over weeks, months over a year. No time detail is shown that the axis cannot resolve.
    private var xAxisFormat: Date.FormatStyle {
        guard let first = sorted.first?.date, let last = sorted.last?.date else {
            return .dateTime.day().month(.abbreviated)
        }
        switch last.timeIntervalSince(first) {
        case ..<(36 * 60 * 60):
            return .dateTime.hour().minute()
        case ..<(60 * 24 * 60 * 60):
            return .dateTime.day().month(.abbreviated)
        case ..<(400 * 24 * 60 * 60):
            return .dateTime.month(.abbreviated)
        default:
            return .dateTime.month(.abbreviated).year()
        }
    }

    // Series names, read aloud by VoiceOver when navigating the plot.
    private var dateLabel: String { String(localized: "trends.axis.date") }
    private var valueLabel: String { String(localized: unit) }
    private var averageLabel: String { String(localized: "trends.average") }
}
