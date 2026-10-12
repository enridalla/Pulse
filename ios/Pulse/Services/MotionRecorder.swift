import CoreMotion
import Foundation
import Observation
import QuartzCore

/// Cheap, Sendable snapshot handed from the sensor queue to the main actor for the live UI.
struct MotionSnapshot: Sendable {
    var elapsedSeconds: Double = 0
    var sampleCount: Int = 0
    var observedRateHz: Double = 0
    var recentStd: Double = 0
    var orientationChange: Double = 0
    var waveform: [Double] = []
}

/// Owns the growing sample buffers, the rolling analysis window and the CSV writer. All of its
/// methods run **only** on the serial motion queue, so its mutable state needs no extra locking;
/// the main actor only reads it after the sensor has stopped and the queue has drained.
private final class RecordingSession: @unchecked Sendable {
    private(set) var times = [Double]()
    private(set) var xs = [Double]()
    private(set) var ys = [Double]()
    private(set) var zs = [Double]()

    private var firstTimestamp: Double?
    private var writer: AccelerometerCSVWriter?

    // Rolling window (~2 s) for the live stability estimate.
    private let windowCapacity: Int
    private var windowX = [Double](), windowY = [Double](), windowZ = [Double](), windowMag = [Double]()
    private var slowMeanMagnitude = 1.0
    private var waveform = [Double]()
    private let waveformCapacity = 150

    init(writer: AccelerometerCSVWriter?, windowCapacity: Int) {
        self.writer = writer
        self.windowCapacity = windowCapacity
    }

    var count: Int { times.count }

    /// Ingests one sample using the Core Motion timestamp as the time source. Returns the running
    /// sample count so the caller can throttle the UI without touching main-actor state.
    @discardableResult
    func ingest(timestamp: Double, x: Double, y: Double, z: Double) throws -> Int {
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let elapsed = timestamp - (firstTimestamp ?? timestamp)
        guard elapsed >= 0, elapsed.isFinite else { throw MeasurementError.invalidTimestamps }

        times.append(elapsed); xs.append(x); ys.append(y); zs.append(z)
        try writer?.append(timeSeconds: elapsed, x: x, y: y, z: z)

        let magnitude = (x * x + y * y + z * z).squareRoot()
        appendWindow(x: x, y: y, z: z, magnitude: magnitude)
        slowMeanMagnitude += 0.02 * (magnitude - slowMeanMagnitude)
        if times.count % 4 == 0 {  // decimate the live waveform to ~25 Hz
            waveform.append(magnitude - slowMeanMagnitude)
            if waveform.count > waveformCapacity { waveform.removeFirst(waveform.count - waveformCapacity) }
        }
        return times.count
    }

    func snapshot() -> MotionSnapshot {
        let count = times.count
        let elapsed = times.last ?? 0
        let rate = elapsed > 0 ? Double(count - 1) / elapsed : 0
        return MotionSnapshot(
            elapsedSeconds: elapsed,
            sampleCount: count,
            observedRateHz: rate,
            recentStd: Statistics.standardDeviation(windowMag),
            orientationChange: orientationChange(),
            waveform: waveform
        )
    }

    /// Finalises the CSV (if any) and returns the buffered signal.
    func finish() throws -> RawSignal {
        try writer?.finalize()
        writer = nil
        return RawSignal(times: times, x: xs, y: ys, z: zs)
    }

    func discard() {
        writer?.cancel()
        writer = nil
    }

    private func appendWindow(x: Double, y: Double, z: Double, magnitude: Double) {
        windowX.append(x); windowY.append(y); windowZ.append(z); windowMag.append(magnitude)
        if windowMag.count > windowCapacity {
            let overflow = windowMag.count - windowCapacity
            windowX.removeFirst(overflow); windowY.removeFirst(overflow)
            windowZ.removeFirst(overflow); windowMag.removeFirst(overflow)
        }
    }

    /// How much the mean acceleration direction moved between the two halves of the window.
    private func orientationChange() -> Double {
        let n = windowMag.count
        guard n >= 4 else { return 0 }
        let half = n / 2
        func meanVector(_ range: Range<Int>) -> (Double, Double, Double) {
            var sx = 0.0, sy = 0.0, sz = 0.0
            for i in range { sx += windowX[i]; sy += windowY[i]; sz += windowZ[i] }
            let c = Double(range.count)
            return (sx / c, sy / c, sz / c)
        }
        let a = meanVector(0..<half)
        let b = meanVector(half..<n)
        return ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
    }
}

/// Public sensor service. Manages Core Motion, exposes availability and throttled live state, and
/// guarantees a single active acquisition at a time.
@MainActor
@Observable
final class MotionRecorder {
    enum Mode: Equatable { case signalCheck, recording }

    private(set) var live = MotionSnapshot()
    private(set) var positioning = PositioningQuality.waiting
    private(set) var isActive = false
    private(set) var activeMode: Mode?

    var isAvailable: Bool { motionManager.isAccelerometerAvailable }

    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "it.enricodallastella.Pulse.motion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var session: RecordingSession?
    private let requestedFrequency = SignalProcessingParameters.requestedSamplingFrequencyHz

    /// Starts acquisition. `csvURL` is provided only for `.recording`. Throws if unavailable or busy.
    func start(mode: Mode, csvURL: URL?) throws {
        guard !isActive else { throw MeasurementError.processingFailed }
        guard motionManager.isAccelerometerAvailable else { throw MeasurementError.accelerometerUnavailable }

        let writer = try csvURL.map { try AccelerometerCSVWriter(url: $0) }
        let windowCapacity = Int(2.0 * requestedFrequency)
        let newSession = RecordingSession(writer: writer, windowCapacity: windowCapacity)
        session = newSession
        live = MotionSnapshot()
        positioning = .waiting
        isActive = true
        activeMode = mode

        motionManager.accelerometerUpdateInterval = 1.0 / requestedFrequency
        motionManager.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
            guard let data else { return }
            do {
                // Everything here touches only the captured session (confined to this serial
                // queue). The main actor is reached solely through the throttled snapshot hop.
                let count = try newSession.ingest(
                    timestamp: data.timestamp,
                    x: data.acceleration.x, y: data.acceleration.y, z: data.acceleration.z
                )
                if count % 8 == 0 {  // ~12 Hz UI refresh at 100 Hz acquisition
                    let snapshot = newSession.snapshot()
                    Task { @MainActor [weak self] in self?.apply(snapshot) }
                }
            } catch {
                // A single bad sample must not tear down the recording; it is simply skipped.
            }
        }
    }

    /// Stops a recording, finalising the CSV and returning the buffered signal.
    func finishRecording() async throws -> RawSignal {
        motionManager.stopAccelerometerUpdates()
        guard let session else { throw MeasurementError.processingFailed }
        isActive = false
        activeMode = nil
        return try await withCheckedThrowingContinuation { continuation in
            motionQueue.addOperation {
                do { continuation.resume(returning: try session.finish()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Stops without saving (signal check, or a cancelled recording).
    func cancel() {
        motionManager.stopAccelerometerUpdates()
        let session = self.session
        self.session = nil
        isActive = false
        activeMode = nil
        motionQueue.addOperation { session?.discard() }
    }

    // MARK: Private

    private func apply(_ snapshot: MotionSnapshot) {
        live = snapshot
        positioning = evaluatePositioning(snapshot)
    }

    private func evaluatePositioning(_ snapshot: MotionSnapshot) -> PositioningQuality {
        // Not enough data yet.
        if snapshot.elapsedSeconds < 1.0 { return .waiting }

        let motionScore = min(1, snapshot.recentStd / 0.05)           // 0.05 g spread ≈ clearly moving
        let orientationScore = min(1, snapshot.orientationChange / 0.15)
        let rateError = abs(snapshot.observedRateHz - requestedFrequency) / requestedFrequency
        let samplingScore = max(0, 1 - min(1, rateError / 0.3))

        let level: PositioningQuality.Level
        let messageKey: String
        if motionScore > 0.6 {
            level = .moving; messageKey = "signalCheck.moving"
        } else if orientationScore > 0.6 {
            level = .adjust; messageKey = "signalCheck.adjust"
        } else if samplingScore < 0.5 {
            level = .adjust; messageKey = "signalCheck.adjust"
        } else if motionScore > 0.3 {
            level = .moving; messageKey = "signalCheck.holdStill"
        } else {
            level = .stable; messageKey = "signalCheck.ready"
        }

        return PositioningQuality(
            level: level,
            motionScore: motionScore,
            orientationChangeScore: orientationScore,
            samplingQualityScore: samplingScore,
            messageKey: messageKey
        )
    }

    deinit {
        motionManager.stopAccelerometerUpdates()
    }
}
