import AVFoundation
import Accelerate
import Foundation
public import Combine

#if os(iOS)
    import UIKit
#endif

public class AudioRecorder: NSObject, ObservableObject {
    private static let frequencyBandCount = 10
    private static let recordingQueueKey = DispatchSpecificKey<Void>()

    @Published public var isRecording = false
    @Published public var audioLevel: Float = 0.0 // Audio level for visualization (0.0 to 1.0)
    @Published public var frequencyBands: [Float] = Array(repeating: 0.0, count: frequencyBandCount)

    private var audioRecorder: AVAudioRecorder?
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var outputFormat: AVAudioFormat?
    private var recordingURL: URL?
    private var levelTimer: Timer?
    private lazy var frequencyAnalyzer = SharedFrequencyAnalyzer()
    private let recordingQueue = DispatchQueue(label: "com.whispermate.audio-recorder", qos: .userInitiated)
    #if os(iOS)
        private var isAudioSessionConfigured = false
    #endif

    // App Group identifier for sharing data between app and keyboard extension
    public static let appGroupIdentifier = "group.com.whispermate.shared"

    override public init() {
        super.init()
        recordingQueue.setSpecific(key: Self.recordingQueueKey, value: ())
    }

    #if os(iOS)
        @discardableResult
        private func configureAudioSession() -> Bool {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth])
                try session.setActive(true)
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
                try AVAudioSession.sharedInstance().setActive(false)
                isAudioSessionConfigured = false
            } catch {
                DebugLog.info("Failed to deactivate audio session: \(error)", context: "AudioRecorder LOG")
            }
        }
    #endif

    public func startRecording() {
        recordingQueue.async { [weak self] in
            self?.startRecordingOnQueue()
        }
    }

    private func startRecordingOnQueue() {
        DebugLog.info("startRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")

        // Guard against multiple recording sessions
        if audioRecorder != nil || audioEngine != nil || audioFile != nil {
            DebugLog.info("⚠️ Already recording - stopping previous session first", context: "AudioRecorder LOG")
            _ = stopRecordingOnQueue()
        }

        let fileManager = FileManager.default

        #if os(iOS)
            guard configureAudioSession() else {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.audioLevel = 0.0
                    self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
                }
                return
            }
        #endif

        DispatchQueue.main.async {
            self.audioLevel = 0.0
            self.frequencyBands = Array(repeating: 0.0, count: Self.frequencyBandCount)
        }

        // Use App Group container on iOS, temp directory on macOS
        #if os(iOS)
            let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
            if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AudioRecorder.appGroupIdentifier) {
                recordingURL = containerURL.appendingPathComponent(fileName)
            } else {
                #if targetEnvironment(simulator)
                    DebugLog.info("App Group container unavailable, using simulator temporary directory", context: "AudioRecorder LOG")
                    recordingURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
                #else
                    DebugLog.info("Failed to get app group container", context: "AudioRecorder LOG")
                    publishStopped()
                    return
                #endif
            }
        #else
            let tempDirectory = fileManager.temporaryDirectory
            let fileName = "recording_\(Date().timeIntervalSince1970).m4a"
            recordingURL = tempDirectory.appendingPathComponent(fileName)
        #endif

        #if os(iOS) && !targetEnvironment(simulator)
            startEngineRecording()
        #else
            startMeteredRecorderRecording()
        #endif
    }

    #if os(iOS)
        private func startEngineRecording() {
            guard let recordingURL else {
                publishStopped()
                return
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode
            let bus = 0

            do {
                audioFile = try AVAudioFile(
                    forWriting: recordingURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100.0,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )

                outputFormat = audioFile?.processingFormat
                _ = frequencyAnalyzer

                inputNode.installTap(onBus: bus, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
                    guard let self else { return }

                    let bands = self.frequencyAnalyzer.analyze(buffer: buffer)
                    let level = self.calculateAudioLevel(from: buffer)

                    DispatchQueue.main.async {
                        self.frequencyBands = bands
                        self.audioLevel = level
                    }

                    self.write(buffer)
                }

                audioEngine = engine
                try engine.start()

                DispatchQueue.main.async {
                    self.isRecording = true
                }

                DebugLog.info("startRecording success - engine recording started", context: "AudioRecorder LOG")
            } catch {
                inputNode.removeTap(onBus: bus)
                audioEngine?.stop()
                audioEngine = nil
                audioFile = nil
                outputFormat = nil
                publishStopped()
                DebugLog.info("Failed to start engine recording: \(error)", context: "AudioRecorder LOG")
            }
        }

        private func write(_ buffer: AVAudioPCMBuffer) {
            guard let audioFile else { return }

            do {
                guard let outputFormat else {
                    try audioFile.write(from: buffer)
                    return
                }

                let bufferFormat = buffer.format
                if bufferFormat.sampleRate != outputFormat.sampleRate || bufferFormat.channelCount != outputFormat.channelCount,
                   let converter = AVAudioConverter(from: bufferFormat, to: outputFormat)
                {
                    let ratio = outputFormat.sampleRate / bufferFormat.sampleRate
                    guard let convertedBuffer = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                    ) else {
                        return
                    }

                    var error: NSError?
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }

                    if error == nil {
                        try audioFile.write(from: convertedBuffer)
                    }
                } else {
                    try audioFile.write(from: buffer)
                }
            } catch {
                DebugLog.info("Failed to write audio buffer: \(error)", context: "AudioRecorder LOG")
            }
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

    private func startMeteredRecorderRecording() {
        guard let recordingURL else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                DebugLog.info("AVAudioRecorder refused to start recording", context: "AudioRecorder LOG")
                publishStopped()
                return
            }

            audioRecorder = recorder

            startMeteringTimer()

            DispatchQueue.main.async {
                self.isRecording = true
            }

            DebugLog.info("startRecording success - isRecording after: \(isRecording)", context: "AudioRecorder LOG")
        } catch {
            DebugLog.info("Failed to start recording: \(error)", context: "AudioRecorder LOG")
        }
    }

    private func startMeteringTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder else { return }
            recorder.updateMeters()
            let normalizedLevel = self.normalizeAudioLevel(recorder.averagePower(forChannel: 0))

            DispatchQueue.main.async {
                self.audioLevel = normalizedLevel
                self.frequencyBands = Self.fallbackBands(for: normalizedLevel)
            }
        }
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
                guard let self, self.audioEngine?.isRunning == true else { return }
                self.audioEngine?.pause()
                DebugLog.info("Recording paused", context: "AudioRecorder LOG")
            }
        #else
            guard isRecording else { return }
            audioRecorder?.pause()
            levelTimer?.invalidate()
            levelTimer = nil

            DebugLog.info("Recording paused", context: "AudioRecorder LOG")
        #endif
    }

    public func resumeRecording() {
        #if os(iOS)
            recordingQueue.async { [weak self] in
                guard let self, let audioEngine = self.audioEngine else { return }
                guard !audioEngine.isRunning else { return }

                do {
                    try audioEngine.start()
                } catch {
                    DebugLog.info("Failed to resume engine recording: \(error)", context: "AudioRecorder LOG")
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

    private func stopRecordingOnQueue(deactivateAudioSession: Bool = true) -> URL? {
        DebugLog.info("stopRecording called - isRecording before: \(isRecording)", context: "AudioRecorder LOG")
        let completedRecordingURL = recordingURL
        recordingURL = nil

        // Stop timer
        levelTimer?.invalidate()
        levelTimer = nil

        audioRecorder?.stop()
        audioRecorder = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioFile = nil
        outputFormat = nil

        #if os(iOS)
            if deactivateAudioSession {
                deactivateSession()
            }
        #endif

        publishStopped()

        DebugLog.info("stopRecording completed, recordingURL: \(String(describing: completedRecordingURL))", context: "AudioRecorder LOG")
        return completedRecordingURL
    }

    deinit {
        DebugLog.info("🗑️ Deinit - cleaning up", context: "AudioRecorder LOG")

        // Stop and clean up recording
        if audioRecorder?.isRecording == true {
            audioRecorder?.stop()
        }
        levelTimer?.invalidate()
        levelTimer = nil
        audioRecorder = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        audioFile = nil
        outputFormat = nil
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
