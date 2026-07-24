import Foundation

enum TranscriptionOutputMode {
    case dictation
    case notes
    case meetings
}

struct TranscriptionOptions: Equatable {
    let diarization: Bool
}

enum TranscriptionMode {
    case auto
    case cloud
}

enum TranscriptionProvider {
    case custom
    case openAI
}

enum TranscriptionTransport {
    case batch
    case local
}

enum PostProcessingProvider {
    case aidictation
    case customLLM
}

private struct MutableAttemptSettings {
    var endpoint = "https://before.example/transcribe"
    var model = "before-model"
    var apiKey = "before-key"
    var realtimeEndpoint = "wss://before.example/realtime"
    var realtimeModel = "before-realtime-model"
    var llmEndpoint = "https://before.example/chat"
    var llmModel = "before-llm"
    var llmKey = "before-llm-key"
    var language = "en"
    var vadThreshold: Float = 0.31
    var prompt = ["Before vocabulary"]
    var replacement = "BeforeCanonical"
}

private func capture(_ settings: MutableAttemptSettings) -> MacTranscriptionAttemptSnapshot {
    MacTranscriptionAttemptSnapshot(
        outputMode: .dictation,
        transcriptionOptions: .init(diarization: false),
        mode: .cloud,
        provider: .custom,
        transport: .batch,
        transcriptionEndpoint: settings.endpoint,
        transcriptionModel: settings.model,
        transcriptionAPIKey: settings.apiKey,
        customRealtimeEndpoint: URL(string: settings.realtimeEndpoint),
        customRealtimeModel: settings.realtimeModel,
        // Custom-provider controls historically leave this hidden toggle off.
        // A two-stage raw path must still run core cleanup with this snapshot.
        llmPostProcessingEnabled: false,
        postProcessingProvider: .customLLM,
        llmEndpoint: settings.llmEndpoint,
        llmModel: settings.llmModel,
        llmAPIKey: settings.llmKey,
        aidictationPostProcessingEndpoint: "https://before.example/cleanup",
        aidictationPostProcessingKey: "before-cleanup-key",
        languageCode: settings.language,
        sttHintPrompt: "Before hint",
        cleanupPromptComponents: settings.prompt,
        baseCleanupPromptComponents: settings.prompt,
        contextRules: [
            .init(
                name: "Meetings",
                appBundleIDs: ["com.current"],
                titlePatterns: [],
                instructions: "",
                isEnabled: true,
                diarization: true
            ),
            .init(
                name: "Current formatting",
                appBundleIDs: ["com.current"],
                titlePatterns: [],
                instructions: "Use current formatting",
                isEnabled: true,
                diarization: false
            ),
        ],
        usesContextRules: true,
        appContext: "Before app",
        screenContext: "Before screen",
        vadEnabled: true,
        vadThreshold: settings.vadThreshold,
        networkWasConnected: true,
        replacements: [.init(trigger: "before", replacement: settings.replacement)]
    )
}

@main
struct ValidateMacOSTranscriptionAttemptSnapshot {
    static func main() throws {
        var settings = MutableAttemptSettings()
        let snapshot = capture(settings)

        // Simulate every relevant manager changing after recording starts.
        settings.endpoint = "https://after.example/transcribe"
        settings.model = "after-model"
        settings.apiKey = "after-key"
        settings.realtimeEndpoint = "wss://after.example/realtime"
        settings.realtimeModel = "after-realtime-model"
        settings.llmEndpoint = "https://after.example/chat"
        settings.llmModel = "after-llm"
        settings.llmKey = "after-llm-key"
        settings.language = "fr"
        settings.vadThreshold = 0.99
        settings.prompt.append("After rule")
        settings.replacement = "AfterCanonical"

        precondition(snapshot.transcriptionEndpoint == "https://before.example/transcribe")
        precondition(snapshot.transcriptionModel == "before-model")
        precondition(snapshot.transcriptionAPIKey == "before-key")
        precondition(snapshot.customRealtimeEndpoint?.absoluteString == "wss://before.example/realtime")
        precondition(snapshot.customRealtimeModel == "before-realtime-model")
        precondition(snapshot.llmEndpoint == "https://before.example/chat")
        precondition(snapshot.llmModel == "before-llm")
        precondition(snapshot.llmAPIKey == "before-llm-key")
        precondition(snapshot.languageCode == "en")
        precondition(snapshot.vadThreshold == 0.31)
        precondition(snapshot.cleanupPromptComponents == ["Before vocabulary"])
        precondition(snapshot.applyReplacements(to: "BEFORE value") == "BeforeCanonical value")
        let contextualSnapshot = snapshot.withContext(
            appContext: "Captured app",
            screenContext: "Captured screen"
        )
        precondition(contextualSnapshot.appContext == "Captured app")
        precondition(contextualSnapshot.screenContext == "Captured screen")
        precondition(contextualSnapshot.transcriptionEndpoint == snapshot.transcriptionEndpoint)
        precondition(contextualSnapshot.transcriptionModel == snapshot.transcriptionModel)
        precondition(contextualSnapshot.llmEndpoint == snapshot.llmEndpoint)
        precondition(contextualSnapshot.cleanupPromptComponents == snapshot.cleanupPromptComponents)
        precondition(
            contextualSnapshot.applyReplacements(to: "BEFORE value")
                == snapshot.applyReplacements(to: "BEFORE value"),
            "Adding captured context changed frozen attempt settings"
        )
        let currentContextSnapshot = snapshot.withContext(
            appContext: "Current app",
            screenContext: "Current screen",
            appBundleID: "com.current",
            windowTitle: "Meeting"
        )
        guard case .meetings = currentContextSnapshot.outputMode else {
            preconditionFailure("Frozen current-app rule did not select Meetings mode")
        }
        precondition(currentContextSnapshot.transcriptionOptions.diarization)
        precondition(
            currentContextSnapshot.cleanupPromptComponents
                == ["Before vocabulary", "Use current formatting"],
            "Frozen current-app formatting instructions were not applied exactly once"
        )
        let resolvedTwice = currentContextSnapshot.withContext(
            appContext: "Current app",
            screenContext: "Current screen",
            appBundleID: "com.current",
            windowTitle: "Meeting"
        )
        precondition(
            resolvedTwice.cleanupPromptComponents
                == currentContextSnapshot.cleanupPromptComponents,
            "Resolving captured context twice duplicated frozen instructions"
        )
        let literalDictation = "Keep (round) [square] {curly} <speaker> tagged text verbatim."
        precondition(
            snapshot.applyReplacements(to: literalDictation) == literalDictation,
            "Durable raw text lost literal dictated delimiters or tags"
        )

        let appStatePath = "Whishpermate/Whispermate/Services/AppState.swift"
        let source = try String(contentsOfFile: appStatePath, encoding: .utf8)
        guard let start = source.range(of: "    private func performTranscription("),
              let end = source.range(
                of: "    private func providerPostProcessingPrompt(",
                range: start.upperBound..<source.endIndex
              )
        else {
            preconditionFailure("Could not isolate attempt execution source")
        }
        let attemptSource = String(source[start.lowerBound..<end.lowerBound])
        let forbiddenLiveReads = [
            "dictionaryManager",
            "transcriptionProviderManager",
            "llmProviderManager",
            "languageManager",
            "vadSettingsManager",
            "NetworkMonitor",
            "resolvedTranscriptionApiKey",
            "resolvedLLMApiKey",
            "capturedAppContext",
            "capturedScreenContext",
        ]
        for forbidden in forbiddenLiveReads {
            precondition(
                !attemptSource.contains(forbidden),
                "Running attempt still reads mutable state: \(forbidden)"
            )
        }

        precondition(attemptSource.contains(
            "let mergedCleanup: ((String) async throws -> String)?"
        ))
        precondition(attemptSource.contains("if provider == .custom {\n                mergedCleanup ="))
        precondition(attemptSource.contains("cleanupMergedTranscript: mergedCleanup"))
        precondition(!attemptSource.contains("cleanupMergedTranscript: {"))
        precondition(!attemptSource.contains("guard let customCleanupPrompt else"))
        precondition(
            !attemptSource.contains("TranscriptionOutputFilter.filter"),
            "Durable raw transcript still passes through destructive output filtering"
        )
        precondition(attemptSource.contains(
            "serverPostProcessingEnabledByDefault: provider == .custom"
        ))

        guard let realtimeStart = source.range(
            of: "    private func startRealtimeTranscriptionIfAvailable("
        ),
        let realtimeEnd = source.range(
            of: "    private func customRealtimeSessionEndpoint(",
            range: realtimeStart.upperBound..<source.endIndex
        )
        else {
            preconditionFailure("Could not isolate realtime attempt setup")
        }
        let realtimeSource = String(source[realtimeStart.lowerBound..<realtimeEnd.lowerBound])
        for forbidden in [
            "SecretsLoader",
            "dictionaryManager",
            "transcriptionProviderManager",
            "llmProviderManager",
            "languageManager",
            "vadSettingsManager",
            "NetworkMonitor",
        ] {
            precondition(
                !realtimeSource.contains(forbidden),
                "Realtime attempt still reads mutable state: \(forbidden)"
            )
        }
        precondition(source.contains("if let realtimeResult"))
        precondition(source.contains("try await session.markRawResultReady(raw)"))
        precondition(source.contains("try await session.beginCleanup()"))
        precondition(source.contains("rawText: raw,\n                        client: OpenAIClient(config: .init())"))
        guard let cleanupStart = source.range(of: "    private func applyLLMPass("),
              let cleanupEnd = source.range(
                of: "    private func applyOutputModeFormatting(",
                range: cleanupStart.upperBound..<source.endIndex
              )
        else {
            preconditionFailure("Could not isolate two-stage cleanup")
        }
        let cleanupSource = String(source[cleanupStart.lowerBound..<cleanupEnd.lowerBound])
        precondition(
            !cleanupSource.contains("llmPostProcessingEnabled"),
            "The hidden legacy toggle still bypasses core two-stage cleanup"
        )
        precondition(
            cleanupSource.contains("rules: promptComponents"),
            "Two-stage cleanup lost personal vocabulary, phrases, replacements, or rules"
        )
        let cleanupFailureChecks = source.components(
            separatedBy: "managedCleanupFailed = !cleanup.completed"
        ).count - 1
        precondition(
            cleanupFailureChecks == 2,
            "Delete and Clear must both surface managed-file cleanup failures"
        )
        precondition(source.contains(
            "let finalIsCheckpointed = finalExists && !partialExists"
        ))
        precondition(source.contains(
            "audioURL: finalIsCheckpointed ? finalURL : partialURL"
        ))
        precondition(source.contains(
            "sourceIntegrity: finalIsCheckpointed ? .complete : .unfinalized"
        ))

        print("PASS: macOS attempt settings are immutable and chunk cleanup has one owner")
    }
}
