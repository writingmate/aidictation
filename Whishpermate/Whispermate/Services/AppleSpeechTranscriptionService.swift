import AVFoundation
import Foundation
import Speech
internal import Combine
import WhisperMateShared

/// On-device transcription using Apple speech recognition.
///
/// Uses SpeechAnalyzer and SpeechTranscriber when the OS and hardware support
/// them. Locale models are installed through AssetInventory. Recording start
/// never waits on this service.
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
        case .ready, .transcribing, .downloading:
            return
        case .notInitialized, .error:
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
                await self.publish(state: .ready, isModelDownloaded: true)
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
        let locale = await resolvedLocale(preferredIdentifier: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    @available(macOS 26.0, *)
    private func transcribeFile(_ audioURL: URL, localeIdentifier: String?) async throws -> String {
        let locale = await resolvedLocale(preferredIdentifier: localeIdentifier)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await publish(state: .downloading, isModelDownloaded: false)
            try await request.downloadAndInstall()
            await publish(state: .transcribing, isModelDownloaded: true)
        }

        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectTranscript(from: transcriber)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private func collectTranscript(from transcriber: SpeechTranscriber) async throws -> String {
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
        let combined = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw runtimeError("No speech was recognized. Your recording was kept.")
        }
        return combined
    }

    @available(macOS 26.0, *)
    private func resolvedLocale(preferredIdentifier: String?) async -> Locale {
        let preferred = preferredLocale(from: preferredIdentifier)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return match
        }
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match
        }
        let supported = await SpeechTranscriber.supportedLocales
        return supported.first ?? preferred
    }

    private func preferredLocale(from identifier: String?) -> Locale {
        if let identifier, !identifier.isEmpty {
            let first = identifier.split(separator: ",").first.map(String.init) ?? identifier
            return Locale(identifier: first)
        }
        return Locale.current
    }

    private func runtimeError(_ message: String) -> NSError {
        NSError(
            domain: "AppleSpeechTranscriptionService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
