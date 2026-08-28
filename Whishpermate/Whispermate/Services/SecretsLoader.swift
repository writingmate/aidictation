import Foundation

enum SecretsLoader {
    private static let secretsDictionary: NSDictionary? = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let dictionary = NSDictionary(contentsOf: url)
        else {
            return nil
        }
        return dictionary
    }()

    static func transcriptionKey(for provider: TranscriptionProvider) -> String? {
        switch provider {
        case .parakeet, .codex:
            return nil // On-device, no API key needed
        case .aidictation:
            return secretsDictionary?["CustomTranscriptionKey"] as? String
        }
    }

    static func customTranscriptionEndpoint() -> String? {
        return secretsDictionary?["CustomTranscriptionEndpoint"] as? String
    }

    static func customTranscriptionRealtimeEndpoint() -> String? {
        return secretsDictionary?["CustomTranscriptionRealtimeEndpoint"] as? String
    }

    static func customTranscriptionModel() -> String? {
        guard let model = secretsDictionary?["CustomTranscriptionModel"] as? String else {
            return nil
        }
        return normalizedCustomTranscriptionModel(model)
    }

    static func customTranscriptionRealtimeModel() -> String? {
        guard let model = secretsDictionary?["CustomTranscriptionRealtimeModel"] as? String else {
            return nil
        }
        return normalizedCustomTranscriptionRealtimeModel(model)
    }

    static func aidictationPostProcessingEndpoint() -> String? {
        return secretsDictionary?["AIDictationPostProcessingEndpoint"] as? String
    }

    static func aidictationPostProcessingKey() -> String? {
        return secretsDictionary?["AIDictationPostProcessingKey"] as? String
    }

    static func llmKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .groq:
            return secretsDictionary?["GroqLLMKey"] as? String
        case .lfm25, .openai, .anthropic, .custom:
            return nil
        }
    }

    static func getValue(for key: String) -> String? {
        return secretsDictionary?[key] as? String
    }

    private static func normalizedCustomTranscriptionModel(_ model: String) -> String {
        guard let endpoint = customTranscriptionEndpoint(),
              let host = URL(string: endpoint)?.host?.lowercased(),
              host.contains("writingmate") || host.contains("aidictation")
        else {
            return model
        }

        switch model.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "gpt-4o-transcribe", "gpt-4o-mini-transcribe",
             "groq/whisper-large-v3-turbo", "openai/whisper-large-v3-turbo":
            return "openai/gpt-transcribe"
        default:
            return model
        }
    }

    private static func normalizedCustomTranscriptionRealtimeModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = customTranscriptionRealtimeEndpoint() ?? customTranscriptionEndpoint()
        guard let host = endpoint.flatMap({ URL(string: $0)?.host?.lowercased() }),
              host.contains("writingmate") || host.contains("aidictation")
        else {
            return trimmed
        }
        return "gpt-live-transcribe"
    }
}
