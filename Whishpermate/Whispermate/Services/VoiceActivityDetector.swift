import AVFoundation
import Foundation

/// A cheap, metadata-only guard that keeps VAD a bounded rejection optimization.
/// Long recordings proceed directly to recognition instead of spending attempt
/// time scanning audio that recognition must read again anyway.
nonisolated struct MacVADAnalysisBudget: Sendable {
    static let maximumSourceBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumDurationSeconds: TimeInterval = 5 * 60

    static func shouldBypass(
        byteCount: Int64?,
        duration: TimeInterval?
    ) -> Bool {
        if let byteCount, byteCount >= maximumSourceBytes {
            return true
        }
        if let duration, duration >= maximumDurationSeconds {
            return true
        }
        return false
    }
}

/// Voice Activity Detection service using Silero VAD CoreML model
/// Analyzes completed audio files to determine if they contain speech
nonisolated final class VoiceActivityDetector {
    private static let shared = VoiceActivityAnalyzer()
    private static let analysisTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    /// Get or create shared analyzer instance
    static func getAnalyzer() -> VoiceActivityAnalyzer {
        shared
    }

    /// Check if an audio file contains speech
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - settings: VAD settings (optional)
    /// - Returns: True if speech detected, false if only silence/noise
    static func hasSpeech(in audioURL: URL, settings: VADSettingsManager? = nil) async throws -> Bool {
        try await hasSpeech(
            in: audioURL,
            threshold: settings?.sensitivityThreshold ?? 0.3
        )
    }

    /// Check a completed audio file using an attempt-local threshold.
    static func hasSpeech(in audioURL: URL, threshold: Float) async throws -> Bool {
        try Task.checkCancellation()
        guard isCoreMLVADSupported else {
            DebugLog.warning(
                "Skipping CoreML VAD on this Mac because the bundled Silero model can crash the CoreML runtime; treating audio as speech",
                context: "VAD"
            )
            return true
        }

        if shouldBypassAnalysis(for: audioURL) {
            DebugLog.info(
                "Skipping speech pre-check for a long recording; continuing with transcription",
                context: "VAD"
            )
            return true
        }

        let analyzer = getAnalyzer()
        let minSpeechRatio: Float = 0.1

        return try await runBoundedAnalysis(
            timeoutNanoseconds: analysisTimeoutNanoseconds
        ) {
            try await analyzer.containsSpeech(
                in: audioURL,
                threshold: threshold,
                minSpeechRatio: minSpeechRatio
            )
        }
    }

    /// Returns speech on analysis failure/timeout because VAD is only allowed to
    /// reject proven silence. Cancellation still belongs to the enclosing attempt.
    static func runBoundedAnalysis(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        do {
            return try await MacVADDeadline.run(
                timeoutNanoseconds: timeoutNanoseconds,
                operation: operation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DebugLog.warning(
                "Speech check unavailable within its time limit; continuing with transcription",
                context: "VAD"
            )
            return true
        }
    }

    private static func shouldBypassAnalysis(for audioURL: URL) -> Bool {
        let byteCount: Int64?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
            byteCount = (attributes[.size] as? NSNumber)?.int64Value
        } catch {
            // Recognition owns format/file errors. A metadata failure must not
            // block the attempt in an optional pre-check.
            return true
        }

        let duration: TimeInterval?
        do {
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            duration = sampleRate > 0
                ? TimeInterval(file.length) / sampleRate
                : nil
        } catch {
            return true
        }

        return MacVADAnalysisBudget.shouldBypass(
            byteCount: byteCount,
            duration: duration
        )
    }

    private static var isCoreMLVADSupported: Bool {
        // Crash reports show the bundled Silero CoreML package can trigger process-level
        // crashes inside Espresso/BNNS on macOS 13 and 14. Swift error handling cannot
        // catch those signals, so fail open before loading the model on affected systems.
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }
}

private actor MacVADDeadlineGate {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var pendingResult: Result<Bool, Error>?
    private var didResolve = false
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        guard !didResolve else {
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
    }

    func install(_ continuation: CheckedContinuation<Bool, Error>) {
        if let pendingResult {
            self.pendingResult = nil
            resume(continuation, with: pendingResult)
            return
        }
        guard !didResolve else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
    }

    func resolve(_ result: Result<Bool, Error>) {
        guard !didResolve else { return }
        didResolve = true
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil

        guard let continuation else {
            pendingResult = result
            return
        }
        self.continuation = nil
        resume(continuation, with: result)
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resume(
        _ continuation: CheckedContinuation<Bool, Error>,
        with result: Result<Bool, Error>
    ) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private nonisolated enum MacVADDeadline {
    static func run(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let gate = MacVADDeadlineGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await gate.install(continuation) }

                let operationTask = Task {
                    do {
                        await gate.resolve(.success(try await operation()))
                    } catch {
                        await gate.resolve(.failure(error))
                    }
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    await gate.resolve(
                        .failure(NSError(
                            domain: "VoiceActivityDetector",
                            code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "Speech analysis timed out"]
                        ))
                    )
                }
                Task {
                    await gate.installTasks(
                        operation: operationTask,
                        timeout: timeoutTask
                    )
                }
            }
        } onCancel: {
            Task { await gate.cancel() }
        }
    }
}
