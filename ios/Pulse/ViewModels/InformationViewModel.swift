import Observation

@MainActor
@Observable
final class InformationViewModel {
    private let store: MeasurementStore
    var onChange: (() -> Void)?

    init(store: MeasurementStore) {
        self.store = store
    }

    func deleteAllData() {
        store.deleteAll()
        onChange?()
    }
}
