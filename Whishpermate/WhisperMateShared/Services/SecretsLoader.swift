import Foundation

public enum SecretsLoader {
    private static let secretsDictionary: NSDictionary? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: url)
        else {
            return nil
        }
        return dictionary
    }()

    public static func transcriptionKey(for provider: TranscriptionProvider) -> String? {
        switch provider {
        case .onDevice:
            return nil
        case .groq:
            return sanitizedSecret("GroqTranscriptionKey")
        case .custom:
            return sanitizedSecret("CustomTranscriptionKey")
        case .openai:
            return sanitizedSecret("OpenAITranscriptionKey") ?? sanitizedSecret("OpenAIAPIKey")
        }
    }

    public static func customTranscriptionEndpoint() -> String? {
        return sanitizedSecret("CustomTranscriptionEndpoint")
    }

    public static func customTranscriptionRealtimeEndpoint() -> String? {
        return sanitizedSecret("CustomTranscriptionRealtimeEndpoint")
    }

    public static func customTranscriptionModel() -> String? {
        guard let model = sanitizedSecret("CustomTranscriptionModel") else {
            return nil
        }
        return normalizedCustomTranscriptionModel(model)
    }

    public static func customTranscriptionRealtimeModel() -> String? {
        return sanitizedSecret("CustomTranscriptionRealtimeModel")
    }

    public static func llmKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .groq:
            return sanitizedSecret("GroqLLMKey")
        case .openai, .anthropic, .custom:
            return nil
        }
    }

    public static func aidictationPostProcessingEndpoint() -> String? {
        return sanitizedSecret("AIDictationPostProcessingEndpoint")
    }

    public static func aidictationPostProcessingKey() -> String? {
        return sanitizedSecret("AIDictationPostProcessingKey")
    }

    public static func getValue(for key: String) -> String? {
        return sanitizedSecret(key)
    }

    private static func sanitizedSecret(_ key: String) -> String? {
        guard let value = secretsDictionary?[key] as? String else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let uppercased = trimmed.uppercased()
        if uppercased.hasPrefix("YOUR_") || uppercased.hasPrefix("REPLACE_") || trimmed.contains("api.example.com") {
            return nil
        }

        return trimmed
    }

    private static func normalizedCustomTranscriptionModel(_ model: String) -> String {
        guard let endpoint = customTranscriptionEndpoint(),
              let host = URL(string: endpoint)?.host?.lowercased(),
              host.contains("writingmate") || host.contains("aidictation")
        else {
            return model
        }

        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "gpt-4o-transcribe", "gpt-4o-mini-transcribe":
            return "groq/whisper-large-v3-turbo"
        default:
            return model
        }
    }
}
