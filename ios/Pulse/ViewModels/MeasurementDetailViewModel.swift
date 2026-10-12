import Foundation
import Observation

@MainActor
@Observable
final class MeasurementDetailViewModel {
    let summary: MeasurementSummary
    private let store: MeasurementStore
    private let onDelete: () -> Void

    private(set) var result: MeasurementResult?
    private(set) var isLoading = false
    private(set) var loadFailed = false

    init(summary: MeasurementSummary, store: MeasurementStore, onDelete: @escaping () -> Void = {}) {
        self.summary = summary
        self.store = store
        self.onDelete = onDelete
        // Load immediately when possible. This prevents the detail destination from flashing a
        // false "result unavailable" state before its task gets a chance to run.
        self.result = store.result(for: summary)
    }

    /// Loads the persisted result and, when needed, transparently rebuilds an old/missing result
    /// from the session's raw CSV. Reprocessing uses the same consolidated DSP pipeline and also
    /// upgrades legacy six-second heart previews to the current full-session preview.
    func load() async {
        if let result, !Self.needsPreviewUpgrade(result) {
            loadFailed = false
            return
        }

        guard let metadata = store.metadata(for: summary) else {
            loadFailed = result == nil
            return
        }

        let rawURL = store.rawCSVURL(for: summary)
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            loadFailed = result == nil
            return
        }

        isLoading = true
        loadFailed = false
        defer { isLoading = false }

        let appVersion = DeviceInfo.appVersion
        let rawName = MeasurementStore.rawCSVFileName
        let metadataName = MeasurementStore.metadataFileName

        do {
            let rebuilt = try await Task.detached(priority: .userInitiated) {
                let raw = try AccelerometerCSV.read(url: rawURL)
                return try CardiorespiratoryProcessor.process(
                    signal: raw,
                    configuration: metadata.configuration,
                    id: metadata.id,
                    startedAt: metadata.startedAt,
                    rawCSVFileName: rawName,
                    metadataFileName: metadataName,
                    appVersion: appVersion
                )
            }.value

            let folder = store.sessionFolder(for: summary)
            try store.saveResult(rebuilt, metadata: metadata, in: folder)
            result = rebuilt
        } catch {
            // Keep an already-decodable legacy result visible even if the optional preview upgrade
            // fails. Only show "unavailable" when no usable result exists at all.
            loadFailed = result == nil
        }
    }

    func rawCSVURL() -> URL? {
        let url = store.rawCSVURL(for: summary)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete() {
        store.delete(summary)
        onDelete()
    }

    private static func needsPreviewUpgrade(_ result: MeasurementResult) -> Bool {
        let respirationDuration: Double = {
            guard result.preview.respirationSampleRateHz > 0 else { return 0 }
            return Double(result.preview.respirationWaveform.count) / result.preview.respirationSampleRateHz
        }()
        let heartDuration: Double = {
            guard result.preview.heartWindowSampleRateHz > 0 else { return 0 }
            return Double(result.preview.heartWindowWaveform.count) / result.preview.heartWindowSampleRateHz
        }()

        // Older builds persisted only about six seconds of the heart-band signal. Current results
        // store the entire analysed interval so both charts share the same time axis.
        return respirationDuration > 15 && heartDuration < respirationDuration * 0.75
    }
}
