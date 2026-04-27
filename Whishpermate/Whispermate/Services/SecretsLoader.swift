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
        case .parakeet:
            return nil // On-device, no API key needed
        case .custom:
            return secretsDictionary?["CustomTranscriptionKey"] as? String
        case .groq, .openai:
            return nil
        }
    }

    static func customTranscriptionEndpoint() -> String? {
        return secretsDictionary?["CustomTranscriptionEndpoint"] as? String
    }

    static func customTranscriptionModel() -> String? {
        return secretsDictionary?["CustomTranscriptionModel"] as? String
    }

    static func aidictationPostProcessingEndpoint() -> String? {
        return secretsDictionary?["AIDictationPostProcessingEndpoint"] as? String
    }

    static func aidictationPostProcessingKey() -> String? {
        return secretsDictionary?["AIDictationPostProcessingKey"] as? String
    }

    static func llmKey(for provider: LLMProvider) -> String? {
        switch provider {
        case .groq, .lfm25, .openai, .anthropic, .custom:
            return nil
        }
    }

    static func getValue(for key: String) -> String? {
        return secretsDictionary?[key] as? String
    }
}
