import Foundation
#if canImport(WhisperMateShared)
import WhisperMateShared
#endif

/// Every mutable preference needed by recognition and cleanup, captured before
/// an attempt begins. Running attempts never consult the live manager objects.
nonisolated struct MacTranscriptionAttemptSnapshot: @unchecked Sendable {
    struct ShortcutExpansion: Sendable {
        let trigger: String
        let expansion: String

        func isSupported(in transcript: String) -> Bool {
            let normalizedTrigger = trigger.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizedTrigger.isEmpty else { return false }
            let escaped = NSRegularExpression.escapedPattern(
                for: normalizedTrigger
            )
            guard let regex = try? NSRegularExpression(
                pattern: "(?i)(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
            ) else { return false }
            return regex.firstMatch(
                in: transcript,
                range: NSRange(transcript.startIndex..., in: transcript)
            ) != nil
        }

        var cleanupInstruction: String {
            "Expand the exact spoken shortcut \"\(trigger)\" to \"\(expansion)\"."
        }
    }

    struct ContextRuleSnapshot: Sendable {
        let name: String
        let appBundleIDs: [String]
        let titlePatterns: [String]
        let instructions: String
        let isEnabled: Bool
        let diarization: Bool

        private var normalizedName: String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var isNotesModeRule: Bool { normalizedName == "notes" }
        var isMeetingsModeRule: Bool { normalizedName == "meetings" }

        func matches(appBundleID: String?, windowTitle: String?) -> Bool {
            guard isEnabled else { return false }
            if appBundleIDs.isEmpty && titlePatterns.isEmpty {
                return true
            }
            let appMatches = appBundleID.map(appBundleIDs.contains) ?? false
            let titleMatches = windowTitle.map { title in
                titlePatterns.contains { pattern in
                    Self.matchesTitlePattern(title: title, pattern: pattern)
                }
            } ?? false
            return appMatches || titleMatches
        }

        private static func matchesTitlePattern(
            title: String,
            pattern: String
        ) -> Bool {
            let patternRegex = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "+", with: "\\+")
                .replacingOccurrences(of: "?", with: "\\?")
                .replacingOccurrences(of: "(", with: "\\(")
                .replacingOccurrences(of: ")", with: "\\)")
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
                .replacingOccurrences(of: "{", with: "\\{")
                .replacingOccurrences(of: "}", with: "\\}")
                .replacingOccurrences(of: "^", with: "\\^")
                .replacingOccurrences(of: "$", with: "\\$")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "*", with: ".*")
            guard let regex = try? NSRegularExpression(
                pattern: patternRegex,
                options: [.caseInsensitive]
            ) else { return false }
            return regex.firstMatch(
                in: title,
                range: NSRange(title.startIndex..., in: title)
            ) != nil
        }
    }

    let outputMode: TranscriptionOutputMode
    let transcriptionOptions: TranscriptionOptions
    let mode: TranscriptionMode
    let provider: TranscriptionProvider
    let transport: TranscriptionTransport
    let transcriptionEndpoint: String
    let transcriptionModel: String
    let transcriptionAPIKey: String?
    let sonioxFallbackEndpoint: String
    let sonioxFallbackAPIKey: String?
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
    let languageCodes: [String]
    let transcriptionKeywords: [String]
    let recordingPrompt: String?
    let sttHintPrompt: String
    let cleanupPromptComponents: [String]
    let baseCleanupPromptComponents: [String]
    let shortcutExpansions: [ShortcutExpansion]
    let contextRules: [ContextRuleSnapshot]
    let usesContextRules: Bool
    let appContext: String?
    let screenContext: String?
    let vadEnabled: Bool
    let vadThreshold: Float
    let networkWasConnected: Bool

    struct BatchRoute: Sendable {
        let endpoint: String
        let model: String
        let apiKey: String?
    }

    func batchRoute(
        provider: TranscriptionProvider,
        transport: TranscriptionTransport
    ) -> BatchRoute {
        if provider == .soniox, transport == .realtime {
            return BatchRoute(
                endpoint: sonioxFallbackEndpoint,
                model: "soniox/stt-async-v5",
                apiKey: sonioxFallbackAPIKey
            )
        }
        if provider == .aidictation, transport == .realtime {
            return BatchRoute(
                endpoint: sonioxFallbackEndpoint,
                model: "gpt-transcribe",
                apiKey: transcriptionAPIKey
            )
        }
        return BatchRoute(
            endpoint: transcriptionEndpoint,
            model: transcriptionModel,
            apiKey: transcriptionAPIKey
        )
    }

    func usesShortRealtimeRecovery(isLiveRecording: Bool) -> Bool {
        isLiveRecording && outputMode == .dictation && transport == .realtime
            && networkWasConnected && !transcriptionOptions.diarization
    }

    func withContext(
        appContext: String?,
        screenContext: String?,
        appBundleID: String? = nil,
        windowTitle: String? = nil
    ) -> MacTranscriptionAttemptSnapshot {
        let matchingRules = usesContextRules
            ? contextRules.filter {
                $0.matches(appBundleID: appBundleID, windowTitle: windowTitle)
            }
            : []
        let resolvedOutputMode: TranscriptionOutputMode
        if matchingRules.contains(where: \.isMeetingsModeRule) {
            resolvedOutputMode = .meetings
        } else if matchingRules.contains(where: \.isNotesModeRule) {
            resolvedOutputMode = .notes
        } else {
            resolvedOutputMode = outputMode
        }
        let resolvedOptions = TranscriptionOptions(
            diarization: transcriptionOptions.diarization
                || matchingRules.contains(where: \.diarization)
        )
        let contextInstructions = matchingRules
            .filter { !$0.isNotesModeRule && !$0.isMeetingsModeRule }
            .map(\.instructions)
            .joined(separator: ". ")
        var resolvedCleanupComponents = baseCleanupPromptComponents
        if !contextInstructions.isEmpty {
            resolvedCleanupComponents.append(contextInstructions)
        }
        let resolvedRecordingPrompt = appContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MacTranscriptionAttemptSnapshot(
            outputMode: resolvedOutputMode,
            transcriptionOptions: resolvedOptions,
            mode: mode,
            provider: provider,
            transport: transport,
            transcriptionEndpoint: transcriptionEndpoint,
            transcriptionModel: transcriptionModel,
            transcriptionAPIKey: transcriptionAPIKey,
            sonioxFallbackEndpoint: sonioxFallbackEndpoint,
            sonioxFallbackAPIKey: sonioxFallbackAPIKey,
            customRealtimeEndpoint: customRealtimeEndpoint,
            customRealtimeModel: customRealtimeModel,
            llmPostProcessingEnabled: llmPostProcessingEnabled,
            postProcessingProvider: postProcessingProvider,
            llmEndpoint: llmEndpoint,
            llmModel: llmModel,
            llmAPIKey: llmAPIKey,
            aidictationPostProcessingEndpoint: aidictationPostProcessingEndpoint,
            aidictationPostProcessingKey: aidictationPostProcessingKey,
            languageCode: languageCode,
            languageCodes: languageCodes,
            transcriptionKeywords: transcriptionKeywords,
            recordingPrompt: resolvedRecordingPrompt?.isEmpty == false
                ? resolvedRecordingPrompt
                : recordingPrompt,
            sttHintPrompt: sttHintPrompt,
            cleanupPromptComponents: resolvedCleanupComponents,
            baseCleanupPromptComponents: baseCleanupPromptComponents,
            shortcutExpansions: shortcutExpansions,
            contextRules: contextRules,
            usesContextRules: usesContextRules,
            appContext: appContext,
            screenContext: screenContext,
            vadEnabled: vadEnabled,
            vadThreshold: vadThreshold,
            networkWasConnected: networkWasConnected
        )
    }

    func cleanupPromptComponents(for rawTranscript: String) -> [String] {
        cleanupPromptComponents + shortcutExpansions
            .filter { $0.isSupported(in: rawTranscript) }
            .map(\.cleanupInstruction)
    }

    /// True when a matching context rule appended free-form instructions to
    /// the base vocabulary, phrase, replacement, and expansion context. Such
    /// rules may legitimately reword the dictation, so the output guard
    /// relaxes its divergence checks for them.
    var hasContextRuleInstructions: Bool {
        cleanupPromptComponents.count > baseCleanupPromptComponents.count
    }

    /// How closely the cleanup output must track the raw transcript.
    var cleanupExpectation: TranscriptionCleanupGuard.Expectation {
        if outputMode != .dictation {
            return .transformation
        }
        return hasContextRuleInstructions ? .instructedCleanup : .faithfulCleanup
    }
}
