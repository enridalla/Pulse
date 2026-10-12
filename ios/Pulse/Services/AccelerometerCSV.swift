import Foundation

/// CSV header shared by writing and reading. Columns are time (s) and tri-axial acceleration (g).
enum AccelerometerCSV {
    static let header = "time_s,acceleration_x_g,acceleration_y_g,acceleration_z_g"

    /// Reads a stored raw accelerometer CSV back into arrays for reprocessing.
    static func read(url: URL) throws -> RawSignal {
        let content = try String(contentsOf: url, encoding: .utf8)
        var times = [Double](), xs = [Double](), ys = [Double](), zs = [Double]()
        for (index, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if index == 0 && line.hasPrefix("time_s") { continue }
            let fields = line.split(separator: ",")
            guard fields.count == 4,
                  let t = Double(fields[0]), let x = Double(fields[1]),
                  let y = Double(fields[2]), let z = Double(fields[3]) else { continue }
            times.append(t); xs.append(x); ys.append(y); zs.append(z)
        }
        return RawSignal(times: times, x: xs, y: ys, z: zs)
    }
}

/// Streaming CSV writer. Buffers text and flushes in blocks so the sensor handler stays cheap,
/// and writes to a `.partial` file that is renamed atomically on `finalize()` so an interrupted
/// session never leaves a truncated `accelerometer.csv`.
final class AccelerometerCSVWriter {
    private let finalURL: URL
    private let partialURL: URL
    private let handle: FileHandle
    private var buffer = Data()
    private let posixLocale = Locale(identifier: "en_US_POSIX")
    private(set) var sampleCount = 0

    init(url: URL) throws {
        finalURL = url
        partialURL = url.deletingPathExtension().appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)
        guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
            throw MeasurementError.fileWriteFailed
        }
        handle = try FileHandle(forWritingTo: partialURL)
        try writeText(AccelerometerCSV.header + "\n")
    }

    func append(timeSeconds: Double, x: Double, y: Double, z: Double) throws {
        let line = String(format: "%.6f,%.6f,%.6f,%.6f\n", locale: posixLocale, timeSeconds, x, y, z)
        buffer.append(Data(line.utf8))
        sampleCount += 1
        if buffer.count >= 64 * 1024 { try flush() }
    }

    /// Flushes, closes and atomically moves the file into place.
    func finalize() throws {
        try flush()
        try handle.synchronize()
        try handle.close()
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
    }

    /// Discards the partial file (used when a session is cancelled).
    func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partialURL)
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func writeText(_ text: String) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}
