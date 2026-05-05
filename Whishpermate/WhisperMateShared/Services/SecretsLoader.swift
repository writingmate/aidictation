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
        case .groq:
            return secretsDictionary?["GroqTranscriptionKey"] as? String
        case .custom:
            return secretsDictionary?["CustomTranscriptionKey"] as? String
        case .openai:
            return nil
        }
    }

    public static func customTranscriptionEndpoint() -> String? {
        return secretsDictionary?["CustomTranscriptionEndpoint"] as? String
    }

    public static func customTranscriptionModel() -> String? {
        guard let model = secretsDictionary?["CustomTranscriptionModel"] as? String else {
            return nil
        }
        return normalizedCustomTranscriptionModel(model)
    }

    public static func llmKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .groq:
            return secretsDictionary?["GroqLLMKey"] as? String
        case .openai, .anthropic, .custom:
            return nil
        }
    }

    public static func aidictationPostProcessingEndpoint() -> String? {
        return secretsDictionary?["AIDictationPostProcessingEndpoint"] as? String
    }

    public static func aidictationPostProcessingKey() -> String? {
        return secretsDictionary?["AIDictationPostProcessingKey"] as? String
    }

    public static func getValue(for key: String) -> String? {
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
        case "gpt-4o-transcribe", "gpt-4o-mini-transcribe":
            return "groq/whisper-large-v3-turbo"
        default:
            return model
        }
    }
}
