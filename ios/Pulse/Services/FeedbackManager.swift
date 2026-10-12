import UIKit

/// Haptic feedback used **only** outside the acquisition window (before the countdown, at the end,
/// on errors) so it never mechanically contaminates the sensor. A single switch disables it all.
///
/// The feedback is intentionally strong: every event fires one or more **full-intensity heavy**
/// impacts (often several in a short burst), because a single soft tap is easy to miss when the
/// phone is resting on the chest. A repeated heavy burst is far more noticeable than one impact.
@MainActor
enum FeedbackManager {
    enum Event { case start, success, warning, error, selection }

    static func play(_ event: Event, enabled: Bool) {
        guard enabled else { return }
        switch event {
        case .start:
            heavyBurst(count: 3, interval: 0.11)
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            heavyBurst(count: 3, interval: 0.10, delay: 0.06)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            heavyBurst(count: 2, interval: 0.12, delay: 0.06)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            heavyBurst(count: 4, interval: 0.10, delay: 0.06)
        case .selection:
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred(intensity: 1.0)
        }
    }

    /// Fires `count` full-intensity heavy impacts spaced `interval` seconds apart, optionally after
    /// an initial `delay`. Several strong taps in a row are what make the feedback unmistakable.
    private static func heavyBurst(count: Int, interval: Double, delay: Double = 0) {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        for index in 0..<max(1, count) {
            let when = delay + Double(index) * interval
            if when <= 0 {
                generator.impactOccurred(intensity: 1.0)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + when) {
                    generator.impactOccurred(intensity: 1.0)
                    generator.prepare()
                }
            }
        }
    }
}
