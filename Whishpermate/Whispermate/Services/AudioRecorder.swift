import AVFoundation
import Foundation
import WhisperMateShared
internal import Combine

class AudioRecorder: NSObject, ObservableObject {
    // Shared instance to prevent multiple instances when view is recreated
    static let shared = AudioRecorder()
    private static let frequencyBandCount = 10

    private enum Constants {
        static let recordingWatchdogInterval: TimeInterval = 1.0
        static let recordingBufferStallThreshold: TimeInterval = 2.5
        static let captureRecoveryDelays: [TimeInterval] = [0.15, 0.5]
        static let recordingPreparationTimeout: TimeInterval = 5.0
        static let recordingFinalizationTimeout: TimeInterval = 5.0

        /// Every speech model downsamples to 16 kHz before it looks at the audio,
        /// so capturing above that only inflates the upload. Encoding at the rate
        /// the model wants makes the payload ~9x smaller with no accuracy cost.
        static let transcriptionSampleRate: Double = 16_000

        /// AAC at 24 kbps is transparent for 16 kHz mono speech.
        static let transcriptionBitRate: Int = 24_000
    }

    enum StopDisposition: Equatable {
        case submitIfValid
        case discard
    }

    enum NativeCloseState: Equatable {
        case pending
        case confirmed(MacAudioProcessingStore.NativeWriterCloseAttestation)
        case unknown
    }

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0 // Audio level for visualization (0.0 to 1.0)
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: frequencyBandCount) // Frequency spectrum data
    var realtimeAudioChunkHandler: (@Sendable (Data) -> Void)? {
        get { realtimeAudioDelivery.handler }
        set { realtimeAudioDelivery.handler = newValue }
    }
    var captureFailureHandler: ((String) -> Void)?

    private let volumeManager = AudioVolumeManager()
    private let frequencyAnalyzer = FrequencyAnalyzer()
    private var recordingWatchdogTimer: Timer?
    private var lastAudioBufferAt: Date?
    private var pendingPreparation: MacCapturePreparation?
    private var activeCapture: MacCaptureSession?
    private var pendingFinalization: MacCaptureFinalization?
    private var nativeCloseProofs: [UUID: MacNativeRecorderCloseProof] = [:]
    private var confirmedNativeCloseAttestations:
        [UUID: MacAudioProcessingStore.NativeWriterCloseAttestation] = [:]
    private var nativeRecordingURLs: [UUID: URL] = [:]
    private var terminationCloseRequested = false
    private let realtimeAudioDelivery = RealtimeAudioDeliveryQueue()
    /// Whether the process-wide CoreAudio input path has been warmed once.
    ///
    /// The first `inputNode.outputFormat(forBus:)` in a process costs 180–622ms
    /// (measured) because it instantiates the CoreAudio IO unit; later engines
    /// are cheaper. Doing that once at launch takes the worst case off the first
    /// recording.
    ///
    /// We deliberately do NOT keep a prepared engine around for the recording to
    /// adopt. That was tried and it silently produced zero-sample recordings:
    /// `prepare()` configures the render chain, and a tap installed afterwards
    /// does not reconfigure the input unit, so capture ran and delivered nothing.
    /// Correct audio outranks the remaining ~200ms.
    private var didWarmCoreAudio = false


    private let realtimeOutputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )

    override private init() {
        super.init()
        // Microphone permission is now handled by OnboardingManager

        // Listen for audio input device changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioDeviceChanged),
            name: NSNotification.Name("AudioInputDeviceChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigurationChanged),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )

        // Build the AVAudioEngine only for active recording sessions. Keeping an idle
        // engine registered with Core Audio makes Bluetooth route-change bursts more
        // likely to hit AVAudioIOUnit's hardware-format callbacks.
    }

    /// Warms the process-wide CoreAudio input path. Does not retain an engine.
    func prewarmEngine() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.prewarmEngine() }
            return
        }
        guard !didWarmCoreAudio, !isRecording, pendingPreparation == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }

        // Build, touch the input node to force IO-unit instantiation, discard.
        // Never prepared, never started, never reused for a recording.
        let probe = AVAudioEngine()
        _ = probe.inputNode.outputFormat(forBus: 0)
        didWarmCoreAudio = true
        DebugLog.info("CoreAudio input path warmed", context: "AudioRecorder LOG")
    }

    @objc private func handleAudioDeviceChanged(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioDeviceChanged(notification)
            }
            return
        }

        DebugLog.info("Audio input device changed", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("input_device_changed")

        // The capture graph is bound to a specific AudioDeviceID and input
        // data source. Ignore default-input notifications so they cannot
        // tear down a live session. HAL source changes are restored by
        // AudioDeviceManager's capture pin, not by rebuilding the engine.
        if pendingPreparation != nil {
            DebugLog.info(
                "Ignoring device change during preparation - device is pinned",
                context: "AudioRecorder LOG"
            )
            SentryTelemetry.recordAudioEngineEvent(
                "device_change_ignored_preparation"
            )
            return
        }
        if isRecording, activeCapture != nil {
            DebugLog.info(
                "Ignoring device change during recording - device is pinned",
                context: "AudioRecorder LOG"
            )
            SentryTelemetry.recordAudioEngineEvent(
                "device_change_ignored_recording"
            )
            return
        }
    }

    @objc private func handleAudioEngineConfigurationChanged(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioEngineConfigurationChanged(notification)
            }
            return
        }

        DebugLog.info("Audio engine configuration changed", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("configuration_changed")

        guard let changedEngine = notification.object as? AVAudioEngine else { return }

        // Configuration-change notifications are ignored during preparation
        // and recording so we do not race HAL by tearing down the graph.
        // The input unit is bound to the selected device; if it actually
        // stops, the watchdog recovers on that same device UID.
        if let pendingPreparation, pendingPreparation.owns(engine: changedEngine) {
            DebugLog.info(
                "Ignoring engine configuration change during preparation - device is pinned",
                context: "AudioRecorder LOG"
            )
            SentryTelemetry.recordAudioEngineEvent(
                "config_change_ignored_preparation"
            )
            return
        }
        if isRecording,
           let session = activeCapture,
           session.owns(engine: changedEngine)
        {
            DebugLog.info(
                "Ignoring engine configuration change during recording - device is pinned",
                context: "AudioRecorder LOG"
            )
            SentryTelemetry.recordAudioEngineEvent(
                "config_change_ignored_recording"
            )
            return
        }
    }

    func startRecording(
        recordingID: UUID,
        recordingURL: URL,
        completion: @escaping (RecordingPreparationAttempt.Terminal) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startRecording(
                    recordingID: recordingID,
                    recordingURL: recordingURL,
                    completion: completion
                )
            }
            return
        }

        DebugLog.info("⚡ startRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("start_recording")

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            DebugLog.info("❌ Microphone permission is not authorized", context: "AudioRecorder LOG")
            completion(.failed("Microphone access is required to start recording."))
            return
        }

        guard pendingPreparation == nil,
              pendingFinalization == nil,
              activeCapture == nil,
              !isRecording,
              !terminationCloseRequested
        else {
            completion(.failed("Recording is already active."))
            return
        }

        let deviceSnapshot = AudioDeviceManager.shared.makeCaptureSelectionSnapshot()
        let closeProof = MacNativeRecorderCloseProof()
        nativeCloseProofs[recordingID] = closeProof
        nativeRecordingURLs[recordingID] = recordingURL
        let preparation = MacCapturePreparation(
            recordingID: recordingID,
            recordingURL: recordingURL,
            closeProof: closeProof,
            completion: completion
        )
        pendingPreparation = preparation

        preparation.queue.async { [weak self, weak preparation] in
            guard let self, let preparation else { return }
            self.prepareCapture(preparation, deviceSnapshot: deviceSnapshot)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.recordingPreparationTimeout) { [weak self, weak preparation] in
            guard let self, let preparation, self.pendingPreparation === preparation else { return }
            guard preparation.attempt.resolve(.timedOut) else { return }

            preparation.retireSession()
            self.pendingPreparation = nil
            self.resetFailedStart()
            preparation.completion(.timedOut)
            preparation.scheduleCleanup(deleteFile: true)
        }
    }

    func cancelPendingRecordingStart() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingRecordingStart()
            }
            return
        }

        guard let preparation = pendingPreparation,
              preparation.attempt.resolve(.cancelled)
        else { return }

        preparation.retireSession()
        pendingPreparation = nil
        resetFailedStart()
        preparation.completion(.cancelled)
        preparation.scheduleCleanup(deleteFile: true)
    }

    /// Cancels one exact capture attempt across the preparation-to-active
    /// promotion boundary. Main-queue serialization makes the operation atomic:
    /// it either resolves the pending attempt or retires the just-promoted
    /// active session, so a late `.ready` cannot leave native capture running.
    func cancelPendingOrActiveCapture(recordingID: UUID) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingOrActiveCapture(recordingID: recordingID)
            }
            return
        }

        if let preparation = pendingPreparation,
           preparation.recordingID == recordingID {
            guard preparation.attempt.resolve(.cancelled) else { return }
            preparation.retireSession()
            pendingPreparation = nil
            resetFailedStart()
            preparation.completion(.cancelled)
            preparation.scheduleCleanup(deleteFile: true)
            return
        }

        guard let session = activeCapture,
              session.recordingID == recordingID else { return }
        activeCapture = nil
        session.retire()
        resetFailedStart()
        DispatchQueue(
            label: "ai.writingmate.audio-cancel.\(recordingID.uuidString)",
            qos: .utility
        ).async {
            session.cleanup(deleteFile: true)
        }
    }

    /// Transfers every matching native writer into retained termination
    /// ownership before clearing its public slot. Returned proof identities are
    /// stable across repeated Quit attempts and are never consumed by polling.
    func beginTerminationClose(
        recordingIDs: Set<UUID>
    ) -> [UUID: MacNativeRecorderCloseProof] {
        precondition(Thread.isMainThread)
        terminationCloseRequested = true
        let ownedRecordingIDs = recordingIDs.union(nativeCloseProofs.keys)

        if let preparation = pendingPreparation,
           ownedRecordingIDs.contains(preparation.recordingID) {
            _ = preparation.attempt.resolve(.cancelled)
            preparation.retireSession()
            pendingPreparation = nil
            resetFailedStart()
            preparation.completion(.cancelled)
            preparation.scheduleCleanup(deleteFile: false)
        }

        if let session = activeCapture,
           ownedRecordingIDs.contains(session.recordingID) {
            activeCapture = nil
            session.retire()
            resetFailedStart()
            DispatchQueue(
                label: "ai.writingmate.audio-termination.\(session.recordingID.uuidString)",
                qos: .utility
            ).async {
                session.cleanup(deleteFile: false)
            }
        }

        // A finalization already owns cleanup on its serial queue. Its stable
        // proof remains in nativeCloseProofs until the caller observes closure.
        return nativeCloseProofs.filter { ownedRecordingIDs.contains($0.key) }
    }

    func acknowledgeConfirmedClose(recordingID: UUID) {
        precondition(Thread.isMainThread)
        guard nativeCloseProofs[recordingID]?.isConfirmedClosed == true else { return }
        confirmedNativeCloseAttestations[recordingID] = .init(
            attemptID: recordingID,
            processID: MacAudioProcessingStore.currentProcessID
        )
        nativeCloseProofs.removeValue(forKey: recordingID)
        nativeRecordingURLs.removeValue(forKey: recordingID)
    }

    func nativeCloseState(recordingID: UUID) -> NativeCloseState {
        precondition(Thread.isMainThread)
        if let attestation = confirmedNativeCloseAttestations[recordingID] {
            return .confirmed(attestation)
        }
        if let proof = nativeCloseProofs[recordingID] {
            if proof.isConfirmedClosed {
                let attestation = MacAudioProcessingStore.NativeWriterCloseAttestation(
                    attemptID: recordingID,
                    processID: MacAudioProcessingStore.currentProcessID
                )
                confirmedNativeCloseAttestations[recordingID] = attestation
                return .confirmed(attestation)
            }
            return .pending
        }
        return .unknown
    }

    func observeNativeClose(
        recordingID: UUID,
        completion: @escaping @MainActor (
            MacAudioProcessingStore.NativeWriterCloseAttestation
        ) -> Void
    ) {
        precondition(Thread.isMainThread)
        switch nativeCloseState(recordingID: recordingID) {
        case .confirmed(let attestation):
            completion(attestation)
        case .pending:
            guard let proof = nativeCloseProofs[recordingID] else { return }
            proof.whenConfirmed { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let attestation = MacAudioProcessingStore.NativeWriterCloseAttestation(
                        attemptID: recordingID,
                        processID: MacAudioProcessingStore.currentProcessID
                    )
                    self.confirmedNativeCloseAttestations[recordingID] = attestation
                    completion(attestation)
                }
            }
        case .unknown:
            break
        }
    }

    @discardableResult
    func releaseTerminationBarrierIfClosed(recordingIDs: Set<UUID>) -> Bool {
        precondition(Thread.isMainThread)
        let unresolved = recordingIDs.contains { nativeCloseProofs[$0]?.isConfirmedClosed == false }
        guard !unresolved else { return false }
        terminationCloseRequested = false
        for recordingID in recordingIDs
            where nativeCloseProofs[recordingID]?.isConfirmedClosed == true {
            confirmedNativeCloseAttestations[recordingID] = .init(
                attemptID: recordingID,
                processID: MacAudioProcessingStore.currentProcessID
            )
            nativeCloseProofs.removeValue(forKey: recordingID)
            nativeRecordingURLs.removeValue(forKey: recordingID)
        }
        return true
    }

    private func prepareCapture(
        _ preparation: MacCapturePreparation,
        deviceSnapshot: AudioDeviceManager.CaptureSelectionSnapshot
    ) {
        guard preparation.attempt.isPending else { return }

        guard let deviceResolution = AudioDeviceManager.shared.resolveCaptureDevice(using: deviceSnapshot) else {
            failPreparation(
                preparation,
                message: "The selected microphone is unavailable. Choose another microphone and try again."
            )
            return
        }
        guard preparation.accept(deviceResolution: deviceResolution) else {
            failPreparation(
                preparation,
                message: "The microphone changed before recording started. Please try again."
            )
            return
        }

        guard preparation.attempt.isPending else { return }

        AudioDeviceManager.shared.beginCapturePin(
            recordingID: preparation.recordingID,
            resolution: deviceResolution
        )

        guard let pinnedGraph = makePinnedCaptureGraph(deviceResolution: deviceResolution) else {
            failPreparation(preparation, message: "The microphone audio format is unavailable. Please try again.")
            return
        }
        let engine = pinnedGraph.engine
        let inputNode = pinnedGraph.inputNode
        let bus = 0
        let inputFormat = pinnedGraph.inputFormat
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: Constants.transcriptionSampleRate,
                  channels: 1,
                  interleaved: false
              )
        else {
            failPreparation(preparation, message: "The microphone audio format is unavailable. Please try again.")
            return
        }

        let recordingURL = preparation.recordingURL

        do {
            let audioFile = try AVAudioFile(
                forWriting: recordingURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: Constants.transcriptionSampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: Constants.transcriptionBitRate,
                ]
            )
            let session = MacCaptureSession(
                recordingID: preparation.recordingID,
                engine: engine,
                audioFile: audioFile,
                recordingURL: recordingURL,
                outputFormat: outputFormat,
                deviceResolution: deviceResolution,
                closeProof: preparation.closeProof
            )
            preparation.setSession(session)

            let generation = session.currentEngineGeneration
            inputNode.installTap(onBus: bus, bufferSize: 2048, format: nil) { [weak self, preparation, weak session, weak engine] buffer, _ in
                guard let self, let session else { return }
                guard let engine,
                      session.accepts(engine: engine, generation: generation)
                else { return }
                self.processCaptureBuffer(
                    buffer,
                    session: session,
                    preparation: preparation,
                    engine: engine,
                    generation: generation
                )
            }

            guard preparation.attempt.isPending else {
                preparation.scheduleCleanup(deleteFile: true)
                return
            }

            do {
                try engine.start()
                AudioDeviceManager.shared.restorePinnedInputDataSourceIfNeeded()
            } catch {
                failPreparation(preparation, message: "Recording could not start. Please try again.")
                preparation.scheduleCleanup(deleteFile: true)
                return
            }

            if session.markEngineStarted() {
                signalPreparationReady(preparation, session: session)
            }

            if !preparation.attempt.isPending, preparation.attempt.terminal != .ready {
                preparation.scheduleCleanup(deleteFile: true)
            }
        } catch {
            failPreparation(preparation, message: "Recording could not start. Please try again.")
            preparation.scheduleCleanup(deleteFile: true)
        }
    }

    private func processCaptureBuffer(
        _ buffer: AVAudioPCMBuffer,
        session: MacCaptureSession,
        preparation: MacCapturePreparation?,
        engine: AVAudioEngine,
        generation: UInt64
    ) {
        // Reserve realtime delivery before any file/conversion work. Native
        // stop seals this generation after retiring write admission and waits
        // for every reservation, so no written head or tail buffer is omitted.
        let realtimeDeliveryLease = realtimeAudioDelivery.beginDelivery()
        defer { realtimeDeliveryLease?.discard() }

        // Keep every callback-local AVAudioFile reference inside this lexical
        // scope. It must be released before finishWrite decrements activeWrites;
        // cleanup is then free to nil the session's final reference and attest
        // the actual container close.
        guard let writeResult = autoreleasepool(invoking: {
            () -> (lease: MacCaptureSession.WriteLease, error: Error?)? in
            guard let write = session.beginWrite() else { return nil }
            do {
                let bufferFormat = buffer.format
                if bufferFormat.sampleRate != session.outputFormat.sampleRate
                    || bufferFormat.channelCount != session.outputFormat.channelCount,
                    let converter = session.converter(from: bufferFormat)
                {
                    let ratio = session.outputFormat.sampleRate / bufferFormat.sampleRate
                    guard let convertedBuffer = AVAudioPCMBuffer(
                        pcmFormat: session.outputFormat,
                        frameCapacity: AVAudioFrameCount(
                            max(1, ceil(Double(buffer.frameLength) * ratio))
                        )
                    ) else {
                        throw NSError(domain: "AudioRecorder", code: 1)
                    }

                    var conversionError: NSError?
                    var providedInput = false
                    converter.convert(
                        to: convertedBuffer,
                        error: &conversionError
                    ) { _, status in
                        guard !providedInput else {
                            status.pointee = .noDataNow
                            return nil
                        }
                        providedInput = true
                        status.pointee = .haveData
                        return buffer
                    }
                    if let conversionError { throw conversionError }
                    try write.audioFile.write(from: convertedBuffer)
                } else {
                    try write.audioFile.write(from: buffer)
                }
                return (write.lease, nil)
            } catch {
                return (write.lease, error)
            }
        }) else { return }

        if let writeError = writeResult.error {
            let failureMessage: String
            switch writeResult.lease {
            case .preparation:
                failureMessage = "The recording could not be saved. Please try again."
            case .active:
                failureMessage = "The recording could not be saved completely. Please record again."
            }
            let outcome = session.finishWrite(
                succeeded: false,
                lease: writeResult.lease,
                failureMessage: failureMessage
            )
            DebugLog.info(
                "❌ Failed to write audio buffer: \(writeError)",
                context: "AudioRecorder LOG"
            )

            switch outcome {
            case .preparationFailed:
                if let preparation {
                    failPreparation(
                        preparation,
                        message: "The recording could not be saved. Please try again."
                    )
                    preparation.scheduleCleanup(deleteFile: true)
                }
            case .activeFailed:
                reportCaptureFailure(
                    "The recording could not be saved completely. Please record again.",
                    session: session
                )
            case .becameReady, .accepted, .ignored:
                break
            }
            return
        } else {
            if session.finishWrite(
                succeeded: true,
                lease: writeResult.lease
            ) == .becameReady {
                if let preparation {
                    signalPreparationReady(preparation, session: session)
                }
            }
        }

        // Meter updates are only useful while capture remains active. Realtime
        // delivery is intentionally not gated by this later state check: a
        // lease acquired before key-up still corresponds to audio that was
        // successfully written above and must reach the final commit.
        if session.isActive,
           session.accepts(engine: engine, generation: generation)
        {
            session.noteHealthyBuffer()
            let bands = frequencyAnalyzer.analyze(buffer: buffer)
            let level = calculateAudioLevel(from: buffer)
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, self.activeCapture === session else { return }
                self.lastAudioBufferAt = Date()
                self.frequencyBands = bands
                self.audioLevel = level
            }
        }

        if let realtimeDeliveryLease {
            if let realtimeOutputFormat,
               let chunk = session.realtimePCMChunk(
                   from: buffer,
                   outputFormat: realtimeOutputFormat
               )
            {
                realtimeDeliveryLease.deliver(chunk)
            } else {
                realtimeDeliveryLease.failCoverage()
            }
        }
    }

    /// Stops admitting realtime chunks and runs `completion` after every chunk
    /// admitted by the old handler has been delivered. This is the only safe
    /// point to commit the final realtime audio buffer.
    func detachRealtimeAudioChunkHandlerAndDrain(
        _ completion: @escaping @Sendable () -> Void
    ) {
        realtimeAudioDelivery.detachAndDrain { _ in completion() }
    }

    private func signalPreparationReady(_ preparation: MacCapturePreparation, session: MacCaptureSession) {
        DispatchQueue.main.async { [weak self, weak preparation, weak session] in
            guard let self, let preparation, let session else { return }
            guard self.pendingPreparation === preparation else {
                preparation.retireSession()
                preparation.scheduleCleanup(deleteFile: true)
                return
            }
            let activationTerminal = preparation.attempt.resolveAfterActivation(
                succeeded: session.activate(),
                failureMessage: "The recording could not be saved. Please try again."
            )
            guard activationTerminal == .ready else {
                if case .failed(let message) = activationTerminal {
                    self.pendingPreparation = nil
                    self.resetFailedStart()
                    preparation.completion(.failed(message))
                }
                preparation.retireSession()
                preparation.scheduleCleanup(deleteFile: true)
                return
            }

            self.pendingPreparation = nil
            self.activeCapture = session
            AudioDeviceManager.shared.publishCaptureDeviceResolution(session.deviceResolution)
            self.isRecording = true
            self.lastAudioBufferAt = Date()
            self.startRecordingWatchdog()
            preparation.completion(.ready)
            self.finishEngineStart()
        }
    }

    private func failPreparation(_ preparation: MacCapturePreparation, message: String) {
        guard preparation.attempt.resolve(.failed(message)) else { return }
        preparation.retireSession()

        DispatchQueue.main.async { [weak self, weak preparation] in
            guard let self, let preparation else { return }
            guard self.pendingPreparation === preparation else {
                preparation.scheduleCleanup(deleteFile: true)
                return
            }

            self.pendingPreparation = nil
            self.resetFailedStart()
            preparation.completion(.failed(message))
            preparation.scheduleCleanup(deleteFile: true)
        }
    }

    private func invalidatePendingPreparation(message: String) {
        guard let preparation = pendingPreparation,
              preparation.attempt.resolve(.invalidated)
        else { return }

        preparation.retireSession()
        pendingPreparation = nil
        resetFailedStart()
        preparation.completion(.invalidated)
        preparation.scheduleCleanup(deleteFile: true)
    }

    private func finishEngineStart() {
        let shouldMuteAudio = AppDefaults.shared.object(forKey: "muteAudioWhenRecording") as? Bool ?? true
        DebugLog.info("Mute audio setting: \(shouldMuteAudio)", context: "AudioRecorder")
        if shouldMuteAudio {
            volumeManager.lowerVolume()
        }

        DebugLog.info("✅ Recording started", context: "AudioRecorder LOG")
        DictationStopwatch.mark("mic capturing")
    }

    private func resetFailedStart() {
        stopRecordingWatchdog()
        AudioDeviceManager.shared.endCapturePin()
        isRecording = false
        audioLevel = 0.0
        frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        volumeManager.restoreVolume()
    }

    private func startRecordingWatchdog() {
        stopRecordingWatchdog()

        let timer = Timer(timeInterval: Constants.recordingWatchdogInterval, repeats: true) { [weak self] _ in
            self?.checkRecordingHealth()
        }
        recordingWatchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingWatchdog() {
        recordingWatchdogTimer?.invalidate()
        recordingWatchdogTimer = nil
        lastAudioBufferAt = nil
    }

    private func checkRecordingHealth() {
        guard isRecording else {
            stopRecordingWatchdog()
            return
        }

        guard let session = activeCapture else { return }
        guard session.engine.isRunning else {
            attemptCaptureRecovery(session, reason: "audio engine stopped")
            return
        }

        guard let lastAudioBufferAt else { return }
        if Date().timeIntervalSince(lastAudioBufferAt) > Constants.recordingBufferStallThreshold {
            attemptCaptureRecovery(session, reason: "audio buffers stalled")
        }
    }

    private func attemptCaptureRecovery(
        _ session: MacCaptureSession,
        reason: String
    ) {
        precondition(Thread.isMainThread)
        guard activeCapture === session, isRecording else { return }
        guard let recoveryAttempt = session.beginRecovery(
            maximumAttempts: Constants.captureRecoveryDelays.count
        ) else {
            if session.recoveryAttemptsExhausted(
                maximumAttempts: Constants.captureRecoveryDelays.count
            ) {
                session.retire()
                reportCaptureFailure(
                    "The microphone stopped responding. AIDictation tried to reconnect automatically. Please try again.",
                    session: session
                )
            }
            return
        }

        stopRecordingWatchdog()
        let delay = Constants.captureRecoveryDelays[recoveryAttempt - 1]
        DebugLog.warning(
            "Recovering microphone capture attempt=\(recoveryAttempt) reason=\(reason)",
            context: "AudioRecorder LOG"
        )
        SentryTelemetry.recordAudioEngineEvent("capture_recovery_started")

        session.recoveryQueue.asyncAfter(deadline: .now() + delay) { [weak self, weak session] in
            guard let self, let session else { return }
            let result = self.rebuildCaptureEngine(session)
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session, self.activeCapture === session, self.isRecording else {
                    session?.finishRecovery(engineStarted: false)
                    return
                }

                session.finishRecovery(engineStarted: result == nil)
                if let result {
                    DebugLog.warning(
                        "Microphone recovery attempt failed: \(result)",
                        context: "AudioRecorder LOG"
                    )
                    self.attemptCaptureRecovery(session, reason: "recovery start failed")
                    return
                }

                self.lastAudioBufferAt = Date()
                self.startRecordingWatchdog()
                SentryTelemetry.recordAudioEngineEvent("capture_recovery_engine_started")
            }
        }
    }

    /// Replaces only the failed CoreAudio graph. The session's open audio file,
    /// durable recording identity, and realtime delivery owner survive.
    /// Recovery rebinds the new engine to the same selected device UID and
    /// input data source; it never adopts a fresh system-default input.
    private func rebuildCaptureEngine(_ session: MacCaptureSession) -> String? {
        guard session.isActive else { return "recording is no longer active" }

        guard let pinnedGraph = makePinnedCaptureGraph(
            deviceResolution: session.deviceResolution
        ) else {
            return "microphone format is unavailable"
        }
        let engine = pinnedGraph.engine
        let inputNode = pinnedGraph.inputNode
        let inputFormat = pinnedGraph.inputFormat
        guard inputFormat.channelCount > 0 else {
            return "microphone format is unavailable"
        }

        guard let replacement = session.replaceEngine(engine) else {
            return "recording is no longer active"
        }
        teardownCaptureEngine(replacement.oldEngine)

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) {
            [weak self, weak session, weak engine] buffer, _ in
            guard let self, let session, let engine,
                  session.accepts(engine: engine, generation: replacement.generation)
            else { return }
            self.processCaptureBuffer(
                buffer,
                session: session,
                preparation: nil,
                engine: engine,
                generation: replacement.generation
            )
        }

        do {
            engine.prepare()
            try engine.start()
            AudioDeviceManager.shared.restorePinnedInputDataSourceIfNeeded()
            return nil
        } catch {
            teardownCaptureEngine(engine)
            return error.localizedDescription
        }
    }

    private func makePinnedCaptureGraph(
        deviceResolution: AudioDeviceManager.CaptureDeviceResolution
    ) -> (engine: AVAudioEngine, inputNode: AVAudioInputNode, inputFormat: AVAudioFormat)? {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let bound = AudioDeviceManager.shared.bindCaptureInputNode(
            inputNode,
            to: deviceResolution
        )
        if !bound {
            DebugLog.warning(
                "Failed to bind capture input uid=\(deviceResolution.device.uniqueID); using node after bind attempt",
                context: "AudioRecorder LOG"
            )
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { return nil }
        return (engine, inputNode, inputFormat)
    }

    private func teardownCaptureEngine(_ engine: AVAudioEngine) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        engine.reset()
    }

    private func reportCaptureFailure(_ message: String, session: MacCaptureSession) {
        guard session.recordFailure(message) else { return }

        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.activeCapture === session else { return }
            self.stopRecordingWatchdog()
            self.captureFailureHandler?(message)
        }
    }

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let rms = calculateRMS(from: buffer) else { return 0.0 }

        // Convert to dB
        let avgPower = 20 * log10(rms)

        // Normalize (-60dB to 0dB → 0.0 to 1.0)
        let minDb: Float = -60.0
        let maxDb: Float = 0.0
        let clampedPower = max(minDb, min(maxDb, avgPower))
        let normalized = (clampedPower - minDb) / (maxDb - minDb)

        // Apply boost for better visualization
        let boosted = min(normalized * 1.5, 1.0)

        return max(0.0, min(1.0, boosted))
    }

    private func calculateRMS(from buffer: AVAudioPCMBuffer) -> Float? {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        let sampleStride = max(1, Int(buffer.stride))
        var sumSquares: Float = 0
        var sampleCount = 0

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            for frame in 0 ..< frameLength {
                let sample = channelData[frame * sampleStride]
                sumSquares += sample * sample
                sampleCount += 1
            }

        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData?[0] else { return nil }
            let scale = Float(Int16.max)
            for frame in 0 ..< frameLength {
                let sample = Float(channelData[frame * sampleStride]) / scale
                sumSquares += sample * sample
                sampleCount += 1
            }

        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData?[0] else { return nil }
            let scale = Float(Int32.max)
            for frame in 0 ..< frameLength {
                let sample = Float(channelData[frame * sampleStride]) / scale
                sumSquares += sample * sample
                sampleCount += 1
            }

        default:
            return nil
        }

        guard sampleCount > 0 else { return nil }
        return sqrt(sumSquares / Float(sampleCount))
    }

    func stopRecording(
        disposition: StopDisposition = .submitIfValid,
        afterRealtimeAudioDrained: (@Sendable (Bool) -> Void)? = nil,
        completion: @escaping (RecordingFinalizationAttempt.Terminal) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stopRecording(
                    disposition: disposition,
                    afterRealtimeAudioDrained: afterRealtimeAudioDrained,
                    completion: completion
                )
            }
            return
        }

        DebugLog.info("⚡ stopRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("stop_recording")

        if pendingPreparation != nil {
            cancelPendingRecordingStart()
            realtimeAudioDelivery.detachAndDrain { _ in }
            completion(.discarded)
            return
        }

        stopRecordingWatchdog()
        guard pendingFinalization == nil else {
            realtimeAudioDelivery.detachAndDrain { _ in }
            completion(.unavailable("Recording is already being saved."))
            return
        }
        guard let session = activeCapture else {
            realtimeAudioDelivery.detachAndDrain { _ in }
            resetFailedStart()
            let closedCandidates = nativeCloseProofs.compactMap { recordingID, proof in
                proof.isConfirmedClosed
                    ? nativeRecordingURLs[recordingID]
                    : nil
            }
            if closedCandidates.count == 1,
               let closedURL = closedCandidates.first {
                completion(.finalized(closedURL))
                return
            }
            completion(.unavailable("No recording is available to save."))
            return
        }
        activeCapture = nil
        isRecording = false
        AudioDeviceManager.shared.endCapturePin(recordingID: session.recordingID)
        // Retiring the exact capture session closes durable write admission.
        // Only after that cutoff may realtime admission be sealed. A callback
        // that acquired both leases before retirement can finish both; one
        // arriving afterwards can enter neither pipeline.
        session.retire()
        realtimeAudioDelivery.detachAndDrain { coverageIsComplete in
            afterRealtimeAudioDrained?(coverageIsComplete)
        }
        let finalization = MacCaptureFinalization(
            session: session,
            deletesFile: disposition == .discard,
            completion: completion
        )
        pendingFinalization = finalization

        // Restore system volume
        let shouldMuteAudio = AppDefaults.shared.object(forKey: "muteAudioWhenRecording") as? Bool ?? true
        if shouldMuteAudio {
            volumeManager.restoreVolume()
        }

        // Update UI state synchronously so ContentView can check it immediately
        // Ensure we're on main thread for @Published property updates
        audioLevel = 0.0
        frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        DebugLog.info("Recording finalization started", context: "AudioRecorder LOG")
        DictationStopwatch.mark("finalization started")
        // Only now that capture has stopped — playing it on the key-release path
        // recorded an 85ms tone into the tail of every dictation and sent it to
        // the transcriber.
        SoundEffectManager.shared.playStop()

        finalization.queue.async { [weak self, finalization] in
            guard let self else { return }
            let deleteFile = finalization.deletesFile
            finalization.session.cleanup(deleteFile: deleteFile)

            let terminal: RecordingFinalizationAttempt.Terminal
            if deleteFile {
                terminal = .discarded
            } else if let failure = finalization.session.recordedFailure {
                terminal = .failed(
                    message: failure,
                    recoverableURL: finalization.session.recordingURL
                )
            } else if let failure = self.finalizedRecordingFailure(finalization.session.recordingURL) {
                terminal = .failed(
                    message: failure,
                    recoverableURL: finalization.session.recordingURL
                )
            } else {
                terminal = .finalized(finalization.session.recordingURL)
            }

            DispatchQueue.main.async { [weak self, weak finalization] in
                guard let self, let finalization else { return }
                DictationStopwatch.mark("recorder finalization resolved")
                self.finishFinalization(finalization, terminal: terminal)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.recordingFinalizationTimeout) { [weak self, weak finalization] in
            guard let self,
                  let finalization,
                  self.pendingFinalization === finalization
            else { return }
            self.finishFinalization(
                finalization,
                terminal: .timedOut(recoverableURL: finalization.session.recordingURL)
            )
        }
    }

    private func finishFinalization(
        _ finalization: MacCaptureFinalization,
        terminal: RecordingFinalizationAttempt.Terminal
    ) {
        guard pendingFinalization === finalization,
              finalization.attempt.resolve(terminal)
        else { return }

        pendingFinalization = nil
        finalization.completion(terminal)
    }

    private func finalizedRecordingFailure(_ url: URL) -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = attributes[.size] as? Int64 ?? 0
            DebugLog.info(
                "Recording file ready name=\(url.lastPathComponent) bytes=\(byteCount)",
                context: "DictationFlow"
            )
            DictationStopwatch.mark("container closed on disk")
            return byteCount < 1_000 ? "No speech was captured. Please try again." : nil
        } catch {
            DebugLog.info("Recording file validation failed: \(error)", context: "AudioRecorder")
            return "Recording couldn’t be verified. Please try again."
        }
    }

    deinit {
        DebugLog.info("🗑️ Deinit - cleaning up", context: "AudioRecorder LOG")

        stopRecordingWatchdog()

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)

        pendingPreparation?.scheduleCleanup(deleteFile: true)
        AudioDeviceManager.shared.endCapturePin()
        if let activeCapture {
            DispatchQueue(
                label: "ai.writingmate.audio-deinit.\(UUID().uuidString)",
                qos: .utility
            ).async {
                activeCapture.cleanup(deleteFile: false)
            }
        }

        // Restore volume as a safety measure
        volumeManager.restoreVolume()

        DebugLog.info("✅ Cleanup complete", context: "AudioRecorder LOG")
    }
}

private final class MacCapturePreparation: @unchecked Sendable {
    let recordingID: UUID
    let attempt: RecordingPreparationAttempt
    let recordingURL: URL
    let closeProof: MacNativeRecorderCloseProof
    let queue = DispatchQueue(
        label: "ai.writingmate.audio-preparation.\(UUID().uuidString)",
        qos: .userInitiated
    )
    let completion: (RecordingPreparationAttempt.Terminal) -> Void

    private let lock = NSLock()
    private var storedSession: MacCaptureSession?
    private var resolvedDeviceUID: String?
    private var lastNotifiedDeviceUID: String?

    init(
        recordingID: UUID,
        recordingURL: URL,
        closeProof: MacNativeRecorderCloseProof,
        completion: @escaping (RecordingPreparationAttempt.Terminal) -> Void
    ) {
        self.recordingID = recordingID
        attempt = RecordingPreparationAttempt(
            token: RecordingPreparationAttempt.Token(rawValue: recordingID)
        )
        self.recordingURL = recordingURL
        self.closeProof = closeProof
        self.completion = completion
    }

    func setSession(_ session: MacCaptureSession) {
        lock.lock()
        storedSession = session
        lock.unlock()

        if !attempt.isPending {
            session.retire()
        }
    }

    func retireSession() {
        lock.lock()
        let session = storedSession
        lock.unlock()
        session?.retire()
    }

    func accept(deviceResolution: AudioDeviceManager.CaptureDeviceResolution) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let uniqueID = deviceResolution.device.uniqueID
        if let lastNotifiedDeviceUID, lastNotifiedDeviceUID != uniqueID {
            return false
        }
        resolvedDeviceUID = uniqueID
        return true
    }

    func shouldInvalidate(forChangedDeviceUID uniqueID: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let uniqueID else { return true }
        if let ownedUID = storedSession?.deviceResolution.device.uniqueID ?? resolvedDeviceUID {
            return ownedUID != uniqueID
        }

        // The route changed before resolution completed. Let the background
        // resolver observe it, then reject only if its resolved UID differs.
        lastNotifiedDeviceUID = uniqueID
        return false
    }

    func owns(engine: AVAudioEngine) -> Bool {
        lock.lock()
        let matches = storedSession?.engine === engine
        lock.unlock()
        return matches
    }

    func scheduleCleanup(deleteFile: Bool) {
        queue.async {
            self.lock.lock()
            let session = self.storedSession
            self.lock.unlock()
            if let session {
                session.cleanup(deleteFile: deleteFile)
            } else {
                self.closeProof.confirmClosed()
            }
        }
    }
}

private final class MacCaptureFinalization: @unchecked Sendable {
    let attempt = RecordingFinalizationAttempt()
    let queue = DispatchQueue(
        label: "ai.writingmate.audio-finalization.\(UUID().uuidString)",
        qos: .userInitiated
    )
    let session: MacCaptureSession
    let deletesFile: Bool
    let completion: (RecordingFinalizationAttempt.Terminal) -> Void

    init(
        session: MacCaptureSession,
        deletesFile: Bool,
        completion: @escaping (RecordingFinalizationAttempt.Terminal) -> Void
    ) {
        self.session = session
        self.deletesFile = deletesFile
        self.completion = completion
    }
}

private final class MacCaptureSession: @unchecked Sendable {
    struct EngineReplacement {
        let oldEngine: AVAudioEngine
        let generation: UInt64
    }
    enum WriteLease {
        case preparation
        case active
    }

    enum WriteCompletion {
        case accepted
        case becameReady
        case preparationFailed
        case activeFailed
        case ignored
    }

    private enum Phase {
        case preparing
        case ready
        case active
        case retired
    }

    let recordingID: UUID
    let recordingURL: URL
    let outputFormat: AVAudioFormat
    let deviceResolution: AudioDeviceManager.CaptureDeviceResolution
    let closeProof: MacNativeRecorderCloseProof

    private let condition = NSCondition()
    private let cleanupClaim = RecordingPreparationCleanupClaim()
    private var phase: Phase = .preparing
    private var engineStorage: AVAudioEngine
    private var engineGeneration: UInt64 = 1
    private var recoveryPolicy = MacCaptureRecoveryPolicy()
    private var audioFile: AVAudioFile?
    private var activeWrites = 0
    private var engineStarted = false
    private var wroteBuffer = false
    private var failureMessage: String?
    private var failureDeliveryClaimed = false
    let recoveryQueue = DispatchQueue(
        label: "ai.writingmate.audio-capture-recovery.\(UUID().uuidString)",
        qos: .userInitiated
    )

    // Resampling to 16 kHz is now the normal path rather than the exception, so
    // the converter has to outlive a single buffer: rebuilding it per callback
    // throws away the resampler's filter state and rings at every seam.
    private let converterLock = NSLock()
    private var cachedConverter: AVAudioConverter?
    private var cachedConverterInputFormat: AVAudioFormat?

    // Realtime audio has its own 24 kHz PCM target. This converter must also
    // outlive individual tap callbacks: rebuilding it for every 2,048-frame
    // buffer repeatedly discards the resampler's priming/filter state and
    // produces discontinuities in the bytes sent over the WebSocket.
    private let realtimeConverterLock = NSLock()
    private var cachedRealtimeConverter: AVAudioConverter?
    private var cachedRealtimeConverterInputFormat: AVAudioFormat?
    private var cachedRealtimeConverterOutputFormat: AVAudioFormat?

    /// Returns a converter from `inputFormat` to `outputFormat`, reusing the
    /// previous one whenever the device keeps handing us the same format.
    func converter(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        converterLock.lock()
        defer { converterLock.unlock() }

        if let cachedConverter, cachedConverterInputFormat == inputFormat {
            return cachedConverter
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        cachedConverter = converter
        cachedConverterInputFormat = inputFormat
        return converter
    }

    func realtimePCMChunk(
        from buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat
    ) -> Data? {
        realtimeConverterLock.lock()
        defer { realtimeConverterLock.unlock() }

        let inputFormat = buffer.format
        let converter: AVAudioConverter
        if let cachedRealtimeConverter,
           cachedRealtimeConverterInputFormat == inputFormat,
           cachedRealtimeConverterOutputFormat == outputFormat
        {
            converter = cachedRealtimeConverter
        } else {
            guard let newConverter = AVAudioConverter(
                from: inputFormat,
                to: outputFormat
            ) else { return nil }
            cachedRealtimeConverter = newConverter
            cachedRealtimeConverterInputFormat = inputFormat
            cachedRealtimeConverterOutputFormat = outputFormat
            converter = newConverter
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        // Leave room for stateful resampler output that crosses a callback
        // boundary instead of truncating it to this callback's ideal ratio.
        let frameCapacity = AVAudioFrameCount(
            max(1, ceil(Double(buffer.frameLength) * ratio) + 64)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        var conversionError: NSError?
        var didProvideInput = false
        let status = converter.convert(
            to: convertedBuffer,
            error: &conversionError
        ) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            DebugLog.info(
                "Realtime audio conversion failed: \(conversionError)",
                context: "AudioRecorder"
            )
            return nil
        }
        guard status != .error else { return nil }
        return Self.int16PCMData(from: convertedBuffer)
    }

    private static func int16PCMData(
        from buffer: AVAudioPCMBuffer
    ) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return nil }
        return Data(bytes: channelData.pointee, count: byteCount)
    }

    init(
        recordingID: UUID,
        engine: AVAudioEngine,
        audioFile: AVAudioFile,
        recordingURL: URL,
        outputFormat: AVAudioFormat,
        deviceResolution: AudioDeviceManager.CaptureDeviceResolution,
        closeProof: MacNativeRecorderCloseProof
    ) {
        self.recordingID = recordingID
        engineStorage = engine
        self.audioFile = audioFile
        self.recordingURL = recordingURL
        self.outputFormat = outputFormat
        self.deviceResolution = deviceResolution
        self.closeProof = closeProof
    }

    var isActive: Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase == .active
    }

    var engine: AVAudioEngine {
        condition.lock()
        defer { condition.unlock() }
        return engineStorage
    }

    var currentEngineGeneration: UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return engineGeneration
    }

    func owns(engine: AVAudioEngine) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase != .retired && engineStorage === engine
    }

    func accepts(engine: AVAudioEngine, generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase != .retired
            && engineStorage === engine
            && engineGeneration == generation
    }

    func replaceEngine(_ engine: AVAudioEngine) -> EngineReplacement? {
        condition.lock()
        guard phase == .active else {
            condition.unlock()
            return nil
        }
        let oldEngine = engineStorage
        engineGeneration &+= 1
        engineStorage = engine
        let replacement = EngineReplacement(
            oldEngine: oldEngine,
            generation: engineGeneration
        )
        condition.unlock()

        converterLock.lock()
        cachedConverter = nil
        cachedConverterInputFormat = nil
        converterLock.unlock()
        realtimeConverterLock.lock()
        cachedRealtimeConverter = nil
        cachedRealtimeConverterInputFormat = nil
        cachedRealtimeConverterOutputFormat = nil
        realtimeConverterLock.unlock()
        return replacement
    }

    func beginRecovery(maximumAttempts: Int) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .active,
              let attempt = recoveryPolicy.begin(maximumAttempts: maximumAttempts)
        else { return nil }
        return attempt
    }

    func finishRecovery(engineStarted: Bool) {
        condition.lock()
        recoveryPolicy.finish()
        if !engineStarted, phase == .active {
            condition.broadcast()
        }
        condition.unlock()
    }

    func recoveryAttemptsExhausted(maximumAttempts: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return phase == .active
            && recoveryPolicy.isExhausted(maximumAttempts: maximumAttempts)
    }

    func noteHealthyBuffer() {
        condition.lock()
        recoveryPolicy.noteHealthyBuffer()
        condition.unlock()
    }

    func markEngineStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .preparing else { return false }
        engineStarted = true
        return promoteToReadyIfPossible()
    }

    func beginWrite() -> (audioFile: AVAudioFile, lease: WriteLease)? {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .preparing || phase == .ready || phase == .active,
              let audioFile
        else { return nil }

        activeWrites += 1
        let lease: WriteLease = phase == .active ? .active : .preparation
        return (audioFile, lease)
    }

    func finishWrite(
        succeeded: Bool,
        lease: WriteLease,
        failureMessage: String? = nil
    ) -> WriteCompletion {
        condition.lock()
        defer { condition.unlock() }

        let failureOutcome: WriteCompletion?
        if !succeeded {
            if self.failureMessage == nil {
                self.failureMessage = failureMessage
            }
            if phase != .retired {
                phase = .retired
            }
            switch lease {
            case .preparation:
                failureOutcome = .preparationFailed
            case .active:
                failureOutcome = .activeFailed
            }
        } else {
            failureOutcome = nil
        }

        activeWrites = max(0, activeWrites - 1)
        if activeWrites == 0 {
            condition.broadcast()
        }
        if let failureOutcome {
            return failureOutcome
        }

        guard phase == .preparing else {
            return phase == .retired ? .ignored : .accepted
        }
        wroteBuffer = true
        return promoteToReadyIfPossible() ? .becameReady : .accepted
    }

    func activate() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .ready else { return false }
        phase = .active
        return true
    }

    func retire() {
        condition.lock()
        phase = .retired
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func recordFailure(_ message: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if failureMessage == nil {
            failureMessage = message
        }
        guard !failureDeliveryClaimed else { return false }
        failureDeliveryClaimed = true
        return true
    }

    var recordedFailure: String? {
        condition.lock()
        defer { condition.unlock() }
        return failureMessage
    }

    func cleanup(deleteFile: Bool) {
        guard cleanupClaim.claim() else { return }

        retire()
        let engine = self.engine
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }

        condition.lock()
        while activeWrites > 0 {
            condition.wait()
        }
        audioFile = nil
        condition.unlock()
        closeProof.confirmClosed()

        if deleteFile {
            try? FileManager.default.removeItem(at: recordingURL)
        }
    }

    private func promoteToReadyIfPossible() -> Bool {
        guard phase == .preparing, engineStarted, wroteBuffer else { return false }
        phase = .ready
        return true
    }
}
