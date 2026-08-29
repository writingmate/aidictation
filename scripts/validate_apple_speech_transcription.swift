import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw ValidationFailure.assertion(message)
    }
}

private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
}

@main
private enum AppleSpeechTranscriptionValidator {
    static func main() throws {
        let provider = try source("Whishpermate/Whispermate/Models/APIProvider.swift")
        let appleService = try source("Whishpermate/Whispermate/Services/AppleSpeechTranscriptionService.swift")
        let appState = try source("Whishpermate/Whispermate/Services/AppState.swift")
        let settings = try source("Whishpermate/Whispermate/Views/SettingsView.swift")
        let history = try source("Whishpermate/Whispermate/Views/HistoryMasterDetailView.swift")
        let secrets = try source("Whishpermate/Whispermate/Services/SecretsLoader.swift")
        let parakeet = try source("Whishpermate/Whispermate/Services/ParakeetTranscriptionService.swift")
        let recorder = try source("Whishpermate/Whispermate/Services/AudioRecorder.swift")

        try require(provider.contains("case apple"), "offline picker must include an Apple provider")
        try require(provider.contains("On-device (Apple)"), "Apple option must use the user-facing name")
        try require(provider.contains("static var offlineProviders"), "offline engines must be listed for the existing picker")
        try require(
            provider.contains("[.parakeet, .apple]"),
            "Parakeet must remain an offline option next to Apple"
        )
        try require(provider.contains("selectedOfflineProvider"), "offline engine selection must persist separately")
        try require(
            provider.contains("AppleSpeechTranscriptionService.isAvailable"),
            "provider availability must consult AppleSpeechTranscriptionService"
        )
        try require(
            !provider.contains("Foundation Models") && !provider.contains("FoundationModels"),
            "user-facing provider names must not mention Foundation Models"
        )

        try require(appleService.contains("SpeechAnalyzer"), "Apple service must use SpeechAnalyzer")
        try require(appleService.contains("SpeechTranscriber"), "Apple service must use SpeechTranscriber")
        try require(appleService.contains("AssetInventory"), "locale models must download through AssetInventory")
        try require(
            appleService.contains("#available(macOS 26.0, *)"),
            "Apple speech must be gated to macOS 26"
        )
        try require(
            appleService.contains("SpeechTranscriber.isAvailable"),
            "Apple speech must also require SpeechTranscriber.isAvailable"
        )
        try require(
            appleService.contains("await SpeechTranscriber.supportedLocale(equivalentTo:"),
            "SpeechTranscriber supportedLocale lookups must be awaited"
        )
        try require(
            appleService.contains("DictationTranscriber"),
            "languages without a SpeechTranscriber model must use DictationTranscriber"
        )
        try require(
            appleService.contains("await DictationTranscriber.supportedLocale(equivalentTo:"),
            "DictationTranscriber supportedLocale lookups must be awaited"
        )
        try require(
            appleService.contains("resolveLanes"),
            "multiple selected languages must each get their own Apple speech lane"
        )
        try require(
            appleService.contains("withThrowingTaskGroup"),
            "Apple speech lanes must run in parallel after recording stops"
        )
        try require(
            appleService.contains("mergeLaneTranscripts") && appleService.contains("mergeTimedSegments") && appleService.contains("mergeScriptStretches"),
            "multi-language Apple results must merge by time or script, not pick one winner"
        )
        try require(
            appleService.contains("Skipping Apple speech lane"),
            "unsupported locales must skip that lane instead of failing the others"
        )
        try require(
            appleService.contains("Apple speech doesn't support this language yet"),
            "unsupported locales must surface a plain error instead of English"
        )
        try require(
            !appleService.contains("supported.first ?? preferred"),
            "Apple speech must not substitute an unrelated SpeechTranscriber locale"
        )
        try require(
            appleService.contains("Downloading Apple speech model"),
            "download copy must stay plain-language"
        )
        try require(
            appleService.contains("Couldn't download. Try again."),
            "failed download copy must stay plain-language"
        )
        try require(
            !appleService.contains("prepareCapture"),
            "Apple speech must not add wait-on-record capture retries"
        )

        try require(
            appState.contains("AppleSpeechTranscriptionService.shared.transcribe"),
            "live and history transcription must call the Apple service"
        )
        try require(
            appState.contains("appleSpeechLocaleIdentifier(from: snapshot)"),
            "Apple speech must honor the app language setting"
        )
        try require(
            appState.contains("languageManager.appleSpeechLanguageCodes"),
            "auto-detect must expand to keyboard languages instead of one locale"
        )
        try require(
            appState.contains("effectiveOfflineProvider"),
            "local snapshots must use the selected offline engine"
        )
        try require(
            appState.contains("case .parakeet, .apple:"),
            "Apple must stay on-device and skip realtime streaming"
        )
        try require(
            !appState.contains("mode == .local ? .parakeet : onlineProvider"),
            "local mode must not hardcode Parakeet after Apple is selectable"
        )
        try require(
            appState.contains("applyLLMPassWithFallback"),
            "Apple raw transcripts must still go through cleanup"
        )

        try require(settings.contains("Offline Model"), "settings must keep the existing offline picker")
        try require(settings.contains("appleService"), "settings must observe the Apple speech service")
        try require(
            settings.contains("On-device (Apple)") || settings.contains("provider.displayName"),
            "settings must present the Apple option by its user-facing name"
        )
        try require(
            settings.contains("AppleSpeechTranscriptionService.downloadingMessage"),
            "settings must show the Apple download copy"
        )
        try require(
            !settings.contains("SpeechAnalyzer") && !settings.contains("SpeechTranscriber"),
            "settings must not expose SpeechAnalyzer or SpeechTranscriber names"
        )
        try require(
            !settings.contains("Foundation Models") && !settings.contains("FoundationModels"),
            "settings must not expose Foundation Models"
        )

        try require(
            history.contains("effectiveOfflineProvider"),
            "history offline retry must use the selected offline engine"
        )
        try require(
            secrets.contains("case .parakeet, .apple, .codex:"),
            "Apple transcription must not require an API key"
        )
        try require(
            parakeet.contains("class ParakeetTranscriptionService"),
            "Parakeet must remain in the project"
        )
        try require(
            !recorder.contains("SpeechAnalyzer") && !recorder.contains("SpeechTranscriber"),
            "AudioRecorder device-pin handling must stay untouched"
        )

        print("Apple speech transcription contract: PASS")
    }
}
