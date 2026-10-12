import Foundation
import Observation

/// Drives the guided measurement flow through the explicit `MeasurementPhase` state machine.
/// Owns no DSP itself — it wires the sensor, the processor and the store together and keeps the
/// UI-facing state. Heavy work runs off the main actor.
@MainActor
@Observable
final class MeasurementViewModel {
    private(set) var phase: MeasurementPhase = .configuration
    var configuration = MeasurementConfiguration.default

    // Live sub-state (associated data kept off the phase enum on purpose).
    private(set) var countdownValue = 0
    private(set) var processingStage: ProcessingStage?
    private(set) var error: MeasurementError?
    private(set) var completedResult: MeasurementResult?
    private(set) var signalCheckSeconds = 0.0
    /// 0…1 fill while the phone is held still during the signal check. When it reaches 1 the
    /// measurement auto-starts, so the user never has to look at or tap the screen once positioned.
    private(set) var autoStartProgress = 0.0

    let recorder: MotionRecorder
    private let store: MeasurementStore
    private let settings: AppSettings

    private var sessionId: UUID?
    private var sessionFolder: URL?
    private var startedAt: Date?
    private var countdownTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    /// When the phone has been continuously stable this long during the signal check, recording
    /// starts automatically.
    private let requiredStableSeconds = 3.5
    private var stableSince: Date?

    init(recorder: MotionRecorder, store: MeasurementStore, settings: AppSettings) {
        self.recorder = recorder
        self.store = store
        self.settings = settings
    }

    var plannedDurationSeconds: Double { configuration.plannedDurationSeconds }
    var liveSnapshot: MotionSnapshot { recorder.live }
    var positioningQuality: PositioningQuality { recorder.positioning }

    var feedbackEnabled: Bool {
        get { settings.feedbackEnabled }
        set { settings.feedbackEnabled = newValue }
    }

    // MARK: Forward transitions

    func startNewMeasurement() {
        // Keep any already-saved session on disk; only reset in-flight state.
        cleanUp(discardFiles: false)
        configuration = MeasurementConfiguration(
            subjectIdentifier: settings.defaultSubjectIdentifier.isEmpty ? nil : settings.defaultSubjectIdentifier,
            breathingMode: .free,
            plannedDurationSeconds: 90,
            notes: nil
        )
        phase = .configuration
    }

    func advanceToPreparation() { phase = .preparation }

    func advanceToPositioning() { phase = .positioning }

    /// Steps back to the positioning screen, stopping any signal-check acquisition or countdown.
    func returnToPositioning() {
        countdownTask?.cancel()
        if recorder.isActive { recorder.cancel() }
        stableSince = nil
        autoStartProgress = 0
        phase = .positioning
    }

    /// Starts the short live signal check.
    func advanceToSignalCheck() {
        guard recorder.isAvailable else {
            fail(with: .accelerometerUnavailable)
            return
        }
        do {
            try recorder.start(mode: .signalCheck, csvURL: nil)
            phase = .signalCheck
            signalCheckSeconds = 0
            stableSince = nil
            autoStartProgress = 0
        } catch {
            fail(with: (error as? MeasurementError) ?? .processingFailed)
        }
    }

    /// Polled from the signal-check screen. Tracks how long the phone has been held still and, once
    /// it has been stable long enough, starts the measurement automatically — no tap required, since
    /// the user cannot see the screen with the phone resting on the chest.
    func evaluateAutoStart() {
        guard phase == .signalCheck else { return }
        // Give the sensor a moment to warm up before considering an auto-start.
        guard recorder.live.elapsedSeconds >= 1.0 else { autoStartProgress = 0; return }

        if recorder.positioning.isStable {
            let now = Date()
            if stableSince == nil { stableSince = now }
            let held = now.timeIntervalSince(stableSince ?? now)
            autoStartProgress = min(1, held / requiredStableSeconds)
            if held >= requiredStableSeconds {
                advanceToCountdown(placementCountdown: false)
            }
        } else {
            stableSince = nil
            autoStartProgress = 0
        }
    }

    /// Begins the short countdown before recording. `placementCountdown` is `true` when the user
    /// tapped "start now" and may still need a few seconds to place the phone; `false` for the
    /// automatic start, where the phone is already resting and stable.
    func advanceToCountdown(placementCountdown: Bool) {
        stableSince = nil
        autoStartProgress = 0
        recorder.cancel()  // stop the signal-check acquisition
        phase = .countdown
        countdownValue = placementCountdown ? 6 : 3
        FeedbackManager.play(.selection, enabled: settings.feedbackEnabled)  // first audible/haptic tick
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while countdownValue > 1 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdownValue -= 1
                FeedbackManager.play(.selection, enabled: settings.feedbackEnabled)  // per-second tick
            }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            self.beginRecording()
        }
    }

    // MARK: Recording

    private func beginRecording() {
        let id = UUID()
        let started = Date()
        do {
            let folder = try store.prepareSessionFolder(id: id)
            let csvURL = folder.appending(path: MeasurementStore.rawCSVFileName)
            try recorder.start(mode: .recording, csvURL: csvURL)
            sessionId = id
            sessionFolder = folder
            startedAt = started
            phase = .recording
            // Strong burst so the user feels the recording actually start without looking.
            FeedbackManager.play(.start, enabled: settings.feedbackEnabled)
            scheduleAutoStop()
        } catch {
            fail(with: (error as? MeasurementError) ?? .fileWriteFailed)
        }
    }

    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(plannedDurationSeconds))
            if Task.isCancelled { return }
            self.stopRecording(completed: true)
        }
    }

    /// Stops the recording and starts processing. `completed` is false when the user stops early.
    func stopRecording(completed: Bool) {
        guard phase == .recording else { return }
        autoStopTask?.cancel()
        // When the recording ends on its own, a strong buzz tells the user it is over and they can
        // relax, without needing to look at the screen.
        if completed {
            FeedbackManager.play(.success, enabled: settings.feedbackEnabled)
        }
        phase = .processing
        processingStage = .signalCheck
        let wasComplete = completed
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.runProcessing(isComplete: wasComplete)
        }
    }

    private func runProcessing(isComplete: Bool) async {
        guard let id = sessionId, let folder = sessionFolder, let started = startedAt else {
            fail(with: .processingFailed)
            return
        }
        let appVersion = DeviceInfo.appVersion
        let config = configuration

        do {
            let raw = try await recorder.finishRecording()
            let actualDuration = raw.times.last ?? 0
            let metadata = RecordingMetadata(
                id: id,
                startedAt: started,
                plannedDurationSeconds: config.plannedDurationSeconds,
                actualDurationSeconds: actualDuration,
                requestedSamplingFrequencyHz: SignalProcessingParameters.requestedSamplingFrequencyHz,
                sampleCount: raw.times.count,
                isComplete: isComplete,
                configuration: config,
                deviceModel: DeviceInfo.deviceModel,
                systemVersion: DeviceInfo.systemVersion,
                appVersion: appVersion
            )
            try store.saveMetadata(metadata, in: folder)

            // DSP runs away from the main actor. Progress crosses the concurrency boundary through
            // an AsyncStream, so the detached task never captures this @MainActor view model.
            let rawName = MeasurementStore.rawCSVFileName
            let metaName = MeasurementStore.metadataFileName
            let (progressStream, progressContinuation) = AsyncStream<ProcessingStage>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )

            let progressConsumer = Task { @MainActor [weak self] in
                for await stage in progressStream {
                    guard !Task.isCancelled else { return }
                    self?.processingStage = stage
                }
            }

            defer {
                progressContinuation.finish()
                progressConsumer.cancel()
            }

            let result = try await Task.detached(priority: .userInitiated) {
                try CardiorespiratoryProcessor.process(
                    signal: raw,
                    configuration: config,
                    id: id,
                    startedAt: started,
                    rawCSVFileName: rawName,
                    metadataFileName: metaName,
                    appVersion: appVersion,
                    progress: { stage in progressContinuation.yield(stage) }
                )
            }.value

            if Task.isCancelled { return }
            try store.saveResult(result, metadata: metadata, in: folder)
            completedResult = result
            phase = .completed
            FeedbackManager.play(.success, enabled: settings.feedbackEnabled)
        } catch {
            fail(with: (error as? MeasurementError) ?? .processingFailed)
        }
    }

    // MARK: Termination

    /// User leaves the flow entirely.
    func cancelFlow() {
        cleanUp(discardFiles: phase != .completed && phase != .failed)
        phase = .configuration
    }

    func acknowledgeErrorAndRetry() {
        error = nil
        phase = .configuration
    }

    /// Called when the app is no longer active. Recording/countdown/signal-check cannot continue
    /// reliably in the background, so we finish gracefully.
    func handleResignActive() {
        switch phase {
        case .recording:
            stopRecording(completed: false)
        case .signalCheck, .countdown:
            countdownTask?.cancel()
            recorder.cancel()
            stableSince = nil
            autoStartProgress = 0
            phase = .positioning
        default:
            break
        }
    }

    func updateSignalCheckClock() {
        signalCheckSeconds = recorder.live.elapsedSeconds
    }

    private func fail(with error: MeasurementError) {
        autoStopTask?.cancel()
        countdownTask?.cancel()
        processingTask?.cancel()
        if recorder.isActive { recorder.cancel() }
        self.error = error
        phase = .failed
        FeedbackManager.play(.error, enabled: settings.feedbackEnabled)
    }

    private func cleanUp(discardFiles: Bool) {
        countdownTask?.cancel(); countdownTask = nil
        autoStopTask?.cancel(); autoStopTask = nil
        processingTask?.cancel(); processingTask = nil
        if recorder.isActive { recorder.cancel() }
        if discardFiles, let folder = sessionFolder {
            try? FileManager.default.removeItem(at: folder)
        }
        sessionId = nil
        sessionFolder = nil
        startedAt = nil
        processingStage = nil
        completedResult = nil
        error = nil
        signalCheckSeconds = 0
        stableSince = nil
        autoStartProgress = 0
    }
}
