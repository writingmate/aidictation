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
        static let recordingPreparationTimeout: TimeInterval = 5.0
        static let recordingFinalizationTimeout: TimeInterval = 5.0
    }

    enum StopDisposition: Equatable {
        case submitIfValid
        case discard
    }

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0 // Audio level for visualization (0.0 to 1.0)
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: frequencyBandCount) // Frequency spectrum data
    var realtimeAudioChunkHandler: ((Data) -> Void)? {
        get {
            realtimeHandlerLock.lock()
            defer { realtimeHandlerLock.unlock() }
            return storedRealtimeAudioChunkHandler
        }
        set {
            realtimeHandlerLock.lock()
            storedRealtimeAudioChunkHandler = newValue
            realtimeHandlerLock.unlock()
        }
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
    private var nativeRecordingURLs: [UUID: URL] = [:]
    private var terminationCloseRequested = false
    private let realtimeHandlerLock = NSLock()
    private var storedRealtimeAudioChunkHandler: ((Data) -> Void)?
    private let realtimeAudioQueue = DispatchQueue(label: "ai.writingmate.realtime-audio")
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

    @objc private func handleAudioDeviceChanged(_ notification: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioDeviceChanged(notification)
            }
            return
        }

        DebugLog.info("Audio input device changed", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("input_device_changed")

        let changedDeviceUID = notification.object as? String
        if let pendingPreparation {
            if !pendingPreparation.shouldInvalidate(forChangedDeviceUID: changedDeviceUID) {
                return
            }
            invalidatePendingPreparation(
                message: "The microphone changed before recording started. Please try again."
            )
        } else if isRecording, let session = activeCapture {
            if changedDeviceUID == session.deviceResolution.device.uniqueID {
                return
            }
            session.retire()
            reportCaptureFailure(
                "The microphone changed while recording. Please record again.",
                session: session
            )
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
        if let pendingPreparation, pendingPreparation.owns(engine: changedEngine) {
            invalidatePendingPreparation(
                message: "The microphone changed before recording started. Please try again."
            )
        } else if isRecording, let session = activeCapture, session.engine === changedEngine {
            session.retire()
            reportCaptureFailure(
                "The microphone changed while recording. Please record again.",
                session: session
            )
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
              !terminationCloseRequested,
              !nativeCloseProofs.values.contains(where: { !$0.isConfirmedClosed })
        else {
            completion(.failed("Recording is already active."))
            return
        }

        let retainedIDs = Set(
            nativeCloseProofs
                .filter { !$0.value.isConfirmedClosed }
                .map(\.key)
        )
        nativeCloseProofs = nativeCloseProofs.filter { retainedIDs.contains($0.key) }
        nativeRecordingURLs = nativeRecordingURLs.filter { retainedIDs.contains($0.key) }
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

        if let preparation = pendingPreparation,
           recordingIDs.contains(preparation.recordingID) {
            _ = preparation.attempt.resolve(.cancelled)
            preparation.retireSession()
            pendingPreparation = nil
            resetFailedStart()
            preparation.completion(.cancelled)
            preparation.scheduleCleanup(deleteFile: false)
        }

        if let session = activeCapture,
           recordingIDs.contains(session.recordingID) {
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
        return nativeCloseProofs.filter { recordingIDs.contains($0.key) }
    }

    func acknowledgeConfirmedClose(recordingID: UUID) {
        precondition(Thread.isMainThread)
        guard nativeCloseProofs[recordingID]?.isConfirmedClosed == true else { return }
        nativeCloseProofs.removeValue(forKey: recordingID)
        nativeRecordingURLs.removeValue(forKey: recordingID)
    }

    @discardableResult
    func releaseTerminationBarrierIfClosed(recordingIDs: Set<UUID>) -> Bool {
        precondition(Thread.isMainThread)
        let unresolved = recordingIDs.contains { nativeCloseProofs[$0]?.isConfirmedClosed == false }
        guard !unresolved else { return false }
        terminationCloseRequested = false
        for recordingID in recordingIDs
            where nativeCloseProofs[recordingID]?.isConfirmedClosed == true {
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

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let bus = 0
        let inputFormat = inputNode.outputFormat(forBus: bus)
        guard inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 44_100,
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
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
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

            inputNode.installTap(onBus: bus, bufferSize: 2048, format: nil) { [weak self, preparation, weak session] buffer, _ in
                guard let self, let session else { return }
                self.processCaptureBuffer(buffer, session: session, preparation: preparation)
            }

            guard preparation.attempt.isPending else {
                preparation.scheduleCleanup(deleteFile: true)
                return
            }

            do {
                try engine.start()
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
        preparation: MacCapturePreparation
    ) {
        guard let write = session.beginWrite() else { return }
        let audioFile = write.audioFile

        do {
            let bufferFormat = buffer.format
            if bufferFormat.sampleRate != session.outputFormat.sampleRate
                || bufferFormat.channelCount != session.outputFormat.channelCount,
                let converter = AVAudioConverter(from: bufferFormat, to: session.outputFormat)
            {
                let ratio = session.outputFormat.sampleRate / bufferFormat.sampleRate
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: session.outputFormat,
                    frameCapacity: AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio)))
                ) else {
                    throw NSError(domain: "AudioRecorder", code: 1)
                }

                var conversionError: NSError?
                var providedInput = false
                converter.convert(to: convertedBuffer, error: &conversionError) { _, status in
                    guard !providedInput else {
                        status.pointee = .noDataNow
                        return nil
                    }
                    providedInput = true
                    status.pointee = .haveData
                    return buffer
                }
                if let conversionError { throw conversionError }
                try audioFile.write(from: convertedBuffer)
            } else {
                try audioFile.write(from: buffer)
            }

            if session.finishWrite(succeeded: true, lease: write.lease) == .becameReady {
                signalPreparationReady(preparation, session: session)
            }
        } catch {
            let failureMessage: String
            switch write.lease {
            case .preparation:
                failureMessage = "The recording could not be saved. Please try again."
            case .active:
                failureMessage = "The recording could not be saved completely. Please record again."
            }
            let outcome = session.finishWrite(
                succeeded: false,
                lease: write.lease,
                failureMessage: failureMessage
            )
            DebugLog.info("❌ Failed to write audio buffer: \(error)", context: "AudioRecorder LOG")

            switch outcome {
            case .preparationFailed:
                failPreparation(
                    preparation,
                    message: "The recording could not be saved. Please try again."
                )
                preparation.scheduleCleanup(deleteFile: true)
            case .activeFailed:
                reportCaptureFailure(
                    "The recording could not be saved completely. Please record again.",
                    session: session
                )
            case .becameReady, .accepted, .ignored:
                break
            }
            return
        }

        guard session.isActive else { return }
        let bands = frequencyAnalyzer.analyze(buffer: buffer)
        let level = calculateAudioLevel(from: buffer)
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, self.activeCapture === session else { return }
            self.lastAudioBufferAt = Date()
            self.frequencyBands = bands
            self.audioLevel = level
        }

        if let chunk = realtimePCMChunk(from: buffer), let handler = realtimeAudioChunkHandler {
            realtimeAudioQueue.async {
                handler(chunk)
            }
        }
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
    }

    private func resetFailedStart() {
        stopRecordingWatchdog()
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

        guard let session = activeCapture, session.engine.isRunning else {
            if let session = activeCapture {
                session.retire()
                reportCaptureFailure(
                    "The microphone stopped responding. Please record again.",
                    session: session
                )
            }
            return
        }

        guard let lastAudioBufferAt else { return }
        if Date().timeIntervalSince(lastAudioBufferAt) > Constants.recordingBufferStallThreshold {
            session.retire()
            reportCaptureFailure(
                "The microphone stopped responding. Please record again.",
                session: session
            )
        }
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

    private func realtimePCMChunk(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let realtimeOutputFormat else { return nil }

        let inputFormat = buffer.format
        guard let converter = AVAudioConverter(from: inputFormat, to: realtimeOutputFormat) else {
            return nil
        }

        let ratio = realtimeOutputFormat.sampleRate / inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio)))
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: realtimeOutputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            DebugLog.info("Realtime audio conversion failed: \(conversionError)", context: "AudioRecorder")
            return nil
        }

        guard let channelData = convertedBuffer.int16ChannelData else { return nil }
        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return nil }

        return Data(bytes: channelData.pointee, count: byteCount)
    }

    func stopRecording(
        disposition: StopDisposition = .submitIfValid,
        completion: @escaping (RecordingFinalizationAttempt.Terminal) -> Void
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stopRecording(disposition: disposition, completion: completion)
            }
            return
        }

        DebugLog.info("⚡ stopRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("stop_recording")

        if pendingPreparation != nil {
            cancelPendingRecordingStart()
            completion(.discarded)
            return
        }

        stopRecordingWatchdog()
        guard pendingFinalization == nil else {
            completion(.unavailable("Recording is already being saved."))
            return
        }
        guard let session = activeCapture else {
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
        session.retire()
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
    let engine: AVAudioEngine
    let recordingURL: URL
    let outputFormat: AVAudioFormat
    let deviceResolution: AudioDeviceManager.CaptureDeviceResolution
    let closeProof: MacNativeRecorderCloseProof

    private let condition = NSCondition()
    private let cleanupClaim = RecordingPreparationCleanupClaim()
    private var phase: Phase = .preparing
    private var audioFile: AVAudioFile?
    private var activeWrites = 0
    private var engineStarted = false
    private var wroteBuffer = false
    private var failureMessage: String?
    private var failureDeliveryClaimed = false

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
        self.engine = engine
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
