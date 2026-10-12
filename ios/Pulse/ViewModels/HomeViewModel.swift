import Foundation
import Observation

@MainActor
@Observable
final class HomeViewModel {
    private let store: MeasurementStore

    private(set) var latest: MeasurementSummary?

    init(store: MeasurementStore) {
        self.store = store
        refresh()
    }

    func refresh() {
        latest = store.latest
    }
}
