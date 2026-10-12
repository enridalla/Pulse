import Foundation

/// Locale-aware formatting for the small set of numbers shown in the UI. Kept in one place so the
/// app never prints raw `%.2f` values with the wrong decimal separator.
enum Format {
    static func rate(_ value: Double, fractionDigits: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    static func integer(_ value: Double) -> String {
        value.rounded().formatted(.number.precision(.fractionLength(0)))
    }

    static func hertz(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// mm:ss for elapsed/remaining time.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func durationDescription(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func signedError(_ value: Double) -> String {
        let formatted = abs(value).formatted(.number.precision(.fractionLength(1)))
        return value >= 0 ? "+\(formatted)" : "−\(formatted)"
    }
}
