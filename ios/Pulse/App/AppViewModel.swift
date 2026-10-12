import Observation
import SwiftUI

enum AppTab: Hashable { case home, history, trends, info }

/// Composition root for Pulse.
///
/// The app view model owns the concrete services and exposes feature-specific view models to SwiftUI.
/// Views never reach into persistence, CoreMotion or DSP services directly.
@MainActor
@Observable
final class AppViewModel {
    private let settings: AppSettings
    private let store: MeasurementStore
    private let recorder: MotionRecorder

    let home: HomeViewModel
    let history: HistoryViewModel
    let trends: TrendsViewModel
    let information: InformationViewModel
    let measurement: MeasurementViewModel

    var selectedTab: AppTab = .home
    var isMeasuring = false

    init() {
        let settings = AppSettings()
        let store = MeasurementStore()
        let recorder = MotionRecorder()

        self.settings = settings
        self.store = store
        self.recorder = recorder
        self.home = HomeViewModel(store: store)
        self.history = HistoryViewModel(store: store)
        self.trends = TrendsViewModel(store: store, settings: settings)
        self.information = InformationViewModel(store: store)
        self.measurement = MeasurementViewModel(recorder: recorder, store: store, settings: settings)

        self.history.onChange = { [weak self] in self?.refreshFeatures() }
        self.information.onChange = { [weak self] in self?.refreshFeatures() }
    }

    func load() {
        store.load()
        refreshFeatures()
    }

    func presentMeasurement() {
        measurement.startNewMeasurement()
        isMeasuring = true
    }

    func finishMeasurement() {
        isMeasuring = false
        store.load()
        refreshFeatures()
    }

    func cancelMeasurement() {
        measurement.cancelFlow()
        isMeasuring = false
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard phase != .active else { return }
        measurement.handleResignActive()
    }

    func refreshFeatures() {
        home.refresh()
        history.refresh()
        trends.refresh()
    }
}
