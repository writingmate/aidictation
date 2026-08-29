import AVFoundation
import CoreMedia
import Foundation
import Speech
internal import Combine
import WhisperMateShared

/// On-device transcription using Apple speech recognition.
///
/// Uses SpeechAnalyzer with one locale lane per selected language.
/// SpeechTranscriber is used when that engine has a model; otherwise
/// DictationTranscriber is used. Multiple lanes run in parallel after
/// recording stops and are merged so a dictation can contain more than
/// one language. Recording start never waits on this service.
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
        let lanes = try await resolveLanes(localeIdentifier: localeIdentifier)
        for lane in lanes {
            try await installAssets(for: lane, duration: 0)
        }
    }

    @available(macOS 26.0, *)
    private func transcribeFile(_ audioURL: URL, localeIdentifier: String?) async throws -> String {
        let duration = try audioDuration(at: audioURL)
        let lanes = try await resolveLanes(localeIdentifier: localeIdentifier)
        for lane in lanes {
            try await installAssets(for: lane, duration: duration, showDownloadProgress: true)
        }
        await publish(state: .transcribing, isModelDownloaded: true)

        var laneSegments: [[AppleSpeechLaneSegment]] = []
        try await withThrowingTaskGroup(of: [AppleSpeechLaneSegment].self) { group in
            for lane in lanes {
                group.addTask {
                    do {
                        return try await self.transcribeLane(
                            audioURL: audioURL,
                            lane: lane,
                            duration: duration
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        DebugLog.error(
                            "Apple speech lane failed: \(error.localizedDescription)",
                            context: "AppleSpeechTranscriptionService"
                        )
                        return []
                    }
                }
            }
            for try await segments in group {
                if !segments.isEmpty {
                    laneSegments.append(segments)
                }
            }
        }

        let merged = mergeLaneTranscripts(laneSegments)
        return try finishedTranscript(merged)
    }

    @available(macOS 26.0, *)
    private func transcribeLane(
        audioURL: URL,
        lane: AppleSpeechEngine,
        duration: TimeInterval
    ) async throws -> [AppleSpeechLaneSegment] {
        let file = try AVAudioFile(forReading: audioURL)
        switch lane {
        case let .speechTranscriber(locale):
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: [.audioTimeRange]
            )
            return try await analyzeSpeechFile(file, transcriber: transcriber, locale: locale)
        case let .dictationTranscriber(locale):
            let preset: DictationTranscriber.Preset = duration >= 30 ? .longDictation : .shortDictation
            let transcriber = DictationTranscriber(locale: locale, preset: preset)
            return try await analyzeDictationFile(file, transcriber: transcriber, locale: locale)
        }
    }

    @available(macOS 26.0, *)
    private func installAssets(
        for lane: AppleSpeechEngine,
        duration: TimeInterval,
        showDownloadProgress: Bool = false
    ) async throws {
        switch lane {
        case let .speechTranscriber(locale):
            try await installAssetsIfNeeded(
                supporting: SpeechTranscriber(
                    locale: locale,
                    transcriptionOptions: [],
                    reportingOptions: [],
                    attributeOptions: [.audioTimeRange]
                ),
                showDownloadProgress: showDownloadProgress
            )
        case let .dictationTranscriber(locale):
            let preset: DictationTranscriber.Preset = duration >= 30 ? .longDictation : .shortDictation
            try await installAssetsIfNeeded(
                supporting: DictationTranscriber(locale: locale, preset: preset),
                showDownloadProgress: showDownloadProgress
            )
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
    private func analyzeSpeechFile(
        _ file: AVAudioFile,
        transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws -> [AppleSpeechLaneSegment] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectSpeechSegments(from: transcriber, locale: locale)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private func analyzeDictationFile(
        _ file: AVAudioFile,
        transcriber: DictationTranscriber,
        locale: Locale
    ) async throws -> [AppleSpeechLaneSegment] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = collectDictationSegments(from: transcriber, locale: locale)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    @available(macOS 26.0, *)
    private func collectSpeechSegments(
        from transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws -> [AppleSpeechLaneSegment] {
        var segments: [AppleSpeechLaneSegment] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            if let segment = laneSegment(from: result.text, locale: locale) {
                segments.append(segment)
            }
        }
        return segments
    }

    @available(macOS 26.0, *)
    private func collectDictationSegments(
        from transcriber: DictationTranscriber,
        locale: Locale
    ) async throws -> [AppleSpeechLaneSegment] {
        var segments: [AppleSpeechLaneSegment] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            if let segment = laneSegment(from: result.text, locale: locale) {
                segments.append(segment)
            }
        }
        return segments
    }

    @available(macOS 26.0, *)
    private func laneSegment(from text: AttributedString, locale: Locale) -> AppleSpeechLaneSegment? {
        let value = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let times = audioTimeBounds(from: text)
        return AppleSpeechLaneSegment(
            text: value,
            start: times?.start,
            end: times?.end,
            localeIdentifier: locale.identifier
        )
    }

    @available(macOS 26.0, *)
    private func audioTimeBounds(from text: AttributedString) -> (start: TimeInterval, end: TimeInterval)? {
        guard let range = text.audioTimeRange, range.isValid, !range.isEmpty else {
            return nil
        }
        let start = CMTimeGetSeconds(range.start)
        let end = CMTimeGetSeconds(range.end)
        guard start.isFinite, end.isFinite, end >= start else { return nil }
        return (start, end)
    }

    private func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        guard file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func finishedTranscript(_ raw: String) throws -> String {
        let combined = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty else {
            throw runtimeError("No speech was recognized. Your recording was kept.")
        }
        return combined
    }

    private struct AppleSpeechLaneSegment: Sendable {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
        var localeIdentifier: String
    }

    @available(macOS 26.0, *)
    private enum AppleSpeechEngine: Sendable {
        case speechTranscriber(Locale)
        case dictationTranscriber(Locale)

        var resolvedIdentifier: String {
            switch self {
            case let .speechTranscriber(locale), let .dictationTranscriber(locale):
                return locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            }
        }

        var kindName: String {
            switch self {
            case .speechTranscriber: return "speech"
            case .dictationTranscriber: return "dictation"
            }
        }
    }

    private func mergeLaneTranscripts(_ lanes: [[AppleSpeechLaneSegment]]) -> String {
        let nonempty = lanes.filter { !$0.isEmpty }
        if nonempty.isEmpty { return "" }
        if nonempty.count == 1 {
            return nonempty[0].map(\.text).joined(separator: " ")
        }

        let allHaveTimes = nonempty.allSatisfy { lane in
            lane.allSatisfy { $0.start != nil && $0.end != nil }
        }
        if allHaveTimes {
            return mergeTimedSegments(nonempty.flatMap { $0 })
        }
        return mergeScriptStretches(nonempty)
    }

    private func mergeTimedSegments(_ segments: [AppleSpeechLaneSegment]) -> String {
        let sorted = segments.sorted { lhs, rhs in
            (lhs.start ?? 0) < (rhs.start ?? 0)
        }
        var chosen: [AppleSpeechLaneSegment] = []
        for segment in sorted {
            if let last = chosen.last,
               let lastEnd = last.end,
               let start = segment.start,
               start < lastEnd
            {
                if laneScore(segment) > laneScore(last) {
                    chosen[chosen.count - 1] = segment
                }
            } else {
                chosen.append(segment)
            }
        }
        return chosen.map(\.text).joined(separator: " ")
    }

    private func mergeScriptStretches(_ lanes: [[AppleSpeechLaneSegment]]) -> String {
        let sentenceLanes = lanes.map { lane in
            lane.flatMap(splitIntoScriptStretches)
        }
        let maxCount = sentenceLanes.map(\.count).max() ?? 0
        var parts: [String] = []
        for index in 0..<maxCount {
            var best: AppleSpeechLaneSegment?
            var bestScore = -1.0
            for lane in sentenceLanes {
                guard index < lane.count else { continue }
                let score = laneScore(lane[index])
                if score > bestScore {
                    bestScore = score
                    best = lane[index]
                }
            }
            if let text = best?.text, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: " ")
    }

    private func splitIntoScriptStretches(_ segment: AppleSpeechLaneSegment) -> [AppleSpeechLaneSegment] {
        let pieces = segment.text
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if pieces.count <= 1 {
            return [segment]
        }
        return pieces.map { piece in
            AppleSpeechLaneSegment(
                text: piece,
                start: nil,
                end: nil,
                localeIdentifier: segment.localeIdentifier
            )
        }
    }

    private func laneScore(_ segment: AppleSpeechLaneSegment) -> Double {
        scriptPurity(segment.text, expected: expectedScript(for: segment.localeIdentifier))
    }

    private enum LetterScript {
        case latin
        case cyrillic
        case other
    }

    private func expectedScript(for localeIdentifier: String) -> LetterScript {
        let language = localeIdentifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { String($0).lowercased() } ?? ""
        switch language {
        case "ru", "uk", "be", "bg", "sr", "mk", "kk":
            return .cyrillic
        default:
            return .latin
        }
    }

    private func scriptPurity(_ text: String, expected: LetterScript) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0.2 }
        let matching = letters.filter { letterScript($0) == expected }.count
        return Double(matching) / Double(letters.count)
    }

    private func letterScript(_ scalar: Unicode.Scalar) -> LetterScript {
        if (0x0400...0x04FF).contains(scalar.value) || (0x0500...0x052F).contains(scalar.value) {
            return .cyrillic
        }
        if CharacterSet.letters.contains(scalar), scalar.isASCII {
            return .latin
        }
        if (0x00C0...0x024F).contains(scalar.value) {
            return .latin
        }
        return .other
    }

    @available(macOS 26.0, *)
    private func resolveLanes(localeIdentifier: String?) async throws -> [AppleSpeechEngine] {
        var lanes: [AppleSpeechEngine] = []
        var seen = Set<String>()
        for locale in requestedLocales(from: localeIdentifier) {
            let engine: AppleSpeechEngine?
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                engine = .speechTranscriber(match)
            } else if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                engine = .dictationTranscriber(match)
            } else {
                DebugLog.info(
                    "Skipping Apple speech lane for unsupported locale \(locale.identifier)",
                    context: "AppleSpeechTranscriptionService"
                )
                engine = nil
            }
            guard let engine else { continue }
            let key = engine.resolvedIdentifier
            guard seen.insert(key).inserted else { continue }
            DebugLog.info(
                "Using Apple \(engine.kindName) lane for \(locale.identifier)",
                context: "AppleSpeechTranscriptionService"
            )
            lanes.append(engine)
        }
        guard !lanes.isEmpty else {
            throw unsupportedLanguageError()
        }
        return lanes
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
