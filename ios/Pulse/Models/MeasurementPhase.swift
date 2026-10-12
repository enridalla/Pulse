import Foundation

/// Explicit state machine for the guided measurement flow. A single enum instead of a set of
/// independent booleans. Associated data (countdown value, error, result) lives on the model.
enum MeasurementPhase: Equatable, Sendable {
    case configuration
    case preparation
    case positioning
    case signalCheck
    case countdown
    case recording
    case processing
    case completed
    case failed

    /// Phases during which the accelerometer must be running.
    var usesSensor: Bool {
        switch self {
        case .signalCheck, .recording: return true
        default: return false
        }
    }
}
