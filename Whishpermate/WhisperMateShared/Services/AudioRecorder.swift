import AVFoundation
import Accelerate
import Foundation
public import Combine

#if os(iOS)
    import UIKit
#endif

public enum ManagedAudioRecordingError: LocalizedError, Equatable, Sendable {
    case alreadyActive
    case staleAttempt
    case audioSessionUnavailable
    case recorderUnavailable
    case writeFailed
    case noAudioWritten
    case interrupted
    case audioServicesReset
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyActive:
            return "Another recording is already active."
        case .staleAttempt:
            return "This recording attempt is no longer active."
        case .audioSessionUnavailable, .recorderUnavailable:
            return "Recording could not start. Please try again."
        case .writeFailed, .noAudioWritten:
            return "The recording was not complete, so it was not sent."
        case .interrupted:
            return "Recording was interrupted, so it was not sent."
        case .audioServicesReset:
            return "Audio became unavailable, so the recording was not sent."
        case .cancelled:
            return "Recording cancelled."
        }
    }
}

public struct ManagedAudioRecordingFailure: Equatable, Sendable {
    public let attemptID: UUID
    public let error: ManagedAudioRecordingError
}

public final class AudioRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private static let frequencyBandCount = 10
    private static let recordingQueueKey = DispatchSpecificKey<Void>()
    #if os(iOS)
        private static let audioSessionOwnership = IOSExclusiveResourceOwnership<AudioRecorder>()
    #endif

    @Published public var isRecording = false
    @Published public var audioLevel: Float = 0.0 // Audio level for visualization (0.0 to 1.0)
    @Published public var frequencyBands: [Float] = Array(repeating: 0.0, count: frequencyBandCount)
    @Published public private(set) var managedAttemptFailure: ManagedAudioRecordingFailure?
    public var realtimeAudioChunkHandler: (@Sendable (Data) -> Void)? {
        get { realtimeAudioDelivery.handler }
        set { realtimeAudioDelivery.handler = newValue }
    }

    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var realtimeCaptureEngine: AVAudioEngine?
    private let realtimeAudioDelivery = RealtimeAudioDeliveryQueue()
    private let realtimePCMConverter = RealtimePCMConverter()
    private var standbyEngine: AVAudioEngine?
    private var recordingURL: URL?
    private var isMonitoringOnly = false
    private var levelTimer: DispatchSourceTimer?
    private lazy var frequencyAnalyzer = SharedFrequencyAnalyzer()
    private let recordingQueue = DispatchQueue(label: "com.whispermate.audio-recorder", qos: .userInitiated)
    private var activeAttemptID: UUID?
    private var managedStartContinuation: CheckedContinuation<URL, Error>?
    private var managedDidWriteAudio = false
    private var managedWriteFailed = false
    private var recorderReadinessProbe: DispatchSourceTimer?
    private var managedCaptureGeneration: UInt64 = 0
    private var activeManagedCaptureGeneration: UInt64?
    #if os(iOS)
        private var isAudioSessionConfigured = false
        private var isStandbySessionConfigured = false
        private var managedAudioSessionObserverTokens: [NSObjectProtocol] = []
    #endif

    // App Group identifier for sharing data between app and keyboard extension
    public static let appGroupIdentifier = "group.com.whispermate.shared"

    /// Returns true if the audio session is in standby mode (ready to record but not recording).
    /// This keeps iOS from suspending the app, enabling Quick Dictation for ~10 minutes.
    #if os(iOS)
    public var isStandbyActive: Bool {
        standbyEngine?.isRunning == true && !isRecording
    }
    #else
    public var isStandbyActive: Bool { false }
    #endif

    override public init() {
        super.init()
        recordingQueue.setSpecific(key: Self.recordingQueueKey, value: ())
    }

    #if os(iOS)
        @discardableResult
        private func configureAudioSession() -> Bool {
            do {
                try Self.audioSessionOwnership.claim(self) {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP])
                    try session.setActive(true)
                }
                isAudioSessionConfigured = true
                DebugLog.info("Audio session configured for iOS category=playAndRecord mode=measurement", context: "AudioRecorder")
                return true
            } catch {
                DebugLog.info("Failed to configure audio session: \(error)", context: "AudioRecorder")
                return false
            }
        }

        private func deactivateSession() {
            guard isAudioSessionConfigured else { return }

            do {
                _ = try Self.audioSessionOwnership.relinquish(self) {
                    try AVAudioSession.sharedInstance().setActive(false)
                }
                isAudioSessionConfigured = false
            } catch {
                DebugLog.info("Failed to deactivate audio session: \(error)", context: "AudioRecorder LOG")
            }
        }

        // MARK: - Audio Standby Mode

        /// Starts audio session standby to keep iOS from suspending the app.
        /// This enables Quick Dictation for ~10 minutes without opening the app.
        /// The audio engine runs with a tap but doesn't capture to disk.
        public func startStandby() throws {
            guard !isRecording else { return }
            guard standbyEngine?.isRunning != true else { return }

            DebugLog.info("Starting audio standby mode", context: "AudioRecorder")

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0, format.channelCount > 0 else {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                throw ManagedAudioRecordingError.audioSessionUnavailable
            }

            // Install a tap that discards all samples. This keeps the audio session active.
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable _, _ in
                // Discard samples - we're just keeping the session alive
            }

            engine.prepare()
            try engine.start()

            standbyEngine = engine
            isStandbySessionConfigured = true
            DebugLog.info("Audio standby mode active - app will stay alive in background", context: "AudioRecorder")
        }

        /// Stops audio standby mode and optionally deactivates the audio session.
        public func stopStandby(deactivateAudioSession: Bool = true) {
            guard !isRecording else { return }
            guard let engine = standbyEngine else { return }

            DebugLog.info("Stopping audio standby mode", context: "AudioRecorder")

            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            standbyEngine = nil
            isStandbySessionConfigured = false

            if deactivateAudioSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }

        private func installManagedAudioSessionObserversOnQueue(
            attemptID: UUID,
            generation: UInt64,
            recorder: AVAudioRecorder
        ) {
            removeManagedAudioSessionObserversOnQueue()

            let recorderID = ObjectIdentifier(recorder)
            let notificationCenter = NotificationCenter.default
            let interruptionObserver = notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began
                else { return }

                self?.recordingQueue.async { [weak self] in
                    self?.terminallyFailManagedCaptureOnQueue(
                        attemptID: attemptID,
                        generation: generation,
                        recorderID: recorderID,
                        error: .interrupted,
                        reason: "Audio session interruption began"
                    )
                }
            }
            let mediaServicesResetObserver = notificationCenter.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.recordingQueue.async { [weak self] in
                    self?.terminallyFailManagedCaptureOnQueue(
                        attemptID: attemptID,
                        generation: generation,
                        recorderID: recorderID,
                        error: .audioServicesReset,
                        reason: "Audio services were reset"
                    )
                }
            }
            managedAudioSessionObserverTokens = [
                interruptionObserver,
                mediaServicesResetObserver,
            ]
        }

        private func removeManagedAudioSessionObserversOnQueue() {
            let notificationCenter = NotificationCenter.default
            for token in managedAudioSessionObserverTokens {
                notificationCenter.removeObserver(token)
            }
            managedAudioSessionObserverTokens.removeAll()
        }
    #endif

    #if os(iOS)
        @available(
            iOS,
            unavailable,
            message: "iOS recording requires a durable MobileAudioProcessingStore destination."
        )
        public func startRecording() {}
    #else
        public func startRecording() {
            recordingQueue.async { [weak self] in
                self?.startRecordingOnQueue(destinationURL: nil, attemptID: nil)
            }
        }
    #endif

    /// Starts a managed capture into a caller-owned durable URL. The call returns only after the
    /// recorder has successfully written audio for this exact attempt.
    public func startRecording(at destinationURL: URL, attemptID: UUID) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                recordingQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: ManagedAudioRecordingError.recorderUnavailable)
                        return
                    }
                    guard self.activeAttemptID == nil else {
                        continuation.resume(throwing: ManagedAudioRecordingError.alreadyActive)
                        return
                    }

                    self.activeAttemptID = attemptID
                    self.managedCaptureGeneration &+= 1
                    self.activeManagedCaptureGeneration = self.managedCaptureGeneration
                    self.managedStartContinuation = continuation
                    self.managedDidWriteAudio = false
                    self.managedWriteFailed = false
                    DispatchQueue.main.async {
                        self.managedAttemptFailure = nil
                    }
                    self.startRecordingOnQueue(destinationURL: destinationURL, attemptID: attemptID)
                }
            }
        } onCancel: {
            self.recordingQueue.async { [weak self] in
                // A timed-out generation may complete after a replacement recorder has activated
                // the process-wide audio session. It may close only its private recorder here.
                self?.cancelManagedAttemptOnQueue(
                    attemptID: attemptID,
                    deactivateAudioSession: false
                )
            }
        }
    }

    /// Abandons only the matching attempt. A late callback from that attempt cannot affect a
    /// subsequent recording owned by a different attempt ID.
    public func abandonRecording(attemptID: UUID, deactivateAudioSession: Bool = true) async {
        await withCheckedContinuation { continuation in
            recordingQueue.async { [weak self] in
                if self?.activeAttemptID == attemptID {
                    self?.cancelManagedAttemptOnQueue(
                        attemptID: attemptID,
                        deactivateAudioSession: deactivateAudioSession
                    )
                }
                continuation.resume()
            }
        }
    }

    private func startRecordingOnQueue(destinationURL: URL?, attemptID: UUID?) {
        DebugLog.info("startRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")

        // Guard against multiple recording sessions
        if audioRecorder != nil || audioEngine != nil || realtimeCaptureEngine != nil {
            #if os(iOS)
                if isMonitoringOnly {
                    stopMonitoringOnQueue(deactivateAudioSession: false)
                } else if attemptID != nil {
                    abortManagedStartOnQueue(.alreadyActive)
                    return
                } else {
                    DebugLog.info("Already recording - stopping previous session first", context: "AudioRecorder LOG")
                    _ = stopRecordingOnQueue(deactivateAudioSession: false)
                }
            #else
            if attemptID != nil {
                abortManagedStartOnQueue(.alreadyActive)
                return
            }
            DebugLog.info("Already recording - stopping previous session first", context: "AudioRecorder LOG")
            _ = stopRecordingOnQueue(deactivateAudioSession: false)
            #endif
        }
        isMonitoringOnly = false

        let fileManager = FileManager.default

        #if os(iOS)
            guard configureAudioSession() else {
                abortManagedStartOnQueue(.audioSessionUnavailable)
                return
            }
        #endif

        DispatchQueue.main.async {
            self.audioLevel = 0.0
            self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        }

        if let destinationURL {
            recordingURL = destinationURL
        } else {
            #if os(iOS)
                // All iOS callers must allocate a stable source in the durable attempt journal
                // before native capture starts.
                abortManagedStartOnQueue(.recorderUnavailable)
                return
            #else
                let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
                recordingURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
            #endif
        }

        // AVAudioRecorder owns the encoder and closes a valid M4A container synchronously on
        // stop. The previous engine-tap path asked AVAudioFile to encode AAC directly, which can
        // fail before the first write and leave an unreadable container.
        startMeteredRecorderRecording(attemptID: attemptID)
    }

    #if os(iOS)
        public func startMonitoring() {
            recordingQueue.async { [weak self] in
                self?.startMonitoringOnQueue()
            }
        }

        public func stopMonitoring(deactivateAudioSession: Bool = true) {
            recordingQueue.async { [weak self] in
                self?.stopMonitoringOnQueue(deactivateAudioSession: deactivateAudioSession)
            }
        }

        private func startMonitoringOnQueue() {
            guard audioRecorder == nil, audioEngine == nil, realtimeCaptureEngine == nil else {
                return
            }

            guard configureAudioSession() else {
                publishStopped()
                return
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            _ = frequencyAnalyzer

            inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                guard let self else { return }

                let bands = self.frequencyAnalyzer.analyze(buffer: buffer)
                let level = self.calculateAudioLevel(from: buffer)

                DispatchQueue.main.async {
                    self.frequencyBands = bands
                    self.audioLevel = level
                }
            }

            do {
                audioEngine = engine
                isMonitoringOnly = true
                try engine.start()

                DispatchQueue.main.async {
                    self.isRecording = false
                }

                DebugLog.info("startMonitoring success - engine listening", context: "AudioRecorder LOG")
            } catch {
                inputNode.removeTap(onBus: 0)
                audioEngine = nil
                isMonitoringOnly = false
                publishStopped()
                DebugLog.info("Failed to start monitoring: \(error)", context: "AudioRecorder LOG")
            }
        }

        private func stopMonitoringOnQueue(deactivateAudioSession: Bool = true) {
            guard isMonitoringOnly else { return }

            if let engine = audioEngine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            audioEngine = nil
            isMonitoringOnly = false

            if deactivateAudioSession {
                deactivateSession()
            }

            publishStopped()
            DebugLog.info("stopMonitoring completed", context: "AudioRecorder LOG")
        }

        private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
            guard let channelData = buffer.floatChannelData?[0] else { return 0.0 }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return 0.0 }

            let samples = stride(from: 0, to: frameLength, by: buffer.stride).map { channelData[$0] }
            let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(max(samples.count, 1)))
            let avgPower = 20 * log10(max(rms, 0.000_001))
            return normalizeAudioLevel(avgPower)
        }
    #endif

    private func publishStopped() {
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
            self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        }
    }

    private func startMeteredRecorderRecording(attemptID: UUID?) {
        guard let recordingURL else {
            abortManagedStartOnQueue(.recorderUnavailable)
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            audioRecorder = recorder

            #if os(iOS)
                if let attemptID,
                   let generation = activeManagedCaptureGeneration
                {
                    installManagedAudioSessionObserversOnQueue(
                        attemptID: attemptID,
                        generation: generation,
                        recorder: recorder
                    )
                }
            #endif

            guard recorder.record() else {
                DebugLog.info("AVAudioRecorder refused to start recording", context: "AudioRecorder LOG")
                abortManagedStartOnQueue(.recorderUnavailable)
                return
            }

            startMeteringTimer()

            if let attemptID {
                startRecorderReadinessProbe(attemptID: attemptID, url: recordingURL)
            } else {
                DispatchQueue.main.async {
                    self.isRecording = true
                }
            }

            DebugLog.info("startRecording success - isRecording after: \(isRecording)", context: "AudioRecorder LOG")
        } catch {
            DebugLog.info("Failed to start recording: \(error)", context: "AudioRecorder LOG")
            abortManagedStartOnQueue(.recorderUnavailable)
        }
    }

    private func startMeteringTimer() {
        levelTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self = self, let recorder = self.audioRecorder else { return }
            recorder.updateMeters()
            let normalizedLevel = self.normalizeAudioLevel(recorder.averagePower(forChannel: 0))

            DispatchQueue.main.async {
                self.audioLevel = normalizedLevel
                self.frequencyBands = Self.fallbackBands(for: normalizedLevel)
            }
        }
        levelTimer = timer
        timer.resume()
    }

    private func startRecorderReadinessProbe(attemptID: UUID, url: URL) {
        recorderReadinessProbe?.cancel()
        let probe = DispatchSource.makeTimerSource(queue: recordingQueue)
        probe.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        probe.setEventHandler { [weak self] in
            guard let self, self.activeAttemptID == attemptID else {
                self?.recorderReadinessProbe?.cancel()
                self?.recorderReadinessProbe = nil
                return
            }
            guard let recorder = self.audioRecorder,
                  recorder.isRecording,
                  recorder.currentTime > 0,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let bytes = attributes[.size] as? NSNumber,
                  bytes.int64Value > 0
            else { return }

            self.managedAudioWasWrittenOnQueue(attemptID: attemptID)
        }
        recorderReadinessProbe = probe
        probe.resume()
    }

    private func managedAudioWasWrittenOnQueue(attemptID: UUID) {
        guard activeAttemptID == attemptID, !managedWriteFailed else { return }
        managedDidWriteAudio = true
        recorderReadinessProbe?.cancel()
        recorderReadinessProbe = nil

        guard let continuation = managedStartContinuation,
              let recordingURL
        else { return }
        managedStartContinuation = nil
        DispatchQueue.main.async {
            self.isRecording = true
        }
        continuation.resume(returning: recordingURL)
        startRealtimeCaptureTapOnQueueIfNeeded()
    }

    /// Best-effort PCM tap for cloud realtime. Started only after the durable
    /// AVAudioRecorder has written audio, so a tap failure cannot lock out
    /// recording. If the tap cannot start, batch fallback still has the file.
    private func startRealtimeCaptureTapOnQueueIfNeeded() {
        guard realtimeAudioDelivery.handler != nil else { return }
        guard realtimeCaptureEngine == nil else { return }
        guard audioRecorder != nil else { return }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            DebugLog.info("Realtime PCM tap unavailable: invalid input format", context: "AudioRecorder")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.deliverRealtimeChunk(from: buffer)
        }

        do {
            try engine.start()
            realtimeCaptureEngine = engine
            DebugLog.info("Realtime PCM tap started", context: "AudioRecorder")
        } catch {
            inputNode.removeTap(onBus: 0)
            DebugLog.info("Realtime PCM tap unavailable: \(error)", context: "AudioRecorder")
        }
    }

    private func deliverRealtimeChunk(from buffer: AVAudioPCMBuffer) {
        let lease = realtimeAudioDelivery.beginDelivery()
        defer { lease?.discard() }
        guard let lease else { return }
        if let chunk = realtimePCMConverter.chunk(from: buffer), !chunk.isEmpty {
            lease.deliver(chunk)
        } else {
            lease.failCoverage()
        }
    }

    private func stopRealtimeCaptureTapOnQueue() {
        guard let engine = realtimeCaptureEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        realtimeCaptureEngine = nil
    }

    public func detachRealtimeAudioChunkHandlerAndDrain(
        _ completion: @escaping @Sendable (Bool) -> Void
    ) {
        realtimeAudioDelivery.detachAndDrain(completion)
    }

    private func terminallyFailManagedCaptureOnQueue(
        attemptID: UUID,
        generation: UInt64,
        recorderID: ObjectIdentifier,
        error: ManagedAudioRecordingError = .writeFailed,
        reason: String
    ) {
        guard activeAttemptID == attemptID,
              activeManagedCaptureGeneration == generation,
              let recorder = audioRecorder,
              ObjectIdentifier(recorder) == recorderID
        else { return }

        DebugLog.info(reason, context: "AudioRecorder LOG")
        managedWriteFailed = true
        failManagedStartOnQueue(error)
        let failure = ManagedAudioRecordingFailure(attemptID: attemptID, error: error)

        // Closing the recorder here is essential: a container containing only the valid prefix
        // from before an interruption must never remain eligible for finalization/submission.
        _ = stopRecordingOnQueue(deactivateAudioSession: true)
        DispatchQueue.main.async {
            self.managedAttemptFailure = failure
        }
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        recordingQueue.async { [weak self, weak recorder] in
            guard let self, let recorder, self.audioRecorder === recorder,
                  let attemptID = self.activeAttemptID
            else { return }
            DebugLog.info(
                "Recorder reported an encoding error: \(error?.localizedDescription ?? "unknown error")",
                context: "AudioRecorder LOG"
            )
            guard let generation = self.activeManagedCaptureGeneration else { return }
            self.terminallyFailManagedCaptureOnQueue(
                attemptID: attemptID,
                generation: generation,
                recorderID: ObjectIdentifier(recorder),
                reason: "Recorder reported an encoding error"
            )
        }
    }

    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        recordingQueue.async { [weak self, weak recorder] in
            guard let self, let recorder, self.audioRecorder === recorder,
                  let attemptID = self.activeAttemptID
            else { return }
            DebugLog.info(
                flag ? "Recorder stopped before finalization." : "Recorder stopped unsuccessfully.",
                context: "AudioRecorder LOG"
            )
            guard let generation = self.activeManagedCaptureGeneration else { return }
            self.terminallyFailManagedCaptureOnQueue(
                attemptID: attemptID,
                generation: generation,
                recorderID: ObjectIdentifier(recorder),
                reason: flag
                    ? "Recorder stopped before requested finalization"
                    : "Recorder stopped unsuccessfully"
            )
        }
    }

    private func failManagedStartOnQueue(_ error: ManagedAudioRecordingError) {
        guard let continuation = managedStartContinuation else { return }
        managedStartContinuation = nil
        continuation.resume(throwing: error)
    }

    private func abortManagedStartOnQueue(_ error: ManagedAudioRecordingError) {
        failManagedStartOnQueue(error)
        _ = stopRecordingOnQueue(deactivateAudioSession: true)
    }

    private func cancelManagedAttemptOnQueue(
        attemptID: UUID,
        deactivateAudioSession: Bool = true
    ) {
        guard activeAttemptID == attemptID else { return }
        failManagedStartOnQueue(.cancelled)
        _ = stopRecordingOnQueue(deactivateAudioSession: deactivateAudioSession)
    }

    private func normalizeAudioLevel(_ power: Float) -> Float {
        // Convert dB (-160 to 0) to normalized 0.0-1.0 scale
        // Using -60dB as minimum threshold for increased sensitivity
        let minDb: Float = -60.0
        let maxDb: Float = 0.0

        let clampedPower = max(minDb, min(maxDb, power))
        let normalized = (clampedPower - minDb) / (maxDb - minDb)

        // Apply additional boost for better visualization
        let boosted = min(normalized * 1.5, 1.0)

        return max(0.0, min(1.0, boosted))
    }

    private static func fallbackBands(for level: Float) -> [Float] {
        (0 ..< frequencyBandCount).map { index in
            let center = Float(frequencyBandCount - 1) / 2
            let distanceFromCenter = abs(Float(index) - center) / center
            let waveformFactor = 1 - (distanceFromCenter * distanceFromCenter)
            return max(0, min(1, level * waveformFactor))
        }
    }

    public func pauseRecording() {
        #if os(iOS)
            recordingQueue.async { [weak self] in
                guard let self else { return }
                if self.audioRecorder?.isRecording == true {
                    self.audioRecorder?.pause()
                    self.levelTimer?.cancel()
                    self.levelTimer = nil
                    self.realtimeCaptureEngine?.pause()
                } else if self.audioEngine?.isRunning == true {
                    self.audioEngine?.pause()
                } else {
                    return
                }
                DebugLog.info("Recording paused", context: "AudioRecorder LOG")
            }
        #else
            guard isRecording else { return }
            audioRecorder?.pause()
            levelTimer?.cancel()
            levelTimer = nil

            DebugLog.info("Recording paused", context: "AudioRecorder LOG")
        #endif
    }

    public func resumeRecording() {
        #if os(iOS)
            recordingQueue.async { [weak self] in
                guard let self else { return }
                if let recorder = self.audioRecorder, !recorder.isRecording {
                    guard recorder.record() else {
                        if let attemptID = self.activeAttemptID,
                           let generation = self.activeManagedCaptureGeneration
                        {
                            self.terminallyFailManagedCaptureOnQueue(
                                attemptID: attemptID,
                                generation: generation,
                                recorderID: ObjectIdentifier(recorder),
                                reason: "Recorder could not resume"
                            )
                        } else {
                            self.publishStopped()
                        }
                        return
                    }
                    self.startMeteringTimer()
                    if let realtimeEngine = self.realtimeCaptureEngine, !realtimeEngine.isRunning {
                        do {
                            try realtimeEngine.start()
                        } catch {
                            DebugLog.info(
                                "Failed to resume realtime PCM tap: \(error)",
                                context: "AudioRecorder LOG"
                            )
                        }
                    }
                } else if let audioEngine = self.audioEngine, !audioEngine.isRunning {
                    do {
                        try audioEngine.start()
                    } catch {
                        DebugLog.info("Failed to resume audio monitoring: \(error)", context: "AudioRecorder LOG")
                        return
                    }
                } else {
                    return
                }

                DebugLog.info("Recording resumed", context: "AudioRecorder LOG")
            }
        #else
            guard isRecording else { return }
            audioRecorder?.record()
            startMeteringTimer()

            DebugLog.info("Recording resumed", context: "AudioRecorder LOG")
        #endif
    }

    public func stopRecording(deactivateAudioSession: Bool = true) -> URL? {
        if DispatchQueue.getSpecific(key: Self.recordingQueueKey) != nil {
            return stopRecordingOnQueue(deactivateAudioSession: deactivateAudioSession)
        }

        return recordingQueue.sync {
            stopRecordingOnQueue(deactivateAudioSession: deactivateAudioSession)
        }
    }

    public func stopRecordingAsync(deactivateAudioSession: Bool = true) async -> URL? {
        await withCheckedContinuation { continuation in
            recordingQueue.async { [weak self] in
                let url = self?.stopRecordingOnQueue(deactivateAudioSession: deactivateAudioSession)
                continuation.resume(returning: url)
            }
        }
    }

    /// Finalizes only the matching managed capture. The URL is returned only when at least one
    /// audio write succeeded and no later write failed.
    public func stopRecording(
        attemptID: UUID,
        deactivateAudioSession: Bool = true
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            recordingQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ManagedAudioRecordingError.recorderUnavailable)
                    return
                }
                guard self.activeAttemptID == attemptID else {
                    continuation.resume(throwing: ManagedAudioRecordingError.staleAttempt)
                    return
                }

                let didWrite = self.managedDidWriteAudio
                let writeFailed = self.managedWriteFailed
                guard let url = self.stopRecordingOnQueue(deactivateAudioSession: deactivateAudioSession) else {
                    continuation.resume(throwing: ManagedAudioRecordingError.recorderUnavailable)
                    return
                }
                if writeFailed {
                    continuation.resume(throwing: ManagedAudioRecordingError.writeFailed)
                } else if !didWrite {
                    continuation.resume(throwing: ManagedAudioRecordingError.noAudioWritten)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }

    private func stopRecordingOnQueue(deactivateAudioSession: Bool = true) -> URL? {
        DebugLog.info("stopRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        let completedRecordingURL = recordingURL
        recordingURL = nil
        let wasMonitoringOnly = isMonitoringOnly
        isMonitoringOnly = false

        // Stop timer
        levelTimer?.cancel()
        levelTimer = nil
        recorderReadinessProbe?.cancel()
        recorderReadinessProbe = nil

        #if os(iOS)
            removeManagedAudioSessionObserversOnQueue()
        #endif

        audioRecorder?.delegate = nil
        audioRecorder?.stop()
        audioRecorder = nil

        stopRealtimeCaptureTapOnQueue()
        realtimeAudioDelivery.detachAndDrain { _ in }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        activeAttemptID = nil
        activeManagedCaptureGeneration = nil
        failManagedStartOnQueue(.cancelled)
        managedDidWriteAudio = false
        managedWriteFailed = false

        #if os(iOS)
            if deactivateAudioSession {
                deactivateSession()
            }
        #endif

        publishStopped()

        DebugLog.info("stopRecording completed, recordingURL: \(String(describing: completedRecordingURL))", context: "AudioRecorder LOG")
        return wasMonitoringOnly ? nil : completedRecordingURL
    }

    deinit {
        DebugLog.info("🗑️ Deinit - cleaning up", context: "AudioRecorder LOG")

        // Stop and clean up recording
        if audioRecorder?.isRecording == true {
            audioRecorder?.stop()
        }
        levelTimer?.cancel()
        levelTimer = nil
        recorderReadinessProbe?.cancel()
        recorderReadinessProbe = nil
        #if os(iOS)
            removeManagedAudioSessionObserversOnQueue()
        #endif
        audioRecorder = nil
        if let engine = realtimeCaptureEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        realtimeCaptureEngine = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        #if os(iOS)
            deactivateSession()
        #endif

        DebugLog.info("✅ Cleanup complete", context: "AudioRecorder LOG")
    }
}

private final class SharedFrequencyAnalyzer {
    private let fftSize = 2048
    private let bandCount = 10
    private var fftSetup: vDSP_DFT_Setup?
    private var window: [Float]
    private var previousBands: [Float]

    init() {
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)
        window = [Float](repeating: 0, count: fftSize)
        previousBands = Array(repeating: 0.0, count: bandCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    func analyze(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0],
              let fftSetup
        else {
            return Array(repeating: 0.0, count: bandCount)
        }

        let sampleCount = min(Int(buffer.frameLength), fftSize)
        let sampleRate = Float(buffer.format.sampleRate)

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(sampleCount))

        var realParts = [Float](repeating: 0, count: fftSize)
        var imagParts = [Float](repeating: 0, count: fftSize)

        windowed.withUnsafeBytes { bufferPtr in
            let complexPtr = bufferPtr.bindMemory(to: DSPComplex.self)
            realParts.withUnsafeMutableBufferPointer { realPtr in
                imagParts.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                }
            }
        }

        vDSP_DFT_Execute(fftSetup, realParts, imagParts, &realParts, &imagParts)

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realParts.withUnsafeMutableBufferPointer { realPtr in
            imagParts.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        var bands = groupIntoBands(magnitudes: magnitudes, sampleRate: sampleRate)
        let noiseGate: Float = 0.5
        let fixedGain: Float = 12.0
        bands = bands.map { min(max($0 - noiseGate, 0.0) * fixedGain, 1.0) }

        for index in 0 ..< bandCount {
            if bands[index] > previousBands[index] {
                bands[index] = previousBands[index] * 0.1 + bands[index] * 0.9
            } else {
                bands[index] = previousBands[index] * 0.6 + bands[index] * 0.4
            }
        }

        previousBands = bands
        return bands
    }

    private func groupIntoBands(magnitudes: [Float], sampleRate: Float) -> [Float] {
        var bands = [Float](repeating: 0, count: bandCount)
        let magnitudeCount = magnitudes.count
        let voiceStartHz: Float = 50.0
        let voiceEndHz: Float = 2400.0
        let nyquistFreq = sampleRate / 2.0
        let voiceRangeStart = Int((voiceStartHz / nyquistFreq) * Float(magnitudeCount))
        let voiceRangeEnd = Int((voiceEndHz / nyquistFreq) * Float(magnitudeCount))
        let voiceRangeWidth = max(voiceRangeEnd - voiceRangeStart, 1)

        for index in 0 ..< bandCount {
            let startIndex = voiceRangeStart + Int(Float(index) / Float(bandCount) * Float(voiceRangeWidth))
            let endIndex = voiceRangeStart + Int(Float(index + 1) / Float(bandCount) * Float(voiceRangeWidth))

            if startIndex < voiceRangeEnd, endIndex <= voiceRangeEnd, startIndex < endIndex {
                let bandMagnitudes = magnitudes[startIndex ..< endIndex]
                bands[index] = bandMagnitudes.reduce(0, +) / Float(bandMagnitudes.count)
            }
        }

        return bands
    }

    deinit {
        if let fftSetup {
            vDSP_DFT_DestroySetup(fftSetup)
        }
    }
}
