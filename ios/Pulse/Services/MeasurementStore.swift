import Foundation
import Observation

/// File-based persistence for measurements.
///
/// Layout: `Documents/Measurements/<UUID>/{accelerometer.csv, metadata.json, result.json}`.
/// A lightweight `index.json` mirrors the folders so the lists load without opening every folder;
/// it is rebuilt automatically if missing or stale.
@MainActor
@Observable
final class MeasurementStore {
    private(set) var summaries: [MeasurementSummary] = []
    var lastError: String?

    var latest: MeasurementSummary? { summaries.first }
    var isEmpty: Bool { summaries.isEmpty }

    private let fileManager = FileManager.default

    // MARK: Paths

    static let rawCSVFileName = "accelerometer.csv"
    static let metadataFileName = "metadata.json"
    static let resultFileName = "result.json"

    var measurementsDirectory: URL {
        let dir = URL.documentsDirectory.appending(path: "Measurements", directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var indexURL: URL { measurementsDirectory.appending(path: "index.json") }

    func sessionFolder(for summary: MeasurementSummary) -> URL {
        measurementsDirectory.appending(path: summary.folderName, directoryHint: .isDirectory)
    }

    // MARK: Loading

    func load() {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? Self.decoder.decode([MeasurementSummary].self, from: data) {
            summaries = index.sorted { $0.startedAt > $1.startedAt }
        } else {
            rebuildIndex()
        }
    }

    /// Rebuilds the index by scanning every session folder. Corrupt or incomplete folders are
    /// skipped rather than crashing the list.
    func rebuildIndex() {
        var rebuilt: [MeasurementSummary] = []
        let folders = (try? fileManager.contentsOfDirectory(
            at: measurementsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for folder in folders where folder.hasDirectoryPath {
            guard
                let metadata = try? Self.decoder.decode(RecordingMetadata.self,
                    from: Data(contentsOf: folder.appending(path: Self.metadataFileName))),
                let result = try? Self.decoder.decode(MeasurementResult.self,
                    from: Data(contentsOf: folder.appending(path: Self.resultFileName)))
            else { continue }
            rebuilt.append(MeasurementSummary(metadata: metadata, result: result, folderName: folder.lastPathComponent))
        }
        summaries = rebuilt.sorted { $0.startedAt > $1.startedAt }
        persistIndex()
    }

    func result(for summary: MeasurementSummary) -> MeasurementResult? {
        let preferredFolder = sessionFolder(for: summary)
        let fallbackFolder = measurementsDirectory.appending(path: summary.id.uuidString, directoryHint: .isDirectory)
        let folders = preferredFolder == fallbackFolder ? [preferredFolder] : [preferredFolder, fallbackFolder]

        for folder in folders {
            let url = folder.appending(path: Self.resultFileName)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let decoded = try Self.decoder.decode(MeasurementResult.self, from: data)
                lastError = nil
                return decoded
            } catch {
                lastError = error.localizedDescription
            }
        }
        return nil
    }

    func metadata(for summary: MeasurementSummary) -> RecordingMetadata? {
        let url = sessionFolder(for: summary).appending(path: Self.metadataFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(RecordingMetadata.self, from: data)
    }

    // MARK: Saving

    /// Creates (or returns) the folder for a new session. The recorder writes the CSV here.
    func prepareSessionFolder(id: UUID) throws -> URL {
        let folder = measurementsDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    func saveMetadata(_ metadata: RecordingMetadata, in folder: URL) throws {
        let data = try Self.encoder.encode(metadata)
        try data.write(to: folder.appending(path: Self.metadataFileName), options: .atomic)
    }

    /// Persists the processing result and refreshes the index.
    func saveResult(_ result: MeasurementResult, metadata: RecordingMetadata, in folder: URL) throws {
        let data = try Self.encoder.encode(result)
        try data.write(to: folder.appending(path: Self.resultFileName), options: .atomic)
        let summary = MeasurementSummary(metadata: metadata, result: result, folderName: folder.lastPathComponent)
        summaries.removeAll { $0.id == summary.id }
        summaries.insert(summary, at: 0)
        summaries.sort { $0.startedAt > $1.startedAt }
        persistIndex()
    }

    // MARK: Deleting

    /// Deleting one session is deleting a batch of one: both entry points remove exactly the same
    /// files through the same code path.
    func delete(_ summary: MeasurementSummary) {
        delete([summary])
    }

    /// Removes every selected session in one pass. A folder that cannot be removed does not abort
    /// the batch: the sessions that were deleted still leave the index, so the list can never keep
    /// showing a measurement whose files are gone.
    func delete(_ selected: [MeasurementSummary]) {
        guard !selected.isEmpty else { return }

        var removed: Set<UUID> = []
        var failure: String?

        for summary in selected {
            do {
                for folder in folders(for: summary) where fileManager.fileExists(atPath: folder.path) {
                    try fileManager.removeItem(at: folder)
                }
                removed.insert(summary.id)
            } catch {
                failure = error.localizedDescription
            }
        }

        summaries.removeAll { removed.contains($0.id) }
        persistIndex()
        lastError = failure
    }

    /// Session folder plus the legacy `<uuid>` folder, mirroring the lookup done when reading a
    /// result, so deleting never leaves an orphaned directory behind.
    private func folders(for summary: MeasurementSummary) -> [URL] {
        let preferred = sessionFolder(for: summary)
        let legacy = measurementsDirectory.appending(path: summary.id.uuidString, directoryHint: .isDirectory)
        return preferred == legacy ? [preferred] : [preferred, legacy]
    }

    func deleteAll() {
        do {
            try fileManager.removeItem(at: measurementsDirectory)
            summaries = []
            persistIndex()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Export

    /// Path to a session's raw accelerometer CSV, used for per-session sharing.
    func rawCSVURL(for summary: MeasurementSummary) -> URL {
        sessionFolder(for: summary).appending(path: Self.rawCSVFileName)
    }

    /// One CSV per session, ready for the share sheet.
    ///
    /// Every session keeps its own file: selecting N measurements produces N CSVs, never an
    /// aggregate. The stored `accelerometer.csv` files are copied into a scratch folder because
    /// they all share the same name inside their session folder; the copies carry a readable,
    /// collision-free name so they survive AirDrop, Mail or "Save to Files" as distinct documents.
    /// Contents are copied verbatim — the CSV format is never rewritten here.
    func exportRawCSVs(for selected: [MeasurementSummary]) throws -> [URL] {
        guard !selected.isEmpty else { return [] }

        let directory = try makeExportDirectory()
        var takenNames: Set<String> = []
        var urls: [URL] = []

        for summary in selected.sorted(by: { $0.startedAt < $1.startedAt }) {
            let source = rawCSVURL(for: summary)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = directory.appending(path: Self.exportFileName(for: summary, taken: &takenNames))
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            urls.append(destination)
        }

        guard !urls.isEmpty else { throw MeasurementError.fileWriteFailed }
        return urls
    }

    /// `Pulse_2026-09-04_143208.csv`: sortable, readable and built from a fixed POSIX pattern, so
    /// it can never contain a separator or any other character that is invalid in a file name.
    /// Sessions that start within the same second get a `_2`, `_3`… suffix. The comparison is
    /// case-insensitive because the iOS file system is.
    private static func exportFileName(for summary: MeasurementSummary, taken: inout Set<String>) -> String {
        let base = "Pulse_" + exportNameFormatter.string(from: summary.startedAt)
        var candidate = base + ".csv"
        var index = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base)_\(index).csv"
            index += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    // MARK: Helpers

    private func persistIndex() {
        do {
            let data = try Self.encoder.encode(summaries)
            try data.write(to: indexURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A single scratch folder under `tmp`, rebuilt from scratch on every export. A new batch can
    /// therefore never mix with the previous one, and a cancelled share leaks nothing durable: the
    /// folder is replaced on the next export and the system purges `tmp` on its own.
    private func makeExportDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "PulseExport", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static let exportNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
