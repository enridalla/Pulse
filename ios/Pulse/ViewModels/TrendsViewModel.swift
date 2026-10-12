import Foundation
import Observation

struct TrendPoint: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
}

@MainActor
@Observable
final class TrendsViewModel {
    private let store: MeasurementStore
    private let settings: AppSettings
    private(set) var summaries: [MeasurementSummary] = []

    init(store: MeasurementStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        refresh()
    }

    var isEmpty: Bool { summaries.isEmpty }
    var count: Int { summaries.count }

    /// Charts add a light tick when the scrubbed sample changes, but only if the user has left the
    /// app's global haptic feedback on.
    var isHapticFeedbackEnabled: Bool { settings.feedbackEnabled }

    var respirationPoints: [TrendPoint] {
        ordered.compactMap { summary in
            summary.respiratoryRateBPM.map { TrendPoint(id: summary.id, date: summary.startedAt, value: $0) }
        }
    }

    var heartPoints: [TrendPoint] {
        ordered.compactMap { summary in
            summary.heartRateBPM.map { TrendPoint(id: summary.id, date: summary.startedAt, value: $0) }
        }
    }

    var respirationAverage: Double? { average(respirationPoints.map(\.value)) }
    var heartAverage: Double? { average(heartPoints.map(\.value)) }

    func refresh() {
        summaries = store.summaries
    }

    private var ordered: [MeasurementSummary] {
        summaries.sorted { $0.startedAt < $1.startedAt }
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
