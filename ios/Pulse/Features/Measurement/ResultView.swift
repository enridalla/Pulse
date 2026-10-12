import SwiftUI

/// Post-measurement result screen shown at the end of the flow.
struct ResultView: View {
    let result: MeasurementResult
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ResultContentView(result: result)
                    .padding(AppSpacing.md)
            }
            .background(AppColor.groupedBackground)
            .navigationTitle(Format.date(result.startedAt))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("action.done", action: onDone)
                        .font(AppTypography.subheadlineSemibold)
                }
            }
        }
    }
}

/// Shared result body used at the end of a measurement and in history detail.
struct ResultContentView: View {
    let result: MeasurementResult
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var revealed = false
    
    var body: some View {
        VStack(spacing: AppSpacing.lg) {
            header
            vitalsCard
            if let notes = result.configuration.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                notesCard(notes)
            }
            chartsSection
            Text("disclaimer.short")
                .font(AppTypography.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.xs)
        }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 10)
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(AppAnimation.gentleSpring.delay(0.04)) { revealed = true }
            }
        }
    }

    private var analyzedDuration: Double {
        max(0, result.durationSeconds - result.excludedBeginningSeconds - result.excludedEndingSeconds)
    }

    private var header: some View {
        Text("result.title")
            .font(AppTypography.title2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.xs)
    }

    private var reliableRespiratoryValue: String? {
        result.respiratoryEstimate.isReliable ? result.respiratoryEstimate.rateBPM.map { Format.rate($0) } : nil
    }

    private var vitalsCard: some View {
        vitalsLayout {
            VitalMetric(
                title: "result.respiration",
                icon: "lungs.fill",
                tint: AppColor.respiration,
                value: reliableRespiratoryValue,
                unit: "unit.bpm.resp",
                footnote: result.respiratoryEstimate.isReliable ? nil : "reliability.respiration.unreliable"
            )

            vitalsDivider

            VitalMetric(
                title: "result.heart",
                icon: "heart.fill",
                tint: AppColor.heart,
                value: result.heartEstimate.isReliable ? result.heartEstimate.rateBPM.map { Format.integer($0) } : nil,
                unit: "unit.bpm",
                footnote: result.heartEstimate.isReliable ? nil : "reliability.heart.unreliable"
            )
        }
        .padding(AppSpacing.lg)
        .appSurface()
    }

    /// Side by side normally; stacked once the text is large enough that half a card would have to
    /// hyphenate or clip the metric names.
    private var vitalsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.md))
            : AnyLayout(HStackLayout(spacing: 0))
    }

    @ViewBuilder
    private var vitalsDivider: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Rectangle().fill(AppColor.hairline).frame(height: 1).accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(AppColor.hairline)
                .frame(width: 1, height: 96)
                .padding(.horizontal, AppSpacing.md)
                .accessibilityHidden(true)
        }
    }

    private var chartsSection: some View {
        VStack(spacing: AppSpacing.md) {
            SectionCard(
                title: "result.chart.respiration",
                systemImage: "lungs.fill",
                tint: AppColor.respiration
            ) {
                RespirationChart(preview: result.preview, durationSeconds: analyzedDuration)
            }

            if !result.preview.heartWindowWaveform.isEmpty {
                SectionCard(
                    title: "result.chart.heart",
                    systemImage: "heart.fill",
                    tint: AppColor.heart
                ) {
                    HeartBeatsChart(preview: result.preview, durationSeconds: analyzedDuration)
                }
            }
        }
    }


    private func notesCard(_ notes: String) -> some View {
        SectionCard(
            title: "config.notes.title",
            systemImage: "note.text",
            tint: AppColor.brand
        ) {
            Text(notes)
                .font(AppTypography.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }


}

private struct VitalMetric: View {
    let title: LocalizedStringKey
    let icon: String
    let tint: Color
    let value: String?
    let unit: LocalizedStringKey
    let footnote: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: AppSpacing.xs) {
                IconBadge(systemImage: icon, tint: tint, size: 32)
                Text(title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(AppTypography.metricLarge)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.75)
                    Text(unit)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(AppTypography.metricLarge)
                    .foregroundStyle(.secondary)
            }

            if let footnote {
                Text(footnote)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
