import SwiftUI

struct HomeView: View {
    let viewModel: HomeViewModel
    let onStart: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    brandHeader
                    measurementPanel
                    latestMeasurement
                    disclaimer
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.lg)
                .padding(.top, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xxl)
            }
            .background(AppColor.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var brandHeader: some View {
        HStack(spacing: AppSpacing.sm) {
            PulseMark(size: 38)

            Text("Pulse")
                .font(AppTypography.title2)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var measurementPanel: some View {
        ZStack(alignment: .topTrailing) {
            PulseGlyph()
                .stroke(
                    AppColor.brand.opacity(0.07),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 178, height: 92)
                .rotationEffect(.degrees(-4))
                .offset(x: 36, y: 16)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("home.hero.title")
                        .font(AppTypography.largeDisplay)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("home.subtitle")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 292, alignment: .leading)
                }

                Spacer(minLength: 26)

                Button(action: onStart) {
                    HStack(spacing: AppSpacing.sm) {
                        Text("home.startMeasurement")
                            .font(AppTypography.headline)
                            .fixedSize(horizontal: false, vertical: true)

                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: AppSpacing.sm)

                            Image(systemName: "arrow.right")
                                .font(AppTypography.subheadlineSemibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 15)
                }
                .buttonStyle(HomePrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, minHeight: 216, alignment: .topLeading)
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, 24)
        }
        .background(HomePanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .stroke(AppColor.brand.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var latestMeasurement: some View {
        if let latest = viewModel.latest {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                // Title and date share a line only while both still fit; at accessibility sizes
                // they stack instead of hyphenating.
                headerLayout {
                    Text("home.latest")
                        .font(AppTypography.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: AppSpacing.sm)
                    }

                    Text(Format.date(latest.startedAt))
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }

                metricsLayout {
                    HomeMetric(
                        title: "home.metric.respiration",
                        systemImage: "lungs.fill",
                        tint: AppColor.respiration,
                        value: latest.respiratoryRateBPM.map { Format.rate($0) },
                        unit: "unit.bpm.resp"
                    )

                    metricDivider

                    HomeMetric(
                        title: "home.metric.heart",
                        systemImage: "heart.fill",
                        tint: AppColor.heart,
                        value: latest.heartRateBPM.map { Format.integer($0) },
                        unit: "unit.bpm"
                    )
                }
            }
            .padding(.horizontal, AppSpacing.lg)
            .padding(.vertical, AppSpacing.md)
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
                    .stroke(AppColor.hairline.opacity(0.70), lineWidth: 1)
            }
        }
    }

    /// Title and date sit on a shared text baseline.
    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 0))
    }

    /// Side by side normally; stacked once the text is large enough that a half-width metric
    /// would have to hyphenate or clip. Centre alignment is what keeps the fixed-height divider
    /// level with the two columns — a text baseline would push it out of the row.
    private var metricsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.md))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 0))
    }

    @ViewBuilder
    private var metricDivider: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Rectangle()
                .fill(AppColor.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(AppColor.hairline)
                .frame(width: 1, height: 66)
                .padding(.horizontal, AppSpacing.lg)
                .accessibilityHidden(true)
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: AppSpacing.xs) {
            Image(systemName: "info.circle")
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(.tertiary)
                .padding(.top, 1)

            Text("disclaimer.short")
                .font(AppTypography.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.xs)
        .padding(.top, AppSpacing.xs)
    }
}

private struct HomePanelBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                AppColor.softBrand.opacity(0.90),
                AppColor.surface,
                AppColor.surface
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct HomePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                AppColor.brand.opacity(configuration.isPressed ? 0.86 : 1),
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AppAnimation.quick, value: configuration.isPressed)
    }
}

private struct PulseMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(AppColor.softBrand)

            PulseGlyph()
                .stroke(
                    AppColor.brand,
                    style: StrokeStyle(
                        lineWidth: max(2, size * 0.065),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .padding(size * 0.20)
        }
        .frame(width: size, height: size)
    }
}

private struct PulseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: 0, y: h * 0.56))
        path.addLine(to: CGPoint(x: w * 0.23, y: h * 0.56))
        path.addLine(to: CGPoint(x: w * 0.37, y: h * 0.27))
        path.addLine(to: CGPoint(x: w * 0.53, y: h * 0.76))
        path.addLine(to: CGPoint(x: w * 0.68, y: h * 0.42))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.56))
        path.addLine(to: CGPoint(x: w, y: h * 0.56))

        return path
    }
}

private struct HomeMetric: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: String?
    let unit: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(tint)

                Text(title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .minimumScaleFactor(0.75)
                    .contentTransition(.numericText())

                Text(unit)
                    .font(AppTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
