import Foundation
import FluidAudio

@objc(ParakeetRuntimeBridge)
public final class ParakeetRuntimeBridge: NSObject {
    private var asrManager: AsrManager?
    private var diarizerManager: OfflineDiarizerManager?
    private let audioConverter = AudioConverter()
    private let parakeetSampleRate: Float = 16_000

    @objc public private(set) dynamic var stateRaw: String = "notInitialized"

    @objc(currentStateRaw)
    public func currentStateRaw() -> NSString {
        stateRaw as NSString
    }

    @objc(initializeWithCompletion:)
    public func initialize(completion: @escaping (Bool, NSString?) -> Void) {
        guard stateRaw == "notInitialized" || stateRaw.hasPrefix("error:") else {
            completion(stateRaw == "ready", nil)
            return
        }

        Task {
            do {
                stateRaw = "downloading"
                let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)

                stateRaw = "initializing"
                let manager = AsrManager(config: .default)
                try await manager.loadModels(downloadedModels)

                asrManager = manager
                stateRaw = "ready"
                completion(true, nil)
            } catch {
                let message = error.localizedDescription
                stateRaw = "error:\(message)"
                completion(false, message as NSString)
            }
        }
    }

    @objc(transcribeAudioAtPath:completion:)
    public func transcribeAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        guard let manager = asrManager else {
            completion(nil, "ASR manager not initialized")
            return
        }

        stateRaw = "transcribing"

        Task {
            do {
                let samples = try audioConverter.resampleAudioFile(path: path as String)
                var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(samples, decoderState: &decoderState)

                stateRaw = "ready"
                completion(result.text as NSString, nil)
            } catch {
                let message = error.localizedDescription
                stateRaw = "error:\(message)"
                completion(nil, message as NSString)
            }
        }
    }

    @objc(transcribeDiarizedAudioAtPath:completion:)
    public func transcribeDiarizedAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        guard let manager = asrManager else {
            completion(nil, "ASR manager not initialized")
            return
        }

        stateRaw = "transcribing"

        Task {
            do {
                let diarizer = try await preparedDiarizer()
                let audioURL = URL(fileURLWithPath: path as String)
                let diarization = try await diarizer.process(audioURL)
                let samples = try audioConverter.resampleAudioFile(path: path as String)
                let transcript = try await transcribeSpeakerTurns(
                    from: diarization.segments,
                    samples: samples,
                    manager: manager
                )

                stateRaw = "ready"
                completion(transcript as NSString, nil)
            } catch {
                let message = error.localizedDescription
                stateRaw = "error:\(message)"
                completion(nil, message as NSString)
            }
        }
    }

    @objc(transcribeMeetingAudioAtPath:completion:)
    public func transcribeMeetingAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        transcribeDiarizedAudio(atPath: path, completion: completion)
    }

    @objc(cleanupRuntime)
    public func cleanupRuntime() {
        let manager = asrManager
        asrManager = nil
        stateRaw = "notInitialized"

        Task {
            await manager?.cleanup()
        }
    }

    private func preparedDiarizer() async throws -> OfflineDiarizerManager {
        if let diarizerManager {
            return diarizerManager
        }

        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        diarizerManager = manager
        return manager
    }

    private struct SpeakerTurn {
        let speakerId: String
        var startTimeSeconds: Float
        var endTimeSeconds: Float
    }

    private func transcribeSpeakerTurns(
        from segments: [TimedSpeakerSegment],
        samples: [Float],
        manager: AsrManager
    ) async throws -> String {
        let turns = mergedSpeakerTurns(from: segments)
        guard !turns.isEmpty else {
            return try await transcribeFullAudio(samples, manager: manager)
        }

        var speakerLabels: [String: String] = [:]
        var lines: [String] = []

        for turn in turns {
            let startSample = max(0, Int((turn.startTimeSeconds * parakeetSampleRate).rounded(.down)))
            let endSample = min(samples.count, Int((turn.endTimeSeconds * parakeetSampleRate).rounded(.up)))
            guard endSample > startSample else {
                continue
            }

            let turnSamples = Array(samples[startSample..<endSample])
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(turnSamples, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }

            let speakerLabel = speakerLabels[turn.speakerId] ?? {
                let label = "Speaker \(speakerLabels.count + 1)"
                speakerLabels[turn.speakerId] = label
                return label
            }()

            lines.append("[\(formatTimestamp(turn.startTimeSeconds))-\(formatTimestamp(turn.endTimeSeconds))] \(speakerLabel): \(text)")
        }

        if lines.isEmpty {
            return try await transcribeFullAudio(samples, manager: manager)
        }

        return lines.joined(separator: "\n")
    }

    private func mergedSpeakerTurns(from segments: [TimedSpeakerSegment]) -> [SpeakerTurn] {
        let sortedSegments = segments
            .filter { $0.durationSeconds >= 0.35 }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var turns: [SpeakerTurn] = []
        for segment in sortedSegments {
            if var last = turns.last,
               last.speakerId == segment.speakerId,
               segment.startTimeSeconds - last.endTimeSeconds <= 0.45 {
                last.endTimeSeconds = max(last.endTimeSeconds, segment.endTimeSeconds)
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(
                    speakerId: segment.speakerId,
                    startTimeSeconds: segment.startTimeSeconds,
                    endTimeSeconds: segment.endTimeSeconds
                ))
            }
        }

        return turns
    }

    private func transcribeFullAudio(_ samples: [Float], manager: AsrManager) async throws -> String {
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
