import Foundation

public enum SharedTranscriptionService {
    private static let diarizationTimeoutSeconds: UInt64 = 75
    private static let llmPostProcessingTimeoutSeconds: UInt64 = 45

    public static func transcribe(
        audioURL: URL,
        dictionaryManager: DictionaryManager = .shared,
        toneStyleManager: ToneStyleManager = .shared,
        shortcutManager: ShortcutManager = .shared,
        outputMode: TranscriptionOutputMode? = nil,
        transcriptionOptions: TranscriptionOptions = .default,
        selectedPreset: ContextRule? = nil
    ) async throws -> String {
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

        let rawTranscript: String
        if transcriptionOptions.diarization {
            do {
                rawTranscript = try await withTimeout(seconds: diarizationTimeoutSeconds) {
                    try await SharedParakeetTranscriptionService.shared.transcribeDiarized(audioURL: audioURL)
                }
            } catch {
                DebugLog.warning("Speaker labels unavailable within time limit - using offline transcript without speaker labels", context: "SharedTranscriptionService")
                rawTranscript = try await transcribeWithoutDiarization(
                    audioURL: audioURL,
                    providerManager: providerManager,
                    prompts: prompts,
                    timedOutDiarization: error is TranscriptionTimeoutError
                )
            }
        } else if providerManager.shouldUseOnDeviceTranscription {
            rawTranscript = try await SharedParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
        } else {
            guard CloudTranscriptionConsent.isGranted else {
                throw error(CloudTranscriptionConsent.requiredErrorMessage)
            }
            rawTranscript = try await transcribeWithCloud(
                audioURL: audioURL,
                providerManager: providerManager,
                prompts: prompts
            )
        }

        let modeResult: String
        do {
            modeResult = try await withTimeout(seconds: llmPostProcessingTimeoutSeconds) {
                try await applyLLMPassIfAvailable(
                    transcript: rawTranscript,
                    outputMode: selectedOutputMode,
                    prompts: prompts
                )
            }
        } catch {
            DebugLog.warning("Mode post-processing unavailable within time limit - using transcript", context: "SharedTranscriptionService")
            modeResult = rawTranscript
        }
        let processedResult = shortcutManager.expandShortcuts(in: modeResult)
        return TranscriptionTextSanitizer.cleanedText(processedResult)
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
            sttPromptComponents.append("Vocabulary: \(dictionaryHints)")
        }

        let shortcutHints = shortcutManager.transcriptionHints
        if !shortcutHints.isEmpty {
            sttPromptComponents.append("Phrases: \(shortcutHints)")
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
            stt: sttPromptComponents.joined(separator: "\n"),
            postProcessing: postProcessingPromptComponents.joined(separator: "\n")
        )
    }

    private static func applyLLMPassIfAvailable(
        transcript: String,
        outputMode: TranscriptionOutputMode,
        prompts: (stt: String, postProcessing: String)
    ) async throws -> String {
        guard outputMode != .dictation || !prompts.postProcessing.isEmpty else {
            return transcript
        }

        guard CloudTranscriptionConsent.isGranted else {
            DebugLog.info("Skipping cloud post-processing because cloud transcription is not allowed", context: "SharedTranscriptionService")
            return transcript
        }

        guard let client = makeLLMClientIfAvailable() else {
            DebugLog.warning("LLM post-processing unavailable - using transcript without mode formatting", context: "SharedTranscriptionService")
            return transcript
        }

        let rules = prompts.postProcessing.isEmpty ? [] : [prompts.postProcessing]
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
        providerManager: TranscriptionProviderManager,
        prompts: (stt: String, postProcessing: String),
        timedOutDiarization: Bool
    ) async throws -> String {
        if !providerManager.shouldUseOnDeviceTranscription {
            return try await transcribeWithCloud(
                audioURL: audioURL,
                providerManager: providerManager,
                prompts: prompts
            )
        }

        guard !timedOutDiarization else {
            throw error("Speaker labels are still preparing. Try again in a moment.")
        }

        return try await SharedParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
    }

    private static func transcribeWithCloud(
        audioURL: URL,
        providerManager: TranscriptionProviderManager,
        prompts: (stt: String, postProcessing: String)
    ) async throws -> String {
        guard CloudTranscriptionConsent.isGranted else {
            throw error(CloudTranscriptionConsent.requiredErrorMessage)
        }

        let provider = providerManager.selectedProvider == .onDevice ? TranscriptionProvider.custom : providerManager.selectedProvider
        let apiKey = KeychainHelper.get(key: provider.apiKeyName) ?? SecretsLoader.transcriptionKey(for: provider)

        guard let apiKey else {
            throw error("API key not configured")
        }

        let config = OpenAIClient.Configuration(
            transcriptionEndpoint: providerManager.effectiveEndpoint.isEmpty ? provider.defaultEndpoint : providerManager.effectiveEndpoint,
            transcriptionModel: providerManager.effectiveModel,
            chatCompletionEndpoint: "",
            chatCompletionModel: "",
            apiKey: apiKey
        )

        let openAIClient = OpenAIClient(config: config)
        return try await openAIClient.transcribe(
            audioURL: audioURL,
            prompt: prompts.stt.isEmpty ? nil : prompts.stt,
            sttPrompt: prompts.stt.isEmpty ? nil : prompts.stt,
            postProcessingPrompt: nil
        )
    }

    private static func makeLLMClientIfAvailable() -> OpenAIClient? {
        if let endpoint = SecretsLoader.aidictationPostProcessingEndpoint(),
           let apiKey = SecretsLoader.aidictationPostProcessingKey()
        {
            return OpenAIClient(config: OpenAIClient.Configuration(
                chatCompletionEndpoint: endpoint,
                chatCompletionModel: "openai/gpt-oss-20b",
                apiKey: apiKey
            ))
        }

        let llmProviderManager = LLMProviderManager()
        let provider = llmProviderManager.selectedProvider
        let apiKey = KeychainHelper.get(key: provider.apiKeyName) ?? SecretsLoader.llmKey(for: provider)
        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        return OpenAIClient(config: OpenAIClient.Configuration(
            chatCompletionEndpoint: llmProviderManager.effectiveEndpoint,
            chatCompletionModel: llmProviderManager.effectiveModel,
            apiKey: apiKey
        ))
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
                Task {
                    do {
                        let result = try await operation()
                        await gate.resume(.success(result), continuation: continuation)
                    } catch {
                        await gate.resume(.failure(error), continuation: continuation)
                    }
                }

                Task {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    await gate.resume(.failure(TranscriptionTimeoutError()), continuation: continuation)
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
    private var didResume = false

    func resume(_ result: Result<T, Error>, continuation: CheckedContinuation<T, Error>) {
        guard !didResume else { return }
        didResume = true

        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    func cancel() {
        didResume = true
    }
}
