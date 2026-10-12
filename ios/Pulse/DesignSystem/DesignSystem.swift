import SwiftUI

enum AppSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
    static let xl: CGFloat = 30
    static let xxl: CGFloat = 44
    static let xxxl: CGFloat = 44
}

enum AppRadius {
    static let small: CGFloat = 12
    static let medium: CGFloat = 16
    static let card: CGFloat = 24
    static let large: CGFloat = 30
}

enum AppTypography {
    // Single type family across the whole app: native SF Pro.
    static let largeDisplay = Font.system(.largeTitle, design: .default, weight: .bold)
    static let display = Font.system(size: 54, weight: .semibold, design: .default)
    static let metric = Font.system(size: 36, weight: .semibold, design: .default)
    static let metricLarge = Font.system(size: 40, weight: .semibold, design: .default)
    static let metricXL = Font.system(size: 116, weight: .bold, design: .default)

    static let title = Font.system(.title2, design: .default, weight: .semibold)
    static let title2 = Font.system(.title2, design: .default, weight: .bold)
    static let title3 = Font.system(.title3, design: .default, weight: .semibold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let headlineMedium = Font.system(.headline, design: .default, weight: .medium)
    static let sectionTitle = Font.system(.headline, design: .default, weight: .semibold)
    static let body = Font.system(.body, design: .default)
    static let bodySemibold = Font.system(.body, design: .default, weight: .semibold)
    static let bodyMedium = Font.system(.body, design: .default, weight: .medium)
    static let subheadline = Font.system(.subheadline, design: .default)
    static let subheadlineSemibold = Font.system(.subheadline, design: .default, weight: .semibold)
    static let subheadlineMedium = Font.system(.subheadline, design: .default, weight: .medium)
    static let footnote = Font.system(.footnote, design: .default)
    static let footnoteSemibold = Font.system(.footnote, design: .default, weight: .semibold)
    static let footnoteMedium = Font.system(.footnote, design: .default, weight: .medium)
    static let caption = Font.system(.caption, design: .default)
    static let captionMedium = Font.system(.caption, design: .default, weight: .medium)
    static let captionSemibold = Font.system(.caption, design: .default, weight: .semibold)
    static let caption2 = Font.system(.caption2, design: .default)
    static let mono = Font.system(.footnote, design: .default, weight: .medium)
}

enum AppAnimation {
    static let standard = Animation.easeInOut(duration: 0.28)
    static let gentleSpring = Animation.spring(response: 0.44, dampingFraction: 0.88)
    static let quick = Animation.easeOut(duration: 0.16)

    static func breathing(cycleSeconds: Double) -> Animation {
        .easeInOut(duration: cycleSeconds / 2)
    }

    static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum AppColor {
    // Pulse uses one calm indigo family. Physiological accents only appear where they carry meaning.
    static let brand = Color(light: 0x5557D9, dark: 0x8D90FF)
    static let brandDeep = Color(light: 0x4042B8, dark: 0xB2B4FF)
    static let respiration = Color(light: 0x239B91, dark: 0x63D4C8)
    static let heart = Color(light: 0xE56B7D, dark: 0xFF8FA0)

    static let good = Color(light: 0x2D8A61, dark: 0x68D7A3)
    static let acceptable = Color(light: 0x377E9C, dark: 0x6DBBDD)
    static let poor = Color(light: 0xC8792B, dark: 0xF0AD61)
    static let unreliable = Color(light: 0x777983, dark: 0xA6A8B2)

    static let canvas = Color(light: 0xF5F6FA, dark: 0x0C0E13)
    static let surface = Color(light: 0xFFFFFF, dark: 0x181B22)
    static let surfaceMuted = Color(light: 0xECEEF5, dark: 0x222630)
    static let softBrand = Color(light: 0xECECFF, dark: 0x292A45)
    static let hairline = Color(light: 0xE4E6EE, dark: 0x2B2F39)

    // Backwards-compatible names used in the feature views.
    static let cardBackground = surface
    static let groupedBackground = canvas

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [brand, Color(light: 0x6669E5, dark: 0x7477E8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func quality(_ quality: MeasurementQuality) -> Color {
        switch quality {
        case .good: return good
        case .acceptable: return acceptable
        case .poor: return poor
        case .unreliable: return unreliable
        }
    }
}

struct AppSurfaceModifier: ViewModifier {
    var radius: CGFloat = AppRadius.card
    var elevated: Bool = true

    func body(content: Content) -> some View {
        content
            .background(AppColor.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(
                color: Color.black.opacity(elevated ? 0.055 : 0),
                radius: elevated ? 18 : 0,
                x: 0,
                y: elevated ? 7 : 0
            )
    }
}

extension View {
    func appSurface(radius: CGFloat = AppRadius.card, elevated: Bool = true) -> some View {
        modifier(AppSurfaceModifier(radius: radius, elevated: elevated))
    }
}

extension Color {
    init(light: UInt, dark: UInt) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}


// MARK: - Naming compatibility
//
// The original Pulse look above is the single source of truth. Views written against the newer
// `Pulse*` names read the very same tokens through these aliases, so there is only ever one
// palette, one spacing scale and one type ramp in the app.

typealias PulseSpacing = AppSpacing
typealias PulseTypography = AppTypography
typealias PulseAnimation = AppAnimation
typealias PulseColors = AppColor

/// Geometry and interaction constants, expressed in terms of the scales above.
enum PulseMetrics {
    static let screenHorizontalPadding = AppSpacing.lg
    static let cardRadius = AppRadius.card
    static let compactRadius = AppRadius.medium
    static let controlHeight: CGFloat = 50
    static let minimumTouchTarget: CGFloat = 44
}
