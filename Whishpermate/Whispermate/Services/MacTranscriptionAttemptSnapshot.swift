import Foundation
#if canImport(WhisperMateShared)
import WhisperMateShared
#endif

/// Every mutable preference needed by recognition and cleanup, captured before
/// an attempt begins. Running attempts never consult the live manager objects.
nonisolated struct MacTranscriptionAttemptSnapshot: @unchecked Sendable {
    struct Replacement: Sendable {
        let trigger: String
        let replacement: String
    }

    let outputMode: TranscriptionOutputMode
    let transcriptionOptions: TranscriptionOptions
    let mode: TranscriptionMode
    let provider: TranscriptionProvider
    let transport: TranscriptionTransport
    let transcriptionEndpoint: String
    let transcriptionModel: String
    let transcriptionAPIKey: String?
    let customRealtimeEndpoint: URL?
    let customRealtimeModel: String?
    let llmPostProcessingEnabled: Bool
    let postProcessingProvider: PostProcessingProvider
    let llmEndpoint: String
    let llmModel: String
    let llmAPIKey: String?
    let aidictationPostProcessingEndpoint: String?
    let aidictationPostProcessingKey: String?
    let languageCode: String?
    let sttHintPrompt: String
    let cleanupPromptComponents: [String]
    let appContext: String?
    let screenContext: String?
    let vadEnabled: Bool
    let vadThreshold: Float
    let networkWasConnected: Bool
    let replacements: [Replacement]

    func applyReplacements(to text: String) -> String {
        replacements.reduce(text) { result, replacement in
            result.replacingOccurrences(
                of: replacement.trigger,
                with: replacement.replacement,
                options: .caseInsensitive
            )
        }
    }
}
