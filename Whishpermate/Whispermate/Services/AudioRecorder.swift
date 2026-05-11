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
        static let engineRecoveryCooldown: TimeInterval = 2.0
    }

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0 // Audio level for visualization (0.0 to 1.0)
    @Published var frequencyBands: [Float] = Array(repeating: 0.0, count: frequencyBandCount) // Frequency spectrum data
    var realtimeAudioChunkHandler: ((Data) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private let volumeManager = AudioVolumeManager()
    private let frequencyAnalyzer = FrequencyAnalyzer()
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var pendingEngineRefresh = false
    private var refreshWorkItem: DispatchWorkItem?
    private var recordingWatchdogTimer: Timer?
    private var lastAudioBufferAt: Date?
    private var lastEngineRecoveryAt: Date?
    private var retiredEngines: [AVAudioEngine] = []
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

        // Only pre-initialize the audio engine if microphone permission is already granted
        // This prevents triggering the permission dialog on app launch
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            if let device = AudioDeviceManager.shared.applyPreferredOrAutomaticDevice() {
                DebugLog.info("Pre-initializing audio engine with input device: \(device.name)", context: "AudioRecorder LOG")
                setupAudioEngine()
            } else {
                DebugLog.info("Skipping audio engine pre-initialization because no preferred input device is available", context: "AudioRecorder LOG")
            }
        }
    }

    @objc private func handleAudioDeviceChanged(_: Notification) {
        DebugLog.info("Audio input device changed", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("input_device_changed")
        // Don't restart if currently recording - let the current recording finish
        // Only reinitialize the engine when not recording
        if !isRecording {
            pendingEngineRefresh = true
            scheduleEngineRefresh()
        } else {
            DebugLog.info("Currently recording - will use new device on next recording", context: "AudioRecorder LOG")
        }
    }

    @objc private func handleAudioEngineConfigurationChanged(_: Notification) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.handleAudioEngineConfigurationChanged(Notification(name: .AVAudioEngineConfigurationChange))
            }
            return
        }

        DebugLog.info("Audio engine configuration changed", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("configuration_changed")
        if isRecording {
            recoverAudioEngineDuringRecording(reason: "configuration change")
        } else {
            pendingEngineRefresh = true
            scheduleEngineRefresh()
        }
    }

    private func scheduleEngineRefresh() {
        refreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.pendingEngineRefresh, !self.isRecording else { return }

            DebugLog.info("Reinitializing engine with new device", context: "AudioRecorder LOG")
            guard let device = AudioDeviceManager.shared.applyPreferredOrAutomaticDevice() else {
                DebugLog.info("Deferring engine refresh because preferred input device is unavailable", context: "AudioRecorder LOG")
                return
            }

            DebugLog.info("Refreshing engine with input device: \(device.name)", context: "AudioRecorder LOG")
            SentryTelemetry.recordAudioDeviceEvent("engine_refresh_device", device: device)
            self.pendingEngineRefresh = false
            self.setupAudioEngine()
        }

        refreshWorkItem = workItem

        // Audio route changes often arrive in bursts; debounce to avoid tearing down the engine
        // while AVAudioIOUnit is still dispatching internal callbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func retireEngine(_ engine: AVAudioEngine) {
        retiredEngines.append(engine)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            let releasedEngines = self.retiredEngines.filter { $0 === engine }
            self.retiredEngines.removeAll { $0 === engine }
            DispatchQueue.global(qos: .utility).async {
                _ = releasedEngines
            }
        }
    }

    private func setupAudioEngine() {
        DebugLog.info("🎙️ Setting up audio engine (persistent mode)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("setup")

        // Clean up existing engine if any
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
            retireEngine(engine)
        }

        do {
            // Create AVAudioEngine
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let bus = 0
            inputFormat = inputNode.outputFormat(forBus: bus)

            // Create output format for M4A file (AAC, 44.1kHz, mono)
            outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 44100.0,
                channels: 1,
                interleaved: false
            )

            guard inputFormat != nil, let outputFormat = outputFormat else {
                DebugLog.info("❌ Failed to create audio formats", context: "AudioRecorder LOG")
                return
            }

            // Install tap for both recording and frequency analysis
            // The tap runs continuously, but only writes to file when isRecording is true
            // Use nil format to let system choose - avoids format mismatch errors
            inputNode.installTap(onBus: bus, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Only analyze and update visualization when actually recording
                if self.isRecording {
                    let bands = self.frequencyAnalyzer.analyze(buffer: buffer)
                    let level = self.calculateAudioLevel(from: buffer)

                    DispatchQueue.main.async {
                        self.lastAudioBufferAt = Date()
                        self.frequencyBands = bands
                        self.audioLevel = level
                    }
                }

                // Only write to file when actually recording
                guard self.isRecording, let audioFile = self.audioFile else { return }

                do {
                    // Use buffer's actual format for conversion (since we use nil tap format)
                    let bufferFormat = buffer.format

                    // Convert to output format if needed
                    if bufferFormat.sampleRate != outputFormat.sampleRate || bufferFormat.channelCount != outputFormat.channelCount,
                       let converter = AVAudioConverter(from: bufferFormat, to: outputFormat)
                    {
                        let ratio = outputFormat.sampleRate / bufferFormat.sampleRate
                        let convertedBuffer = AVAudioPCMBuffer(
                            pcmFormat: outputFormat,
                            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                        )!

                        var error: NSError?
                        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                            outStatus.pointee = .haveData
                            return buffer
                        }

                        if error == nil {
                            try audioFile.write(from: convertedBuffer)
                        }
                    } else {
                        // Same format, write directly
                        try audioFile.write(from: buffer)
                    }
                } catch {
                    DebugLog.info("❌ Failed to write audio buffer: \(error)", context: "AudioRecorder LOG")
                }

                if let chunk = self.realtimePCMChunk(from: buffer), let handler = self.realtimeAudioChunkHandler {
                    self.realtimeAudioQueue.async {
                        handler(chunk)
                    }
                }
            }

            // Don't start the engine yet - only start when recording begins
            audioEngine = engine

            DebugLog.info("✅ Audio engine initialized (will start on recording)", context: "AudioRecorder LOG")
        } catch {
            DebugLog.info("❌ Failed to setup audio engine: \(error)", context: "AudioRecorder LOG")
        }
    }

    func startRecording() {
        DebugLog.info("⚡ startRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("start_recording")

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            DebugLog.info("❌ Microphone permission is not authorized", context: "AudioRecorder LOG")
            return
        }

        guard let inputDevice = AudioDeviceManager.shared.applyPreferredOrAutomaticDevice() else {
            DebugLog.info("❌ Preferred input device is unavailable; refusing to record from fallback microphone", context: "AudioRecorder LOG")
            return
        }
        DebugLog.info("Using input device for recording: \(inputDevice.name)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioDeviceEvent("recording_input_device", device: inputDevice)

        if pendingEngineRefresh {
            DebugLog.info("Applying deferred audio engine refresh before recording", context: "AudioRecorder LOG")
            pendingEngineRefresh = false
            refreshWorkItem?.cancel()
            setupAudioEngine()
        }

        // Ensure engine is set up
        if audioEngine == nil {
            DebugLog.info("Engine not initialized, setting up...", context: "AudioRecorder LOG")
            setupAudioEngine()
        }

        // Start the engine if not running
        guard let engine = audioEngine else {
            DebugLog.info("❌ Engine not available", context: "AudioRecorder LOG")
            return
        }

        // Prepare recording file
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
        let newRecordingURL = tempDirectory.appendingPathComponent(fileName)

        // Delete any existing file at this path
        if fileManager.fileExists(atPath: newRecordingURL.path) {
            try? fileManager.removeItem(at: newRecordingURL)
        }

        recordingURL = newRecordingURL

        guard outputFormat != nil else {
            DebugLog.info("❌ Output format not initialized - audioEngine: \(audioEngine != nil)", context: "AudioRecorder LOG")
            return
        }

        do {
            // Create audio file for writing
            audioFile = try AVAudioFile(
                forWriting: newRecordingURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
            )

            // Update UI state synchronously so ContentView can check it immediately
            // Ensure we're on main thread for @Published property updates
            if Thread.isMainThread {
                isRecording = true
                lastAudioBufferAt = Date()
            } else {
                DispatchQueue.main.sync {
                    self.isRecording = true
                    self.lastAudioBufferAt = Date()
                }
            }
            startRecordingWatchdog()

            let engineWasStarted = engine.isRunning
            if !engineWasStarted {
                do {
                    try engine.start()
                    DebugLog.info("✅ Audio engine started", context: "AudioRecorder LOG")
                    // Give the engine a moment to start processing audio
                    usleep(50000) // 50ms delay to let audio pipeline stabilize
                } catch {
                    DebugLog.info("❌ Failed to start audio engine: \(error)", context: "AudioRecorder LOG")
                    resetFailedStart()
                    return
                }
            }

            // Lower system volume to duck other audio only after recording has actually started.
            let shouldMuteAudio = AppDefaults.shared.object(forKey: "muteAudioWhenRecording") as? Bool ?? true
            DebugLog.info("Mute audio setting: \(shouldMuteAudio)", context: "AudioRecorder")
            if shouldMuteAudio {
                volumeManager.lowerVolume()
            }

            DebugLog.info("✅ Recording started", context: "AudioRecorder LOG")
        } catch {
            DebugLog.info("❌ Failed to create audio file: \(error)", context: "AudioRecorder LOG")
            resetFailedStart()
        }
    }

    private func resetFailedStart() {
        stopRecordingWatchdog()
        audioFile = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        if Thread.isMainThread {
            isRecording = false
            audioLevel = 0.0
            frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        } else {
            DispatchQueue.main.sync {
                self.isRecording = false
                self.audioLevel = 0.0
                self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
            }
        }
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

        guard let engine = audioEngine, engine.isRunning else {
            recoverAudioEngineDuringRecording(reason: "engine stopped")
            return
        }

        guard let lastAudioBufferAt else { return }
        if Date().timeIntervalSince(lastAudioBufferAt) > Constants.recordingBufferStallThreshold {
            recoverAudioEngineDuringRecording(reason: "audio tap stalled")
        }
    }

    private func recoverAudioEngineDuringRecording(reason: String) {
        guard isRecording else {
            pendingEngineRefresh = true
            scheduleEngineRefresh()
            return
        }

        let now = Date()
        if let lastEngineRecoveryAt,
           now.timeIntervalSince(lastEngineRecoveryAt) < Constants.engineRecoveryCooldown
        {
            return
        }
        lastEngineRecoveryAt = now

        guard let device = AudioDeviceManager.shared.applyPreferredOrAutomaticDevice() else {
            DebugLog.info("Cannot recover recording engine after \(reason): preferred input device unavailable", context: "AudioRecorder LOG")
            return
        }

        DebugLog.info("Recovering audio engine after \(reason) with input device: \(device.name)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioDeviceEvent("recover_engine_device", device: device)
        SentryTelemetry.recordAudioEngineEvent("recover", reason: reason)
        setupAudioEngine()

        guard let engine = audioEngine else {
            DebugLog.info("❌ Audio engine recovery failed: engine not available", context: "AudioRecorder LOG")
            return
        }

        do {
            try engine.start()
            lastAudioBufferAt = Date()
            DebugLog.info("✅ Audio engine recovered during recording", context: "AudioRecorder LOG")
        } catch {
            DebugLog.info("❌ Failed to recover audio engine during recording: \(error)", context: "AudioRecorder LOG")
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

    func stopRecording() -> URL? {
        DebugLog.info("⚡ stopRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        SentryTelemetry.recordAudioEngineEvent("stop_recording")

        stopRecordingWatchdog()

        // Close audio file
        audioFile = nil

        // Stop the audio engine to release microphone
        if let engine = audioEngine, engine.isRunning {
            engine.stop()
            DebugLog.info("✅ Audio engine stopped", context: "AudioRecorder LOG")
        }

        // Restore system volume
        let shouldMuteAudio = AppDefaults.shared.object(forKey: "muteAudioWhenRecording") as? Bool ?? true
        if shouldMuteAudio {
            volumeManager.restoreVolume()
        }

        // Update UI state synchronously so ContentView can check it immediately
        // Ensure we're on main thread for @Published property updates
        if Thread.isMainThread {
            isRecording = false
            audioLevel = 0.0
            frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        } else {
            DispatchQueue.main.sync {
                self.isRecording = false
                self.audioLevel = 0.0
                self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
            }
        }

        let url = recordingURL
        DebugLog.info("✅ stopRecording completed, recordingURL: \(String(describing: url))", context: "AudioRecorder LOG")

        // Clear recordingURL for next session
        recordingURL = nil

        return url
    }

    deinit {
        DebugLog.info("🗑️ Deinit - cleaning up", context: "AudioRecorder LOG")

        refreshWorkItem?.cancel()
        stopRecordingWatchdog()

        // Remove notification observers
        NotificationCenter.default.removeObserver(self)

        // Stop engine and clean up
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        audioFile = nil

        // Restore volume as a safety measure
        volumeManager.restoreVolume()

        DebugLog.info("✅ Cleanup complete", context: "AudioRecorder LOG")
    }
}
