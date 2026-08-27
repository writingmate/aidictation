import Foundation
import FluidAudio

@objc(ParakeetRuntimeBridge)
public final class ParakeetRuntimeBridge: NSObject {
    private var asrManager: AsrManager?
    private var diarizerManager: OfflineDiarizerManager?
    private let audioConverter = AudioConverter()
    private let parakeetSampleRate: Float = 16_000
    private let operationLock = NSLock()
    private var activeOperation: ActiveOperation?
    private var preCancelledAttemptIDs: Set<String> = []
    private var preCancelledAttemptOrder: [String] = []
    private var rawState = "notInitialized"

    private struct ActiveOperation {
        let id: String
        var task: Task<Void, Never>?
        var abandoned = false
        var cleanupRequested = false
    }

    private enum StartDisposition {
        case start
        case alreadyReady
        case cancelled
        case busy
        case notInitialized
    }

    @objc public dynamic var stateRaw: String {
        operationLock.lock()
        let value = rawState
        operationLock.unlock()
        return value
    }

    @objc(currentStateRaw)
    public func currentStateRaw() -> NSString {
        stateRaw as NSString
    }

    @objc(initializeWithCompletion:)
    public func initialize(completion: @escaping (Bool, NSString?) -> Void) {
        initialize(attemptID: UUID().uuidString as NSString, completion: completion)
    }

    @objc(initializeAttempt:completion:)
    public func initialize(attemptID: NSString, completion: @escaping (Bool, NSString?) -> Void) {
        let id = attemptID as String
        switch reserveInitialization(id: id) {
        case .alreadyReady:
            completion(true, nil)
            return
        case .cancelled:
            completion(false, "Offline initialization was cancelled.")
            return
        case .busy:
            completion(false, "Offline mode is finishing another operation. Please retry.")
            return
        case .start:
            break
        case .notInitialized:
            preconditionFailure("Initialization reservation returned an invalid state")
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let downloadedModels = try await AsrModels.downloadAndLoad(version: .v3)
                try Task.checkCancellation()

                updateState("initializing", for: id)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(downloadedModels)
                try Task.checkCancellation()

                finishInitialization(id: id, manager: manager, error: nil, completion: completion)
            } catch {
                finishInitialization(id: id, manager: nil, error: error, completion: completion)
            }
        }
        attach(task: task, to: id)
    }

    @objc(transcribeAudioAtPath:completion:)
    public func transcribeAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        transcribeAudio(
            atPath: path,
            attemptID: UUID().uuidString as NSString,
            completion: completion
        )
    }

    @objc(transcribeAudioAtPath:attemptID:completion:)
    public func transcribeAudio(
        atPath path: NSString,
        attemptID: NSString,
        completion: @escaping (NSString?, NSString?) -> Void
    ) {
        let id = attemptID as String
        let manager: AsrManager
        switch reserveTranscription(id: id) {
        case let .manager(value):
            manager = value
        case .cancelled:
            completion(nil, "Offline transcription was cancelled.")
            return
        case .busy:
            completion(nil, "Offline mode is finishing another operation. Please retry.")
            return
        case .notInitialized:
            completion(nil, "ASR manager not initialized")
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let samples = try audioConverter.resampleAudioFile(path: path as String)
                try Task.checkCancellation()
                var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(samples, decoderState: &decoderState)
                try Task.checkCancellation()

                finishTextOperation(id: id, text: result.text, error: nil, completion: completion)
            } catch {
                finishTextOperation(id: id, text: nil, error: error, completion: completion)
            }
        }
        attach(task: task, to: id)
    }

    @objc(transcribeDiarizedAudioAtPath:completion:)
    public func transcribeDiarizedAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        transcribeDiarizedAudio(
            atPath: path,
            attemptID: UUID().uuidString as NSString,
            completion: completion
        )
    }

    @objc(transcribeDiarizedAudioAtPath:attemptID:completion:)
    public func transcribeDiarizedAudio(
        atPath path: NSString,
        attemptID: NSString,
        completion: @escaping (NSString?, NSString?) -> Void
    ) {
        let id = attemptID as String
        let manager: AsrManager
        switch reserveTranscription(id: id) {
        case let .manager(value):
            manager = value
        case .cancelled:
            completion(nil, "Offline transcription was cancelled.")
            return
        case .busy:
            completion(nil, "Offline mode is finishing another operation. Please retry.")
            return
        case .notInitialized:
            completion(nil, "ASR manager not initialized")
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let diarizer = try await preparedDiarizer(for: id)
                try Task.checkCancellation()
                let audioURL = URL(fileURLWithPath: path as String)
                let diarization = try await diarizer.process(audioURL)
                try Task.checkCancellation()
                let samples = try audioConverter.resampleAudioFile(path: path as String)
                try Task.checkCancellation()
                let transcript = try await transcribeSpeakerTurns(
                    from: diarization.segments,
                    samples: samples,
                    manager: manager
                )
                try Task.checkCancellation()

                finishTextOperation(id: id, text: transcript, error: nil, completion: completion)
            } catch {
                finishTextOperation(id: id, text: nil, error: error, completion: completion)
            }
        }
        attach(task: task, to: id)
    }

    @objc(transcribeMeetingAudioAtPath:completion:)
    public func transcribeMeetingAudio(atPath path: NSString, completion: @escaping (NSString?, NSString?) -> Void) {
        transcribeDiarizedAudio(atPath: path, completion: completion)
    }

    @objc(cancelAttempt:)
    public func cancelAttempt(_ attemptID: NSString) {
        let id = attemptID as String
        let task: Task<Void, Never>?

        operationLock.lock()
        if activeOperation?.id == id {
            activeOperation?.abandoned = true
            task = activeOperation?.task
            rawState = "cancelling"
        } else {
            rememberPreCancellationLocked(id)
            task = nil
        }
        operationLock.unlock()

        task?.cancel()
    }

    @objc(cleanupRuntime)
    public func cleanupRuntime() {
        let task: Task<Void, Never>?
        let manager: AsrManager?

        operationLock.lock()
        if activeOperation != nil {
            activeOperation?.abandoned = true
            activeOperation?.cleanupRequested = true
            task = activeOperation?.task
            manager = nil
            rawState = "cancelling"
        } else {
            task = nil
            manager = asrManager
            asrManager = nil
            diarizerManager = nil
            rawState = "notInitialized"
        }
        operationLock.unlock()

        task?.cancel()

        Task { [manager] in
            await manager?.cleanup()
        }
    }

    @objc(clearModelCache)
    public func clearModelCache() {
        cleanupRuntime()
        DownloadUtils.clearAllModelCaches()
    }

    private enum TranscriptionReservation {
        case manager(AsrManager)
        case cancelled
        case busy
        case notInitialized
    }

    private func reserveInitialization(id: String) -> StartDisposition {
        operationLock.lock()
        defer { operationLock.unlock() }

        if consumePreCancellationLocked(id) {
            return .cancelled
        }
        if activeOperation != nil {
            return .busy
        }
        if asrManager != nil {
            rawState = "ready"
            return .alreadyReady
        }

        activeOperation = ActiveOperation(id: id)
        rawState = "downloading"
        return .start
    }

    private func reserveTranscription(id: String) -> TranscriptionReservation {
        operationLock.lock()
        defer { operationLock.unlock() }

        if consumePreCancellationLocked(id) {
            return .cancelled
        }
        if activeOperation != nil {
            return .busy
        }
        guard let manager = asrManager else {
            return .notInitialized
        }

        activeOperation = ActiveOperation(id: id)
        rawState = "transcribing"
        return .manager(manager)
    }

    private func attach(task: Task<Void, Never>, to id: String) {
        let shouldCancel: Bool
        operationLock.lock()
        if activeOperation?.id == id {
            activeOperation?.task = task
            shouldCancel = activeOperation?.abandoned == true
        } else {
            shouldCancel = true
        }
        operationLock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    private func updateState(_ state: String, for id: String) {
        operationLock.lock()
        if activeOperation?.id == id,
           activeOperation?.abandoned == false,
           activeOperation?.cleanupRequested == false {
            rawState = state
        }
        operationLock.unlock()
    }

    private func finishInitialization(
        id: String,
        manager: AsrManager?,
        error: Error?,
        completion: @escaping (Bool, NSString?) -> Void
    ) {
        let resolution = finishOperation(id: id, manager: manager, succeeded: manager != nil, error: error)
        cleanupManager(resolution.managerToCleanup)
        guard resolution.shouldDeliver else { return }

        if manager != nil {
            completion(true, nil)
        } else {
            completion(false, (error?.localizedDescription ?? "Offline initialization failed.") as NSString)
        }
    }

    private func finishTextOperation(
        id: String,
        text: String?,
        error: Error?,
        completion: @escaping (NSString?, NSString?) -> Void
    ) {
        let resolution = finishOperation(id: id, manager: nil, succeeded: text != nil, error: error)
        cleanupManager(resolution.managerToCleanup)
        guard resolution.shouldDeliver else { return }

        if let text {
            completion(text as NSString, nil)
        } else {
            completion(nil, (error?.localizedDescription ?? "Offline transcription failed.") as NSString)
        }
    }

    private func finishOperation(
        id: String,
        manager: AsrManager?,
        succeeded: Bool,
        error: Error?
    ) -> (shouldDeliver: Bool, managerToCleanup: AsrManager?) {
        operationLock.lock()
        guard let operation = activeOperation, operation.id == id else {
            operationLock.unlock()
            return (false, manager)
        }

        if let manager {
            asrManager = manager
        }
        activeOperation = nil

        let managerToCleanup: AsrManager?
        if operation.cleanupRequested {
            managerToCleanup = asrManager
            asrManager = nil
            diarizerManager = nil
            rawState = "notInitialized"
        } else {
            managerToCleanup = nil
            if succeeded || (error is CancellationError && asrManager != nil) {
                rawState = asrManager == nil ? "notInitialized" : "ready"
            } else {
                rawState = "error:\(error?.localizedDescription ?? "Offline operation failed.")"
            }
        }
        operationLock.unlock()

        return (!operation.abandoned, managerToCleanup)
    }

    private func cleanupManager(_ manager: AsrManager?) {
        guard let manager else { return }
        Task {
            await manager.cleanup()
        }
    }

    private func rememberPreCancellationLocked(_ id: String) {
        guard preCancelledAttemptIDs.insert(id).inserted else { return }
        preCancelledAttemptOrder.append(id)
        if preCancelledAttemptOrder.count > 128 {
            let evicted = preCancelledAttemptOrder.removeFirst()
            preCancelledAttemptIDs.remove(evicted)
        }
    }

    private func consumePreCancellationLocked(_ id: String) -> Bool {
        guard preCancelledAttemptIDs.remove(id) != nil else { return false }
        if let index = preCancelledAttemptOrder.firstIndex(of: id) {
            preCancelledAttemptOrder.remove(at: index)
        }
        return true
    }

    private func preparedDiarizer(for id: String) async throws -> OfflineDiarizerManager {
        if let existing = currentDiarizer() {
            return existing
        }

        try Task.checkCancellation()
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        try Task.checkCancellation()

        return try installPreparedDiarizer(manager, for: id)
    }

    private func currentDiarizer() -> OfflineDiarizerManager? {
        operationLock.lock()
        let manager = diarizerManager
        operationLock.unlock()
        return manager
    }

    private func installPreparedDiarizer(
        _ manager: OfflineDiarizerManager,
        for id: String
    ) throws -> OfflineDiarizerManager {
        operationLock.lock()
        guard activeOperation?.id == id,
              activeOperation?.abandoned == false,
              activeOperation?.cleanupRequested == false
        else {
            operationLock.unlock()
            throw CancellationError()
        }
        if let existing = diarizerManager {
            operationLock.unlock()
            return existing
        }
        diarizerManager = manager
        operationLock.unlock()
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
