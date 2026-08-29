import AVFoundation
import Foundation
import Speech
internal import Combine
import WhisperMateShared

/// On-device transcription using Apple speech recognition.
///
/// Uses SpeechAnalyzer with SpeechTranscriber when that engine supports the
/// requested language. If it does not, uses DictationTranscriber (system
/// dictation) for languages such as Russian. Locale models are installed
/// through AssetInventory. Recording start never waits on this service.
class AppleSpeechTranscriptionService: ObservableObject {
    static let shared = AppleSpeechTranscriptionService()

    enum ServiceState: Equatable {
        case notInitialized
        case downloading
        case ready
        case transcribing
        case error(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    @Published var state: ServiceState = .notInitialized
    @Published var isModelDownloaded = false

    static let downloadingMessage = "Downloading Apple speech model"
    static let downloadFailedMessage = "Couldn't download. Try again."
    static let unavailableMessage = "Apple speech recognition isn’t available on this Mac."
    static let unsupportedLanguageMessage = "Apple speech doesn't support this language yet"

    private enum ErrorCode {
        static let unsupportedLanguage = 2
    }

    static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    private let operationLock = NSLock()
    private var activeTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    func initialize(localeIdentifier: String? = nil) async throws {
        guard Self.isAvailable else {
            await publish(state: .error(Self.unavailableMessage), isModelDownloaded: false)
            throw runtimeError(Self.unavailableMessage)
        }

        switch state {
        case .transcribing, .downloading:
            return
        case .ready, .notInitialized, .error:
            break
        }

        try await performExclusive {
            guard #available(macOS 26.0, *) else {
                throw self.runtimeError(Self.unavailableMessage)
            }
            try Task.checkCancellation()
            await self.publish(state: .downloading, isModelDownloaded: false)
            do {
                try await self.installLocaleAssetsIfNeeded(localeIdentifier: localeIdentifier)
                try Task.checkCancellation()
                await self.publish(state: .ready, isModelDownloaded: true)
                DebugLog.info("Apple speech model ready", context: "AppleSpeechTranscriptionService")
            } catch is CancellationError {
                await self.publish(state: .notInitialized, isModelDownloaded: false)
                throw CancellationError()
            } catch {
                if Self.isUnsupportedLanguageError(error) {
                    await self.publish(state: .error(Self.unsupportedLanguageMessage), isModelDownloaded: false)
                    throw error
                }
                DebugLog.error(
                    "Couldn't download Apple speech model: \(error.localizedDescription)",
                    context: "AppleSpeechTranscriptionService"
                )
                await self.publish(state: .error(Self.downloadFailedMessage), isModelDownloaded: false)
                throw self.runtimeError(Self.downloadFailedMessage)
            }
        }
    }

    func transcribe(audioURL: URL, localeIdentifier: String? = nil) async throws -> String {
        guard Self.isAvailable else {
            await publish(state: .error(Self.unavailableMessage), isModelDownloaded: false)
            throw runtimeError(Self.unavailableMessage)
        }

        return try await performExclusive {
            guard #available(macOS 26.0, *) else {
                throw self.runtimeError(Self.unavailableMessage)
            }
            try Task.checkCancellation()
            if !self.isModelDownloaded {
                await self.publish(state: .downloading, isModelDownloaded: false)
                do {
                    try await self.installLocaleAssetsIfNeeded(localeIdentifier: localeIdentifier)
                } catch is CancellationError {
                    await self.publish(state: .notInitialized, isModelDownloaded: false)
                    throw CancellationError()
                } catch {
                    if Self.isUnsupportedLanguageError(error) {
                        await self.publish(state: .error(Self.unsupportedLanguageMessage), isModelDownloaded: false)
                        throw error
                    }
                    await self.publish(state: .error(Self.downloadFailedMessage), isModelDownloaded: false)
                    throw self.runtimeError(Self.downloadFailedMessage)
                }
            }

            await self.publish(state: .transcribing, isModelDownloaded: true)
            do {
                let text = try await self.transcribeFile(audioURL, localeIdentifier: localeIdentifier)
                await self.publish(state: .ready, isModelDownloaded: true)
                return text
            } catch is CancellationError {
                await self.publish(state: .ready, isModelDownloaded: true)
                throw CancellationError()
            } catch {
                if Self.isUnsupportedLanguageError(error) {
                    await self.publish(state: .error(Self.unsupportedLanguageMessage), isModelDownloaded: false)
                } else {
                    await self.publish(state: .ready, isModelDownloaded: true)
                }
                throw error
            }
        }
    }

    @MainActor
    func cleanup() {
        operationLock.lock()
        let task = activeTask
        activeTask = nil
        operationLock.unlock()
        task?.cancel()
        state = .notInitialized
        isModelDownloaded = false
    }

    // MARK: - Private Methods

    private func performExclusive<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        while true {
            try Task.checkCancellation()
            operationLock.lock()
            if let existing = activeTask {
                operationLock.unlock()
                _ = try? await existing.value
                continue
            }
            let task = Task { try await operation() }
            activeTask = Task { _ = try? await task.value }
            operationLock.unlock()

            do {
                let value = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                clearActiveTask()
                return value
            } catch {
                clearActiveTask()
                throw error
            }
        }
    }

    private func clearActiveTask() {
        operationLock.lock()
        activeTask = nil
        operationLock.unlock()
    }

    @MainActor
    private func publish(state newState: ServiceState, isModelDownloaded newDownloadState: Bool) {
        state = newState
        isModelDownloaded = newDownloadState
    }

    private func publish(state newState: ServiceState, isModelDownloaded newDownloadState: Bool) async {
        await MainActor.run {
            self.state = newState
            self.isModelDownloaded = newDownloadState
        }
    }

    @available(macOS 26.0, *)
    private func installLocaleAssetsIfNeeded(localeIdentifier: String?) async throws {
        switch try await resolveEngine(localeIdentifier: localeIdentifier) {
        case let .speechTranscriber(locale):
            try await installAssets(
                supporting: SpeechTranscriber(locale: locale, preset: .transcription)
            )
        case let .dictationTranscriber(locale):
            try await installAssets(
                supporting: DictationTranscriber(locale: locale, preset: .longDictation)
            )
        }
    }

    @available(macOS 26.0, *)
    private func transcribeFile(_ audioURL: URL, localeIdentifier: String?) async throws -> String {
        let file = try AVAudioFile(forReading: audioURL)
        let duration = file.fileFormat.sampleRate > 0
            ? Double(file.length) / file.fileFormat.sampleRate
            : 0
        switch try await resolveEngine(localeIdentifier: localeIdentifier) {
        case let .speechTranscriber(locale):
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            try await installAssetsIfNeeded(supporting: transcriber, showDownloadProgress: true)
            return try await analyzeFile(file, transcriber: transcriber)
        case let .dictationTranscriber(locale):
            let preset: DictationTranscriber.Preset = duration >= 30 ? .longDictation : .shortDictation
            let transcriber = DictationTranscriber(locale: locale, preset: preset)
            try await installAssetsIfNeeded(supporting: transcriber, showDownloadProgress: true)
            return try await analyzeFile(file, transcriber: transcriber)
        }
    }

    @available(macOS 26.0, *)
    private func installAssetsIfNeeded(
        supporting transcriber: SpeechTranscriber,
        showDownloadProgress: Bool
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        if showDownloadProgress {
            await publish(state: .downloading, isModelDownloaded: false)
        }
        try await request.downloadAndInstall()
        if showDownloadProgress {
            await publish(state: .transcribing, isModelDownloaded: true)
        }
    }

    @available(macOS 26.0, *)
    private func installAssetsIfNeeded(
        supporting transcriber: DictationTranscriber,
        showDownloadProgress: Bool
    ) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        if showDownloadProgress {
            await publish(state: .downloading, isModelDownloaded: false)
        }
        try await request.downloadAndInstall()
        if showDownloadProgress {
            await publish(state: .transcribing, isModelDownloaded: true)
        }
    }

    @available(macOS 26.0, *)
    private func installAssets(supporting transcriber: SpeechTranscriber) async throws {
        try await installAssetsIfNeeded(supporting: transcriber, showDownloadProgress: false)
    }

    @available(macOS 26.0, *)
    private func installAssets(supporting transcriber: DictationTranscriber) async throws {
        try await installAssetsIfNeeded(supporting: transcriber, showDownloadProgress: false)
    }

    @available(macOS 26.0, *)
    private func analyzeFile(_ file: AVAudioFile, transcriber: SpeechTranscriber) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectSpeechTranscript(from: transcriber)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private func analyzeFile(_ file: AVAudioFile, transcriber: DictationTranscriber) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectDictationTranscript(from: transcriber)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private func collectSpeechTranscript(from transcriber: SpeechTranscriber) async throws -> String {
        var finalized = ""
        var volatile = ""
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = String(result.text.characters)
            if result.isFinal {
                finalized += text
                volatile = ""
            } else {
                volatile = text
            }
        }
        return try finishedTranscript(finalized + volatile)
    }

    @available(macOS 26.0, *)
    private func collectDictationTranscript(from transcriber: DictationTranscriber) async throws -> String {
        var parts: [String] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parts.append(text)
            }
        }
        return try finishedTranscript(parts.joined(separator: " "))
    }

    private func finishedTranscript(_ raw: String) throws -> String {
        let combined = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw runtimeError("No speech was recognized. Your recording was kept.")
        }
        return combined
    }

    @available(macOS 26.0, *)
    private enum AppleSpeechEngine: Sendable {
        case speechTranscriber(Locale)
        case dictationTranscriber(Locale)
    }

    @available(macOS 26.0, *)
    private func resolveEngine(localeIdentifier: String?) async throws -> AppleSpeechEngine {
        for locale in requestedLocales(from: localeIdentifier) {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                DebugLog.info(
                    "Using Apple speech engine for \(locale.identifier)",
                    context: "AppleSpeechTranscriptionService"
                )
                return .speechTranscriber(match)
            }
            if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                DebugLog.info(
                    "Using Apple dictation engine for \(locale.identifier)",
                    context: "AppleSpeechTranscriptionService"
                )
                return .dictationTranscriber(match)
            }
        }
        throw unsupportedLanguageError()
    }

    private func requestedLocales(from identifier: String?) -> [Locale] {
        let parts = (identifier ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return [Locale.current]
        }
        return parts.map { Locale(identifier: $0) }
    }

    private static func isUnsupportedLanguageError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "AppleSpeechTranscriptionService"
            && nsError.code == ErrorCode.unsupportedLanguage
    }

    private func unsupportedLanguageError() -> NSError {
        runtimeError(Self.unsupportedLanguageMessage, code: ErrorCode.unsupportedLanguage)
    }

    private func runtimeError(_ message: String, code: Int = -1) -> NSError {
        NSError(
            domain: "AppleSpeechTranscriptionService",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
