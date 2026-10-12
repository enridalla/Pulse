import Foundation
import Observation

/// User preferences that persist between launches. Backed by `UserDefaults`; no account, no cloud.
@MainActor
@Observable
final class AppSettings {
    var feedbackEnabled: Bool {
        didSet { defaults.set(feedbackEnabled, forKey: Keys.feedback) }
    }
    var hasSeenOnboarding: Bool {
        didSet { defaults.set(hasSeenOnboarding, forKey: Keys.onboarding) }
    }
    var defaultSubjectIdentifier: String {
        didSet { defaults.set(defaultSubjectIdentifier, forKey: Keys.subject) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        feedbackEnabled = defaults.object(forKey: Keys.feedback) as? Bool ?? true
        hasSeenOnboarding = defaults.bool(forKey: Keys.onboarding)
        defaultSubjectIdentifier = defaults.string(forKey: Keys.subject) ?? ""
    }

    private enum Keys {
        static let feedback = "settings.feedbackEnabled"
        static let onboarding = "settings.hasSeenOnboarding"
        static let subject = "settings.defaultSubjectIdentifier"
    }
}
