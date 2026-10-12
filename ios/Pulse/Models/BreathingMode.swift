import Foundation

/// How the subject was asked to breathe during a measurement.
///
/// `free` = normal spontaneous breathing. `guided` = the app showed an expanding/contracting
/// guide at a target rate (a full inhale+exhale cycle lasts `60 / target` seconds).
enum BreathingMode: Codable, Sendable, Equatable, Hashable {
    case free
    case guided(targetBreathsPerMinute: Double)

    var isGuided: Bool {
        if case .guided = self { return true }
        return false
    }

    /// Target breaths-per-minute for guided sessions, otherwise `nil`.
    var targetBreathsPerMinute: Double? {
        if case let .guided(target) = self { return target }
        return nil
    }

    /// Duration of one full breathing cycle at the target rate, in seconds.
    var cycleDurationSeconds: Double? {
        guard let target = targetBreathsPerMinute, target > 0 else { return nil }
        return 60.0 / target
    }

    /// Stable identifier used in exported CSV files.
    var exportName: String {
        isGuided ? "guided" : "free"
    }
}
