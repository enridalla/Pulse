import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = AppColor.brand
    var light = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                light ? Color.white.opacity(configuration.isPressed ? 0.88 : 0.98)
                      : tint.opacity(configuration.isPressed ? 0.86 : 1),
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
            )
            .foregroundStyle(light ? tint : Color.white)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AppAnimation.quick, value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = AppColor.brand

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                AppColor.surfaceMuted.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
            )
            .foregroundStyle(tint)
    }
}

struct SectionCard<Content: View>: View {
    var title: LocalizedStringKey?
    var systemImage: String?
    var tint: Color = AppColor.brand
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            if let title {
                HStack(spacing: AppSpacing.sm) {
                    if let systemImage {
                        IconBadge(systemImage: systemImage, tint: tint, size: 32)
                    }
                    Text(title)
                        .font(AppTypography.sectionTitle)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .appSurface()
    }
}

struct SectionLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: Color = AppColor.brand

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            if let systemImage {
                IconBadge(systemImage: systemImage, tint: tint, size: 30)
            }
            Text(title)
                .font(AppTypography.headline)
            Spacer(minLength: 0)
        }
    }
}

struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous))
    }
}

// MARK: - Components used by the newer screens
//
// Same visual language as the section cards above: one surface colour, the soft card elevation,
// and a tinted icon badge for section titles.

struct PulseCard<Content: View>: View {
    var padding: CGFloat = AppSpacing.md
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .appSurface()
    }
}

struct PulseSectionHeader: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var tint: Color = AppColor.brand

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout {
            if let systemImage {
                IconBadge(systemImage: systemImage, tint: tint, size: 30)
            }
            Text(title)
                .font(AppTypography.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// At accessibility sizes the badge moves above the title: sharing the line would leave the
    /// title too narrow and the system would hyphenate it mid-word.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppSpacing.xs))
            : AnyLayout(HStackLayout(spacing: AppSpacing.sm))
    }
}

struct PulseMetricCard: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: String?
    let unit: LocalizedStringKey

    var body: some View {
        PulseCard(padding: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: systemImage)
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value ?? "—")
                        .font(.system(size: 32, weight: .semibold, design: .default))
                        .foregroundStyle(value == nil ? Color.secondary : Color.primary)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Text(unit)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            // Lets a pair of cards share one height: a title that wraps in one language must not
            // push its own value down relative to the card beside it.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PulsePrimaryButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.sm) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
    }
}

struct PulseDestructiveButton: View {
    let title: LocalizedStringKey
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: AppSpacing.sm) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
        }
        .buttonStyle(SecondaryButtonStyle(tint: AppColor.heart))
    }
}

struct PulseEmptyState: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var systemImage: String = "waveform.path.ecg"
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            IconBadge(systemImage: systemImage, tint: AppColor.brand, size: 46)

            Text(title)
                .font(AppTypography.headline)

            Text(message)
                .font(AppTypography.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, AppSpacing.xs)
                    .padding(.horizontal, AppSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(AppSpacing.lg)
    }
}
