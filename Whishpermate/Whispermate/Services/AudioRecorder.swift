import AVFoundation
import Foundation
import WhisperMateShared
internal import Combine

class AudioRecorder: NSObject, ObservableObject {
    // Shared instance to prevent multiple instances when view is recreated
    static let shared = AudioRecorder()
    private static let frequencyBandCount = 10

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

        // Only pre-initialize the audio engine if microphone permission is already granted
        // This prevents triggering the permission dialog on app launch
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            AudioDeviceManager.shared.applyPreferredOrAutomaticDevice()
            setupAudioEngine()
        }
    }

    @objc private func handleAudioDeviceChanged(_: Notification) {
        DebugLog.info("Audio input device changed", context: "AudioRecorder LOG")
        // Don't restart if currently recording - let the current recording finish
        // Only reinitialize the engine when not recording
        if !isRecording {
            pendingEngineRefresh = true
            scheduleEngineRefresh()
        } else {
            DebugLog.info("Currently recording - will use new device on next recording", context: "AudioRecorder LOG")
        }
    }

    private func scheduleEngineRefresh() {
        refreshWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard self.pendingEngineRefresh, !self.isRecording else { return }

            DebugLog.info("Reinitializing engine with new device", context: "AudioRecorder LOG")
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
            self.retiredEngines.removeAll { $0 === engine }
        }
    }

    private func setupAudioEngine() {
        DebugLog.info("🎙️ Setting up audio engine (persistent mode)", context: "AudioRecorder LOG")

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

            guard let inputFormat = inputFormat, let outputFormat = outputFormat else {
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

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            DebugLog.info("❌ Microphone permission is not authorized", context: "AudioRecorder LOG")
            return
        }

        AudioDeviceManager.shared.applyPreferredOrAutomaticDevice()

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

        guard let outputFormat = outputFormat else {
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
            } else {
                DispatchQueue.main.sync {
                    self.isRecording = true
                }
            }

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

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0, to: Int(buffer.frameLength), by: buffer.stride).map { channelDataValue[$0] }

        // Calculate RMS (Root Mean Square)
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

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
