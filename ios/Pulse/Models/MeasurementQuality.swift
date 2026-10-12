import Foundation

/// Overall, human-readable verdict for a session. A category, never a false-precision percentage.
enum MeasurementQuality: String, Codable, Sendable, CaseIterable {
    case good
    case acceptable
    case poor
    case unreliable

    /// Maps a heuristic 0...1 score to a category.
    init(score: Double) {
        switch score {
        case 0.75...: self = .good
        case 0.5..<0.75: self = .acceptable
        case 0.3..<0.5: self = .poor
        default: self = .unreliable
        }
    }
}
