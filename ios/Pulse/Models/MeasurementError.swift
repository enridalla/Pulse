import Foundation

/// User-facing failures. Descriptions and recovery suggestions are localization keys resolved
/// in the UI, so no raw technical text ever reaches the user.
enum MeasurementError: Error, Equatable, Sendable {
    case accelerometerUnavailable
    case permissionDenied
    case insufficientSamples
    case invalidTimestamps
    case recordingTooShort
    case excessiveMotion
    case processingFailed
    case fileWriteFailed

    /// Localization key for a short title.
    var titleKey: String { "error.\(rawName).title" }
    /// Localization key for the explanatory message.
    var messageKey: String { "error.\(rawName).message" }

    /// Whether the raw recording was safely saved despite the error.
    var dataWasSaved: Bool {
        switch self {
        case .processingFailed: return true
        default: return false
        }
    }

    /// Whether retrying is meaningful.
    var isRetryable: Bool {
        switch self {
        case .accelerometerUnavailable: return false
        default: return true
        }
    }

    private var rawName: String {
        switch self {
        case .accelerometerUnavailable: return "accelerometerUnavailable"
        case .permissionDenied: return "permissionDenied"
        case .insufficientSamples: return "insufficientSamples"
        case .invalidTimestamps: return "invalidTimestamps"
        case .recordingTooShort: return "recordingTooShort"
        case .excessiveMotion: return "excessiveMotion"
        case .processingFailed: return "processingFailed"
        case .fileWriteFailed: return "fileWriteFailed"
        }
    }
}
