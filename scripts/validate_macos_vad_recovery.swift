import AVFoundation
import Foundation

// Minimal production-dependency stubs. This validator compiles the real
// VoiceActivityDetector.swift and exercises its policy/deadline primitives.
final class VADSettingsManager {
    var sensitivityThreshold: Float = 0.3
}

enum DebugLog {
    static func info(_: String, context _: String) {}
    static func warning(_: String, context _: String) {}
}

private actor BlockingAnalysis {
    private var operationContinuation: CheckedContinuation<Bool, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var isReady = false

    func run() async -> Bool {
        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
        return await withCheckedContinuation { continuation in
            operationContinuation = continuation
        }
    }

    func waitUntilReady() async {
        guard !isReady else { return }
        await withCheckedContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func release() {
        operationContinuation?.resume(returning: false)
        operationContinuation = nil
    }
}

@main
struct ValidateMacOSVADRecovery {
    static func main() async throws {
        precondition(!MacVADAnalysisBudget.shouldBypass(
            byteCount: MacVADAnalysisBudget.maximumSourceBytes - 1,
            duration: MacVADAnalysisBudget.maximumDurationSeconds - 0.001
        ))
        precondition(MacVADAnalysisBudget.shouldBypass(
            byteCount: MacVADAnalysisBudget.maximumSourceBytes,
            duration: nil
        ))
        precondition(MacVADAnalysisBudget.shouldBypass(
            byteCount: nil,
            duration: MacVADAnalysisBudget.maximumDurationSeconds
        ))

        let blocker = BlockingAnalysis()
        let clock = ContinuousClock()
        let started = clock.now
        let analysis = Task {
            try await VoiceActivityDetector.runBoundedAnalysis(
                timeoutNanoseconds: 25_000_000
            ) {
                await blocker.run()
            }
        }
        await blocker.waitUntilReady()
        let result = try await analysis.value
        let elapsed = started.duration(to: clock.now)
        precondition(result, "A blocked optional VAD must fail open")
        precondition(elapsed < .seconds(1), "A blocked VAD must return before native work")

        // Resolve the deliberately non-cooperative late callback. The deadline
        // gate must already have fenced it, so it cannot change the returned value.
        await blocker.release()

        let cancelled = Task {
            try await VoiceActivityDetector.runBoundedAnalysis(
                timeoutNanoseconds: 5_000_000_000
            ) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancellation must not fail open as speech")
        } catch is CancellationError {
            // Expected: cancellation belongs to the enclosing attempt.
        }

        print("PASS: macOS VAD is size-bounded, deadline-fenced, fail-open, and cancellation-safe")
    }
}
