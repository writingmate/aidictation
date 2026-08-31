import Foundation

public enum SharedTranscriptionService {
    private static let diarizationTimeoutSeconds: UInt64 = 75
    private static let llmPostProcessingTimeoutSeconds: UInt64 = 45

    public struct RequestSnapshot: Sendable {
        fileprivate let useOnDeviceRecognition: Bool
        fileprivate let cloud: CloudRequestConfiguration?
        fileprivate let cleanup: CleanupRequestConfiguration?
        fileprivate let outputMode: TranscriptionOutputMode
        fileprivate let transcriptionOptions: TranscriptionOptions
        fileprivate let sttPrompt: String
        fileprivate let postProcessingPrompt: String
        fileprivate let serverPostProcessingPrompt: String

        public static func capture(
            dictionaryManager: DictionaryManager = .shared,
            toneStyleManager: ToneStyleManager = .shared,
            shortcutManager: ShortcutManager = .shared,
            outputMode: TranscriptionOutputMode? = nil,
            transcriptionOptions: TranscriptionOptions = .default,
            selectedPreset: ContextRule? = nil
        ) throws -> RequestSnapshot {
            let providerManager = TranscriptionProviderManager()
            let selectedOutputMode = outputMode ?? outputModeFor(
                selectedPreset: selectedPreset,
                toneStyleManager: toneStyleManager
            )
            let prompts = buildPrompts(
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager,
                selectedPreset: selectedPreset
            )

            let useOnDevice = providerManager.shouldUseOnDeviceTranscription
            let cloud: CloudRequestConfiguration?
            if useOnDevice {
                cloud = nil
            } else {
                let provider = providerManager.selectedProvider == .onDevice
                    ? TranscriptionProvider.custom
                    : providerManager.selectedProvider
                guard let apiKey = KeychainHelper.get(key: provider.apiKeyName)
                    ?? SecretsLoader.transcriptionKey(for: provider),
                    !apiKey.isEmpty
                else {
                    throw error("API key not configured")
                }
                cloud = CloudRequestConfiguration(
                    endpoint: providerManager.effectiveEndpoint.isEmpty
                        ? provider.defaultEndpoint
                        : providerManager.effectiveEndpoint,
                    model: providerManager.effectiveModel,
                    apiKey: apiKey,
                    isOneStage: provider == .custom
                )
            }

            return RequestSnapshot(
                useOnDeviceRecognition: useOnDevice,
                cloud: cloud,
                cleanup: captureCleanupConfiguration(),
                outputMode: selectedOutputMode,
                transcriptionOptions: transcriptionOptions,
                sttPrompt: prompts.stt,
                postProcessingPrompt: prompts.postProcessing,
                serverPostProcessingPrompt: SharedTranscriptionService.serverPostProcessingPrompt(
                    outputMode: selectedOutputMode,
                    referenceContext: prompts.postProcessing
                )
            )
        }
    }

    fileprivate struct CloudRequestConfiguration: Sendable {
        let endpoint: String
        let model: String
        let apiKey: String
        let isOneStage: Bool
    }

    fileprivate struct CleanupRequestConfiguration: Sendable {
        let endpoint: String
        let model: String
        let apiKey: String
    }

    private struct RecognitionResult: Sendable {
        let rawTranscript: String
        let cleanedTranscript: String?
        let rawCallbacksCompleted: Bool

        init(
            rawTranscript: String,
            cleanedTranscript: String? = nil,
            rawCallbacksCompleted: Bool = false
        ) {
            self.rawTranscript = rawTranscript
            self.cleanedTranscript = cleanedTranscript
            self.rawCallbacksCompleted = rawCallbacksCompleted
        }
    }

    public static func transcribe(
        audioURL: URL,
        dictionaryManager: DictionaryManager = .shared,
        toneStyleManager: ToneStyleManager = .shared,
        shortcutManager: ShortcutManager = .shared,
        outputMode: TranscriptionOutputMode? = nil,
        transcriptionOptions: TranscriptionOptions = .default,
        selectedPreset: ContextRule? = nil,
        chunkWorkspace: MobileAudioProcessingStore.ChunkWorkspace? = nil,
        onRecognitionCheckpoint: @escaping @Sendable (String) async throws -> Void = { _ in },
        onRawTranscript: @escaping @Sendable (String) async throws -> Void = { _ in },
        onCleanupStarted: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> String {
        let request = try RequestSnapshot.capture(
            dictionaryManager: dictionaryManager,
            toneStyleManager: toneStyleManager,
            shortcutManager: shortcutManager,
            outputMode: outputMode,
            transcriptionOptions: transcriptionOptions,
            selectedPreset: selectedPreset
        )
        return try await transcribe(
            audioURL: audioURL,
            request: request,
            chunkWorkspace: chunkWorkspace,
            onRecognitionCheckpoint: onRecognitionCheckpoint,
            onRawTranscript: onRawTranscript,
            onCleanupStarted: onCleanupStarted
        )
    }

    public static func transcribe(
        audioURL: URL,
        request: RequestSnapshot,
        chunkWorkspace: MobileAudioProcessingStore.ChunkWorkspace? = nil,
        onRecognitionCheckpoint: @escaping @Sendable (String) async throws -> Void = { _ in },
        onRawTranscript: @escaping @Sendable (String) async throws -> Void = { _ in },
        onCleanupStarted: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> String {
        let checkpointForwarder = RecognitionCheckpointForwarder(
            callback: onRecognitionCheckpoint
        )

        let recognitionResult: RecognitionResult
        if request.transcriptionOptions.diarization {
            do {
                let transcript = try await withTimeout(seconds: diarizationTimeoutSeconds) {
                    try await SharedParakeetTranscriptionService.shared.transcribeDiarized(audioURL: audioURL)
                }
                recognitionResult = RecognitionResult(rawTranscript: transcript)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.warning("Speaker labels unavailable within time limit - using offline transcript without speaker labels", context: "SharedTranscriptionService")
                recognitionResult = try await transcribeWithoutDiarization(
                    audioURL: audioURL,
                    request: request,
                    timedOutDiarization: error is TranscriptionTimeoutError,
                    chunkWorkspace: chunkWorkspace,
                    checkpointForwarder: checkpointForwarder,
                    onRawTranscript: onRawTranscript,
                    onCleanupStarted: onCleanupStarted
                )
            }
        } else if request.useOnDeviceRecognition {
            recognitionResult = RecognitionResult(
                rawTranscript: try await SharedParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
            )
        } else {
            guard CloudTranscriptionConsent.isGranted else {
                throw error(CloudTranscriptionConsent.requiredErrorMessage)
            }
            recognitionResult = try await transcribeWithCloud(
                audioURL: audioURL,
                request: request,
                chunkWorkspace: chunkWorkspace,
                checkpointForwarder: checkpointForwarder,
                onRawTranscript: onRawTranscript,
                onCleanupStarted: onCleanupStarted
            )
        }

        try Task.checkCancellation()
        let durableRawTranscript = recognitionResult.rawTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !durableRawTranscript.isEmpty else {
            throw error("No speech was recognized. Your recording was kept.")
        }
        if !recognitionResult.rawCallbacksCompleted {
            try await checkpointForwarder.checkpoint(durableRawTranscript)
            try Task.checkCancellation()
            try await onRawTranscript(durableRawTranscript)
            try Task.checkCancellation()
            try await onCleanupStarted()
            try Task.checkCancellation()
        }

        let modeResult: String
        if let cleanedTranscript = recognitionResult.cleanedTranscript {
            modeResult = cleanedTranscript
        } else {
            do {
                modeResult = try await withTimeout(seconds: llmPostProcessingTimeoutSeconds) {
                    try await applyLLMPassIfAvailable(
                        transcript: durableRawTranscript,
                        outputMode: request.outputMode,
                        postProcessingPrompt: request.postProcessingPrompt,
                        cleanupConfiguration: request.cleanup
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.warning("Mode post-processing unavailable within time limit - using transcript", context: "SharedTranscriptionService")
                modeResult = durableRawTranscript
            }
        }
        let nonemptyModeResult = modeResult.trimmingCharacters(in: .whitespacesAndNewlines)
        return nonemptyModeResult.isEmpty ? durableRawTranscript : nonemptyModeResult
    }

    private static func outputModeFor(
        selectedPreset: ContextRule?,
        toneStyleManager: ToneStyleManager
    ) -> TranscriptionOutputMode {
        if selectedPreset?.isMeetingsModeRule == true {
            return .meetings
        }
        if selectedPreset?.isNotesModeRule == true || toneStyleManager.isNotesModeActive() {
            return .notes
        }
        return .dictation
    }

    private static func buildPrompts(
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager,
        selectedPreset: ContextRule?
    ) -> (stt: String, postProcessing: String) {
        var sttPromptComponents: [String] = []
        var postProcessingPromptComponents: [String] = []

        let dictionaryHints = dictionaryManager.transcriptionHints
        if !dictionaryHints.isEmpty {
            sttPromptComponents.append(dictionaryHints)
            postProcessingPromptComponents.append("Vocabulary: \(dictionaryHints)")
        }

        let shortcutHints = shortcutManager.transcriptionHints
        if !shortcutHints.isEmpty {
            sttPromptComponents.append(shortcutHints)
            postProcessingPromptComponents.append("Phrases: \(shortcutHints)")
        }

        if let instructions = dictionaryManager.formattingInstructions {
            postProcessingPromptComponents.append(instructions)
        }

        if let instructions = shortcutManager.formattingInstructions {
            postProcessingPromptComponents.append(instructions)
        }

        if let selectedPreset, !selectedPreset.isNotesModeRule, !selectedPreset.isMeetingsModeRule {
            postProcessingPromptComponents.append("\(selectedPreset.name): \(selectedPreset.instructions)")
        }

        return (
            stt: TranscriptionCleanupPrompt.speechRecognitionPrompt(
                hints: sttPromptComponents
            ),
            postProcessing: postProcessingPromptComponents.joined(separator: "\n")
        )
    }

    private static func serverPostProcessingPrompt(
        outputMode: TranscriptionOutputMode,
        referenceContext: String
    ) -> String {
        let transformationInstruction: String?
        switch outputMode {
        case .dictation:
            transformationInstruction = nil
        case .notes:
            transformationInstruction = TranscriptionOutputMode.notesPostProcessingInstruction
        case .meetings:
            transformationInstruction = TranscriptionOutputMode.meetingsPostProcessingInstruction
        }

        return TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: referenceContext.isEmpty ? [] : [referenceContext],
            languageContext: nil,
            appContext: nil,
            hasSelectedContent: false,
            transformationInstruction: transformationInstruction
        )
    }

    private static func applyLLMPassIfAvailable(
        transcript: String,
        outputMode: TranscriptionOutputMode,
        postProcessingPrompt: String,
        cleanupConfiguration: CleanupRequestConfiguration?
    ) async throws -> String {
        guard CloudTranscriptionConsent.isGranted else {
            DebugLog.info("Skipping cloud post-processing because cloud transcription is not allowed", context: "SharedTranscriptionService")
            return transcript
        }

        guard let cleanupConfiguration else {
            DebugLog.warning("LLM post-processing unavailable - using transcript without mode formatting", context: "SharedTranscriptionService")
            return transcript
        }
        let client = OpenAIClient(config: OpenAIClient.Configuration(
            chatCompletionEndpoint: cleanupConfiguration.endpoint,
            chatCompletionModel: cleanupConfiguration.model,
            apiKey: cleanupConfiguration.apiKey
        ))

        let rules = postProcessingPrompt.isEmpty ? [] : [postProcessingPrompt]
        switch outputMode {
        case .dictation:
            return try await client.applyFormattingRules(transcription: transcript, rules: rules)
        case .notes:
            return try await client.applyNotesFormatting(transcription: transcript, rules: rules)
        case .meetings:
            return try await client.applyMeetingFormatting(transcription: transcript, rules: rules)
        }
    }

    private static func transcribeWithoutDiarization(
        audioURL: URL,
        request: RequestSnapshot,
        timedOutDiarization: Bool,
        chunkWorkspace: MobileAudioProcessingStore.ChunkWorkspace?,
        checkpointForwarder: RecognitionCheckpointForwarder,
        onRawTranscript: @escaping @Sendable (String) async throws -> Void,
        onCleanupStarted: @escaping @Sendable () async throws -> Void
    ) async throws -> RecognitionResult {
        if !request.useOnDeviceRecognition {
            return try await transcribeWithCloud(
                audioURL: audioURL,
                request: request,
                chunkWorkspace: chunkWorkspace,
                checkpointForwarder: checkpointForwarder,
                onRawTranscript: onRawTranscript,
                onCleanupStarted: onCleanupStarted
            )
        }

        guard !timedOutDiarization else {
            throw error("Speaker labels are still preparing. Try again in a moment.")
        }

        return RecognitionResult(
            rawTranscript: try await SharedParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
        )
    }

    private static func transcribeWithCloud(
        audioURL: URL,
        request: RequestSnapshot,
        chunkWorkspace: MobileAudioProcessingStore.ChunkWorkspace?,
        checkpointForwarder: RecognitionCheckpointForwarder,
        onRawTranscript: @escaping @Sendable (String) async throws -> Void,
        onCleanupStarted: @escaping @Sendable () async throws -> Void
    ) async throws -> RecognitionResult {
        guard CloudTranscriptionConsent.isGranted else {
            throw error(CloudTranscriptionConsent.requiredErrorMessage)
        }

        guard let cloud = request.cloud else {
            throw error("API key not configured")
        }

        let config = OpenAIClient.Configuration(
            transcriptionEndpoint: cloud.endpoint,
            transcriptionModel: cloud.model,
            chatCompletionEndpoint: "",
            chatCompletionModel: "",
            apiKey: cloud.apiKey
        )

        let openAIClient = OpenAIClient(config: config)
        let mergedCapture = MergedRawCapture()
        let mergedCleanup: ((String) async throws -> String)?
        if cloud.isOneStage {
            mergedCleanup = nil
        } else {
            mergedCleanup = { mergedRaw in
                try await withTimeout(seconds: llmPostProcessingTimeoutSeconds) {
                    try await applyLLMPassIfAvailable(
                        transcript: mergedRaw,
                        outputMode: request.outputMode,
                        postProcessingPrompt: request.postProcessingPrompt,
                        cleanupConfiguration: request.cleanup
                    )
                }
            }
        }
        let transcript = try await openAIClient.transcribe(
            audioURL: audioURL,
            prompt: request.sttPrompt.isEmpty ? nil : request.sttPrompt,
            sttPrompt: request.sttPrompt.isEmpty ? nil : request.sttPrompt,
            postProcessingPrompt: nil,
            serverPostProcessingEnabledByDefault: false,
            postProcessingEnabled: !cloud.isOneStage,
            chunkWorkspace: chunkWorkspace,
            onChunkCheckpoint: { completedLeafIndex, transcript in
                try await checkpointForwarder.checkpointLeaf(
                    completedLeafIndex: completedLeafIndex,
                    transcript: transcript
                )
            },
            onMergedRawTranscript: { mergedRaw in
                let durableRaw = mergedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !durableRaw.isEmpty else {
                    throw error("No speech was recognized. Your recording was kept.")
                }
                try await checkpointForwarder.checkpoint(durableRaw)
                try Task.checkCancellation()
                try await onRawTranscript(durableRaw)
                try Task.checkCancellation()
                try await onCleanupStarted()
                try Task.checkCancellation()
                await mergedCapture.store(durableRaw)
            },
            cleanupMergedTranscript: mergedCleanup
        )

        if let mergedRaw = await mergedCapture.value() {
            return RecognitionResult(
                rawTranscript: mergedRaw,
                cleanedTranscript: transcript,
                rawCallbacksCompleted: true
            )
        }

        if cloud.isOneStage {
            return RecognitionResult(
                rawTranscript: transcript,
                cleanedTranscript: transcript
            )
        }
        return RecognitionResult(rawTranscript: transcript)
    }

    private static func captureCleanupConfiguration() -> CleanupRequestConfiguration? {
        if let endpoint = SecretsLoader.aidictationPostProcessingEndpoint(),
           let apiKey = SecretsLoader.aidictationPostProcessingKey()
        {
            return CleanupRequestConfiguration(
                endpoint: endpoint,
                model: "openai/gpt-oss-20b",
                apiKey: apiKey
            )
        }

        let llmProviderManager = LLMProviderManager()
        let provider = llmProviderManager.selectedProvider
        let apiKey = KeychainHelper.get(key: provider.apiKeyName) ?? SecretsLoader.llmKey(for: provider)
        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        return CleanupRequestConfiguration(
            endpoint: llmProviderManager.effectiveEndpoint,
            model: llmProviderManager.effectiveModel,
            apiKey: apiKey
        )
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "SharedTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func withTimeout<T>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = TimeoutGate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await gate.install(continuation) }

                let operationTask = Task {
                    do {
                        let result = try await operation()
                        await gate.resolve(.success(result))
                    } catch {
                        await gate.resolve(.failure(error))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    } catch {
                        return
                    }
                    await gate.resolve(.failure(TranscriptionTimeoutError()))
                }

                Task {
                    await gate.installTasks(operation: operationTask, timeout: timeoutTask)
                }
            }
        } onCancel: {
            Task {
                await gate.cancel()
            }
        }
    }
}

private struct TranscriptionTimeoutError: LocalizedError {
    var errorDescription: String? {
        "The operation took too long."
    }
}

private actor TimeoutGate<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var didResolve = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
            return
        }
        guard !didResolve else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        guard !didResolve else {
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
    }

    func resolve(_ result: Result<T, Error>) {
        guard !didResolve else { return }
        didResolve = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil

        guard let continuation else {
            pendingResult = result
            return
        }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }
}

private actor RecognitionCheckpointForwarder {
    private let callback: @Sendable (String) async throws -> Void
    private var lastCheckpoint: String?
    private var completedLeafTranscripts: [String] = []

    init(callback: @escaping @Sendable (String) async throws -> Void) {
        self.callback = callback
    }

    func checkpoint(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastCheckpoint else { return }
        try await callback(trimmed)
        lastCheckpoint = trimmed
    }

    func checkpointLeaf(completedLeafIndex: Int, transcript: String) async throws {
        guard completedLeafIndex == completedLeafTranscripts.count else {
            throw NSError(
                domain: "SharedTranscriptionService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio parts completed out of order. Your recording was kept."]
            )
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "SharedTranscriptionService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "An audio part returned no text. Your recording was kept."]
            )
        }

        let cumulativeTranscript = (completedLeafTranscripts + [trimmed])
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await checkpoint(cumulativeTranscript)
        completedLeafTranscripts.append(trimmed)
    }
}

private actor MergedRawCapture {
    private var rawTranscript: String?

    func store(_ transcript: String) {
        rawTranscript = transcript
    }

    func value() -> String? {
        rawTranscript
    }
}
