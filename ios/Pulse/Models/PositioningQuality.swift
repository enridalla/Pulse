import Foundation

/// Result of the short pre-recording signal check. Heuristic, not a probability.
struct PositioningQuality: Sendable, Equatable {
    /// Coarse verdict driving the on-screen message and colour.
    enum Level: Sendable, Equatable {
        case waiting        // still collecting the first samples
        case moving         // too much motion / orientation change
        case adjust         // sampling or contact looks wrong
        case stable         // good enough to record
    }

    let level: Level
    /// 0...1, higher = more motion (worse).
    let motionScore: Double
    /// 0...1, higher = more orientation change (worse).
    let orientationChangeScore: Double
    /// 0...1, higher = better sampling regularity.
    let samplingQualityScore: Double
    /// Localization key for the message shown to the user.
    let messageKey: String

    var isStable: Bool { level == .stable }

    static let waiting = PositioningQuality(
        level: .waiting,
        motionScore: 0,
        orientationChangeScore: 0,
        samplingQualityScore: 0,
        messageKey: "signalCheck.waiting"
    )
}
