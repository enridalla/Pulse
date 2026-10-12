import Foundation
import Observation

@MainActor
@Observable
final class HistoryViewModel {
    private let store: MeasurementStore
    private(set) var summaries: [MeasurementSummary] = []
    var onChange: (() -> Void)?

    init(store: MeasurementStore) {
        self.store = store
        refresh()
    }

    var isEmpty: Bool { summaries.isEmpty }

    func refresh() {
        summaries = store.summaries
    }

    // MARK: Selection

    /// The selected sessions in list order. Selection is held by the view as a set of ids, so every
    /// batch action resolves it here and nowhere else.
    func selected(_ ids: Set<UUID>) -> [MeasurementSummary] {
        summaries.filter { ids.contains($0.id) }
    }

    // MARK: Delete

    /// Deleting one row (swipe, detail screen) and deleting a selection share this single path.
    func delete(_ summary: MeasurementSummary) {
        delete([summary])
    }

    func delete(ids: Set<UUID>) {
        delete(selected(ids))
    }

    private func delete(_ summaries: [MeasurementSummary]) {
        guard !summaries.isEmpty else { return }
        store.delete(summaries)
        refresh()
        onChange?()
    }

    // MARK: Export

    /// One CSV per selected session, so N selected measurements reach the share sheet as N files.
    func exportCSVs(ids: Set<UUID>) throws -> [URL] {
        try store.exportRawCSVs(for: selected(ids))
    }

    func makeDetailViewModel(for summary: MeasurementSummary) -> MeasurementDetailViewModel {
        MeasurementDetailViewModel(summary: summary, store: store, onDelete: { [weak self] in
            self?.refresh()
            self?.onChange?()
        })
    }
}
