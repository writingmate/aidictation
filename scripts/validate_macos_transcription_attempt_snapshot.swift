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
    case aidictation
    case custom
    case openAI
    case soniox
}

enum TranscriptionTransport {
    case batch
    case local
    case realtime
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
}

private func capture(
    _ settings: MutableAttemptSettings,
    provider: TranscriptionProvider = .custom,
    transport: TranscriptionTransport = .batch,
    networkWasConnected: Bool = true
) -> MacTranscriptionAttemptSnapshot {
    MacTranscriptionAttemptSnapshot(
        outputMode: .dictation,
        transcriptionOptions: .init(diarization: false),
        mode: .cloud,
        provider: provider,
        transport: transport,
        transcriptionEndpoint: settings.endpoint,
        transcriptionModel: settings.model,
        transcriptionAPIKey: settings.apiKey,
        sonioxFallbackEndpoint: "https://before.example/batch",
        sonioxFallbackAPIKey: "before-fallback-key",
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
        languageCodes: [settings.language],
        transcriptionKeywords: ["Before vocabulary"],
        recordingPrompt: "Before recording context",
        sttHintPrompt: "Before hint",
        cleanupPromptComponents: settings.prompt,
        baseCleanupPromptComponents: settings.prompt,
        shortcutExpansions: [
            .init(trigger: "my calendly", expansion: "https://calendly.com/yourname"),
            .init(trigger: "my email", expansion: "your.email@example.com"),
        ],
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
            .init(
                name: "Compose formatting",
                appBundleIDs: [],
                titlePatterns: ["Compose*"],
                instructions: "Write as a friendly email",
                isEnabled: true,
                diarization: false
            ),
        ],
        usesContextRules: true,
        appContext: "Before app",
        screenContext: "Before screen",
        vadEnabled: true,
        vadThreshold: settings.vadThreshold,
        networkWasConnected: networkWasConnected
    )
}

@main
struct ValidateMacOSTranscriptionAttemptSnapshot {
    static func main() throws {
        var settings = MutableAttemptSettings()
        let snapshot = capture(settings)
        var sonioxSettings = settings
        sonioxSettings.apiKey = "not-needed"
        let realtime = capture(sonioxSettings, provider: .soniox, transport: .realtime)
        let fallback = realtime.batchRoute(provider: .soniox, transport: .realtime)
        precondition(fallback.endpoint == "https://before.example/batch")
        precondition(fallback.model == "soniox/stt-async-v5")
        precondition(fallback.apiKey == "before-fallback-key")
        precondition(fallback.apiKey != realtime.transcriptionAPIKey)
        let aidictation = capture(settings, provider: .aidictation, transport: .realtime)
        let aidictationFallback = aidictation.batchRoute(provider: .aidictation, transport: .realtime)
        precondition(aidictationFallback.endpoint == "https://before.example/batch")
        precondition(aidictationFallback.model == "gpt-transcribe")
        precondition(aidictationFallback.apiKey == aidictation.transcriptionAPIKey)
        var keylessSettings = settings
        keylessSettings.apiKey = "not-needed"
        let keylessRoute = capture(
            keylessSettings,
            provider: .aidictation,
            transport: .realtime
        ).batchRoute(provider: .aidictation, transport: .realtime)
        precondition(keylessRoute.apiKey == "not-needed")
        precondition(realtime.usesShortRealtimeRecovery(isLiveRecording: true))
        precondition(!realtime.usesShortRealtimeRecovery(isLiveRecording: false))
        let offline = capture(
            settings,
            provider: .soniox,
            transport: .realtime,
            networkWasConnected: false
        )
        precondition(!offline.usesShortRealtimeRecovery(isLiveRecording: true))
        let ordinary = snapshot.batchRoute(provider: .custom, transport: .batch)
        precondition(ordinary.endpoint == snapshot.transcriptionEndpoint)
        precondition(ordinary.apiKey == snapshot.transcriptionAPIKey)

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
        precondition(
            !snapshot.cleanupPromptComponents(for: "Discuss my calendars.")
                .joined().contains("calendly.com")
        )
        precondition(
            snapshot.cleanupPromptComponents(for: "Send my Calendly.")
                .joined().contains("calendly.com")
        )
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
        // The output guard must hold dictation to its words unless the user
        // configured rewording rules or a Notes/Meetings transformation.
        precondition(
            snapshot.cleanupExpectation == .faithfulCleanup,
            "Plain dictation cleanup is not held to the dictated words"
        )
        precondition(
            !snapshot.hasContextRuleInstructions,
            "Vocabulary-only reference context was treated as rewording instructions"
        )
        precondition(
            contextualSnapshot.cleanupExpectation == .faithfulCleanup,
            "Captured app and screen context changed the cleanup expectation"
        )
        precondition(
            currentContextSnapshot.hasContextRuleInstructions,
            "A matching context rule's instructions were not recognized"
        )
        precondition(
            currentContextSnapshot.cleanupExpectation == .transformation,
            "Meetings mode did not relax the guard to a transformation"
        )
        let ruleOnlySnapshot = snapshot.withContext(
            appContext: "Mail",
            screenContext: "Current screen",
            appBundleID: "com.other",
            windowTitle: "Compose: Weekly update"
        )
        guard case .dictation = ruleOnlySnapshot.outputMode else {
            preconditionFailure("A formatting-only rule changed the output mode")
        }
        precondition(
            ruleOnlySnapshot.cleanupPromptComponents
                == ["Before vocabulary", "Write as a friendly email"],
            "Title-matched rule instructions were not applied"
        )
        precondition(
            ruleOnlySnapshot.cleanupExpectation == .instructedCleanup,
            "Dictation with a context rule was not treated as instructed cleanup"
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

        precondition(attemptSource.contains("postProcessingPrompt: nil"))
        precondition(attemptSource.contains("postProcessingEnabled: false"))
        precondition(attemptSource.contains("cleanupMergedTranscript: nil"))
        precondition(
            !attemptSource.contains("TranscriptionOutputFilter.filter"),
            "Durable raw transcript still passes through destructive output filtering"
        )
        precondition(attemptSource.contains(
            "serverPostProcessingEnabledByDefault: false"
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
        precondition(
            realtimeSource.contains("WritingmateRealtimeSessionSupport.resolveClientSecretAPIKey")
        )
        precondition(
            realtimeSource.contains("fallbackAPIKey: snapshot.transcriptionAPIKey")
        )
        precondition(!realtimeSource.contains("AuthManager.shared.accessToken()"))
        precondition(source.contains("if let realtimeResult"))
        precondition(!source.contains("usingBatchFallback"))
        precondition(!source.contains("groq/whisper-large-v3-turbo"))
        precondition(source.contains("try await session.checkpoint(realtimeResult)"))
        precondition(source.contains("try await session.markRawResultReady(realtimeResult)"))
        precondition(source.contains("try await session.beginCleanup()"))
        precondition(source.contains("return realtimeResult"))
        precondition(source.contains("snapshot.usesShortRealtimeRecovery(isLiveRecording: isLiveRecording)"))
        precondition(source.contains("rawText: rawResult,"))
        precondition(source.contains("guard let transcriptionApiKey = batchRoute.apiKey,"))
        precondition(!source.contains("transcriptionApiKey != \"not-needed\""))
        precondition(!attemptSource.contains("applyLLMPassWithFallback("))
        guard let recognitionEnd = source.range(of: "            let rawResult = try await withTimeout"),
              let cleanupAfterRecognition = source.range(
                of: "            try await session.beginCleanup()",
                range: recognitionEnd.upperBound..<source.endIndex
              ),
              let cleanupCall = source.range(
                of: "result = try await applyLLMPassWithFallback(",
                range: cleanupAfterRecognition.upperBound..<source.endIndex
              ) else {
            preconditionFailure("Cleanup is not separate from bounded recognition")
        }
        precondition(cleanupAfterRecognition.lowerBound < cleanupCall.lowerBound)
        precondition(
            !source.contains("applyReplacements(to:"),
            "Recognizer text is being transformed before the durable raw checkpoint"
        )
        precondition(source.contains(
            "let durableRaw = text.trimmingCharacters(in: .whitespacesAndNewlines)"
        ))
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
        guard let liveOutputStart = source.range(of: "    private func cleanupWithRawFallback("),
              let liveOutputEnd = source.range(
                of: "    private func applyLLMPass(",
                range: liveOutputStart.upperBound..<source.endIndex
              )
        else {
            preconditionFailure("Could not isolate live cleanup output path")
        }
        let liveOutputSource = String(source[liveOutputStart.lowerBound..<liveOutputEnd.lowerBound])
        precondition(
            liveOutputSource.contains("return transcriptWithoutStandaloneFillers(cleaned)"),
            "Successful LLM cleanup no longer runs the live filler output filter"
        )
        precondition(
            liveOutputSource.contains("return transcriptWithoutStandaloneFillers(rawText)"),
            "Cleanup fallback no longer runs the live filler output filter"
        )
        precondition(
            liveOutputSource.contains("TranscriptionOutputFilter.removeStandaloneFillers(text)"),
            "Live cleanup output path lost removeStandaloneFillers"
        )
        precondition(
            !liveOutputSource.contains("TranscriptionOutputFilter.filter"),
            "Live cleanup output still passes through destructive .filter whitespace collapsing"
        )
        let filterPath = "Whishpermate/Whispermate/Services/TranscriptionOutputFilter.swift"
        let filterSource = try String(contentsOfFile: filterPath, encoding: .utf8)
        guard let fillerStart = filterSource.range(of: "static func removeStandaloneFillers(") else {
            preconditionFailure("Could not isolate removeStandaloneFillers")
        }
        let fillerSource = String(filterSource[fillerStart.lowerBound...])
        precondition(
            !fillerSource.contains(#"\s{2,}"#),
            "removeStandaloneFillers still collapses Foundation \\s, including newlines between bullets"
        )
        precondition(
            fillerSource.contains(#"[ \t]{2,}"#),
            "removeStandaloneFillers no longer collapses leftover spaces and tabs after filler deletion"
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
