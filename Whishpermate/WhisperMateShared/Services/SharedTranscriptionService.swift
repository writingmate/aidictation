import Foundation

public enum SharedTranscriptionService {
    public static func transcribe(
        audioURL: URL,
        dictionaryManager: DictionaryManager = .shared,
        toneStyleManager: ToneStyleManager = .shared,
        shortcutManager: ShortcutManager = .shared
    ) async throws -> String {
        let providerManager = TranscriptionProviderManager()

        let rawResult: String
        if providerManager.shouldUseOnDeviceTranscription {
            rawResult = try await SharedParakeetTranscriptionService.shared.transcribe(audioURL: audioURL)
        } else {
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
            let prompts = buildPrompts(
                dictionaryManager: dictionaryManager,
                toneStyleManager: toneStyleManager,
                shortcutManager: shortcutManager
            )

            rawResult = try await openAIClient.transcribe(
                audioURL: audioURL,
                prompt: prompts.stt.isEmpty ? nil : prompts.stt,
                sttPrompt: prompts.stt.isEmpty ? nil : prompts.stt,
                postProcessingPrompt: prompts.postProcessing.isEmpty ? nil : prompts.postProcessing
            )
        }

        let processedResult = shortcutManager.expandShortcuts(in: rawResult)
        return TranscriptionTextSanitizer.cleanedText(processedResult)
    }

    private static func buildPrompts(
        dictionaryManager: DictionaryManager,
        toneStyleManager: ToneStyleManager,
        shortcutManager: ShortcutManager
    ) -> (stt: String, postProcessing: String) {
        var sttPromptComponents: [String] = []
        var postProcessingPromptComponents: [String] = []

        let dictionaryHints = dictionaryManager.transcriptionHints
        if !dictionaryHints.isEmpty {
            sttPromptComponents.append("Vocabulary: \(dictionaryHints)")
            postProcessingPromptComponents.append("Vocabulary: \(dictionaryHints)")
        }

        let shortcutHints = shortcutManager.transcriptionHints
        if !shortcutHints.isEmpty {
            sttPromptComponents.append("Phrases: \(shortcutHints)")
            postProcessingPromptComponents.append("Phrases: \(shortcutHints)")
        }

        let styleInstructions = toneStyleManager.allInstructions
        if !styleInstructions.isEmpty {
            postProcessingPromptComponents.append(styleInstructions)
        }

        return (
            stt: sttPromptComponents.joined(separator: "\n"),
            postProcessing: postProcessingPromptComponents.joined(separator: "\n")
        )
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "SharedTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
