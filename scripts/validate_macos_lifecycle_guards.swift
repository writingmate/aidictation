import Foundation

private enum ValidationFailure: Error {
    case assertion(String)
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

private final class CompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MacBoundedNativeOperation<Void>.Completion?

    func set(_ completion: @escaping MacBoundedNativeOperation<Void>.Completion) {
        lock.lock()
        stored = completion
        lock.unlock()
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let completion = stored
        lock.unlock()
        completion?(result)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func testStalledNativeExportDeadlineAndLateFence() async throws {
    let completion = CompletionBox()
    let cancellations = Counter()
    let operation = MacBoundedNativeOperation<Void> {
        cancellations.increment()
    }
    let started = Date()
    do {
        _ = try await operation.run(timeoutNanoseconds: 50_000_000) { callback in
            completion.set(callback)
            // Simulate production AVAssetExportSession never calling back.
        }
        throw ValidationFailure.assertion("a stalled native export unexpectedly succeeded")
    } catch MacNativeOperationDeadlineError.timedOut {
        // Expected.
    }
    try require(
        Date().timeIntervalSince(started) < 0.5,
        "a stalled native export did not return at its independent deadline"
    )
    try require(cancellations.count == 1, "the deadline did not request native cancellation")

    // A native framework can complete after ignoring cancellation. The exact
    // production gate must absorb this callback without resuming a second time.
    completion.complete(.success(()))
    try await Task.sleep(nanoseconds: 20_000_000)
    try require(cancellations.count == 1, "a late completion reopened the native operation")
}

private func testNativeCloseProofAndReplyOwnership() async throws {
    let proof = MacNativeRecorderCloseProof()
    let missed = await proof.waitUntilConfirmed(
        deadline: Date().addingTimeInterval(0.03)
    )
    try require(!missed, "an unconfirmed writer was accepted as closed")
    proof.confirmClosed()
    let closed = await proof.waitUntilConfirmed(
        deadline: Date().addingTimeInterval(0.03)
    )
    try require(closed, "a confirmed writer close was not retained")

    try await MainActor.run {
        let guardrail = MacTerminationReplyGuard()
        let first = guardrail.begin()
        try require(first != nil, "the first Quit did not acquire reply ownership")
        try require(
            guardrail.begin() == nil,
            "a repeated Quit acquired a second terminate-later reply"
        )
        try require(
            guardrail.resolve(first!) == true,
            "the owner could not resolve its terminate-later reply"
        )
        try require(
            guardrail.resolve(first!) == false,
            "the same Quit token replied more than once"
        )
    }
}

private func testProductionIntegrationContracts() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appState = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/Services/AppState.swift"
    ), encoding: .utf8)
    let recorder = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/Services/AudioRecorder.swift"
    ), encoding: .utf8)
    let app = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/WhispermateApp.swift"
    ), encoding: .utf8)
    let client = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/Services/OpenAIClient.swift"
    ), encoding: .utf8)

    try require(
        appState.contains("terminationOwnedStoreIDs.formUnion(pendingPreparationStoreIDs.keys)"),
        "Quit ownership does not include store preparation that has not reached AudioRecorder"
    )
    let startRecordingStart = appState.range(of: "func startRecording(")!.lowerBound
    let startRecordingEnd = appState.range(
        of: "private func beginPreparedCapture(",
        range: startRecordingStart..<appState.endIndex
    )!.lowerBound
    let startRecordingBody = appState[startRecordingStart..<startRecordingEnd]
    let retranscribeStart = appState.range(of: "func retranscribe(recording: Recording)")!.lowerBound
    let retranscribeEnd = appState.range(
        of: "private func runRetranscription(",
        range: retranscribeStart..<appState.endIndex
    )!.lowerBound
    let retranscribeBody = appState[retranscribeStart..<retranscribeEnd]
    try require(
        startRecordingBody.contains("!terminationBarrierActive")
            && retranscribeBody.contains("!terminationBarrierActive"),
        "start or retry can run while a refused Quit still owns unresolved work"
    )
    try require(
        recorder.contains("func beginTerminationClose(")
            && recorder.contains("nativeCloseProofs.filter"),
        "AudioRecorder does not retain native writer-close ownership"
    )
    let releaseIndex = recorder.range(of: "audioFile = nil")!.lowerBound
    let proofIndex = recorder.range(
        of: "closeProof.confirmClosed()",
        range: releaseIndex..<recorder.endIndex
    )!.lowerBound
    try require(
        releaseIndex < proofIndex,
        "native close is confirmed before the AVAudioFile writer is released"
    )
    try require(
        app.contains("applicationShouldTerminate")
            && app.contains("terminationReplyGuard.resolve(token)"),
        "AppKit Quit does not use the one-reply termination guard"
    )

    let successStart = appState.range(of: "private func commitTranscriptionSuccess(")!.lowerBound
    let failureStart = appState.range(
        of: "private func finishStoredTranscriptionFailure(",
        range: successStart..<appState.endIndex
    )!.lowerBound
    let successBody = appState[successStart..<failureStart]
    let historyIndex = successBody.range(of: "historyManager.upsertRecording(success)")!.lowerBound
    let claimIndex = successBody.range(of: "markSucceededAndClaimUsage")!.lowerBound
    let sinkIndex = successBody.range(of: "recordWords")!.lowerBound
    try require(
        historyIndex < claimIndex && claimIndex < sinkIndex,
        "usage can be claimed or reported before durable History and terminal store state"
    )
    try require(
        appState.contains("MacHistoryAudioDeletion.remove(")
            && !successBody.isEmpty,
        "decoded legacy History paths do not use the trusted deletion helper"
    )
    try require(
        client.contains("MacBoundedNativeOperation<Void>")
            && client.contains("chunkExportTimeoutNanoseconds")
            && client.contains("workspace.validateCompletedOutput"),
        "the production chunk exporter is not independently bounded and capability-validated"
    )
}

@main
private struct ValidateMacLifecycleGuards {
    static func main() async {
        do {
            try await testStalledNativeExportDeadlineAndLateFence()
            try await testNativeCloseProofAndReplyOwnership()
            try testProductionIntegrationContracts()
            print("PASS: macOS Quit, native deadline, usage, and path guards")
        } catch ValidationFailure.assertion(let message) {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
