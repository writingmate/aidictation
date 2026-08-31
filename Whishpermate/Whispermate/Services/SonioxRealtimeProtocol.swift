import Foundation

enum SonioxRealtimeProtocolError: Error, Equatable {
    case invalidResponse
    case upstream(type: String, message: String)
}

struct SonioxRealtimeTranscriptUpdate: Equatable {
    let transcript: String
    let isFinalizationComplete: Bool
}

enum SonioxRealtimeProtocol {
    static let model = "stt-rt-v5"
    static let sampleRate = 24_000
    static let channelCount = 1
    static let finalizationSilence = Data(
        repeating: 0,
        count: sampleRate * MemoryLayout<Int16>.size / 5
    )

    static func configurationData(
        temporaryAPIKey: String,
        languages: [String],
        keywords: [String],
        prompt: String?
    ) throws -> Data {
        let normalizedLanguages = normalized(languages)
        let normalizedKeywords = normalized(keywords)
        let normalizedPrompt = prompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let context: Context? = {
            let text = normalizedPrompt?.isEmpty == false ? normalizedPrompt : nil
            guard !normalizedKeywords.isEmpty || text != nil else { return nil }
            return Context(
                terms: normalizedKeywords.isEmpty ? nil : normalizedKeywords,
                text: text
            )
        }()

        return try JSONEncoder().encode(Configuration(
            apiKey: temporaryAPIKey,
            model: model,
            audioFormat: "pcm_s16le",
            sampleRate: sampleRate,
            channelCount: channelCount,
            languageHints: normalizedLanguages.isEmpty ? nil : normalizedLanguages,
            enableLanguageIdentification: true,
            context: context
        ))
    }

    static let finalizeMessage = Data(#"{"type":"finalize"}"#.utf8)

    static func decodeResponse(_ data: Data) throws -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SonioxRealtimeProtocolError.invalidResponse
        }
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    struct Response: Decodable {
        let tokens: [Token]
        let finished: Bool
        let errorType: String?
        let errorMessage: String?

        private enum CodingKeys: String, CodingKey {
            case tokens
            case finished
            case errorType = "error_type"
            case errorMessage = "error_message"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tokens = try container.decodeIfPresent([Token].self, forKey: .tokens) ?? []
            finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
            errorType = try container.decodeIfPresent(String.self, forKey: .errorType)
            errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        }
    }

    struct Token: Decodable {
        let text: String
        let isFinal: Bool

        private enum CodingKeys: String, CodingKey {
            case text
            case isFinal = "is_final"
        }
    }

    private struct Configuration: Encodable {
        let apiKey: String
        let model: String
        let audioFormat: String
        let sampleRate: Int
        let channelCount: Int
        let languageHints: [String]?
        let enableLanguageIdentification: Bool
        let context: Context?

        private enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
            case model
            case audioFormat = "audio_format"
            case sampleRate = "sample_rate"
            case channelCount = "num_channels"
            case languageHints = "language_hints"
            case enableLanguageIdentification = "enable_language_identification"
            case context
        }
    }

    private struct Context: Encodable {
        let terms: [String]?
        let text: String?
    }
}

struct SonioxRealtimeTranscriptState {
    private var finalizedText = ""

    mutating func consume(_ data: Data) throws -> SonioxRealtimeTranscriptUpdate? {
        let response = try SonioxRealtimeProtocol.decodeResponse(data)
        if let errorType = response.errorType {
            throw SonioxRealtimeProtocolError.upstream(
                type: errorType,
                message: response.errorMessage ?? "Realtime transcription failed"
            )
        }

        var provisionalText = ""
        var didFinalize = response.finished
        for token in response.tokens {
            if token.text == "<fin>" {
                didFinalize = didFinalize || token.isFinal
            } else if token.isFinal {
                finalizedText += token.text
            } else {
                provisionalText += token.text
            }
        }

        let transcript = finalizedText + provisionalText
        guard !transcript.isEmpty || didFinalize else { return nil }
        return SonioxRealtimeTranscriptUpdate(
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            isFinalizationComplete: didFinalize
        )
    }
}
