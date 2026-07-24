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

private final class SuspensionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation != nil
    }

    func suspend() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
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
    let observerCalls = Counter()
    proof.whenConfirmed {
        observerCalls.increment()
    }
    let missed = await proof.waitUntilConfirmed(
        deadline: Date().addingTimeInterval(0.03)
    )
    try require(!missed, "an unconfirmed writer was accepted as closed")
    proof.confirmClosed()
    proof.confirmClosed()
    let closed = await proof.waitUntilConfirmed(
        deadline: Date().addingTimeInterval(0.03)
    )
    try require(closed, "a confirmed writer close was not retained")
    try require(
        observerCalls.count == 1,
        "late-close observers were not delivered exactly once"
    )
    proof.whenConfirmed {
        observerCalls.increment()
    }
    try require(
        observerCalls.count == 2,
        "an observer registered after close did not receive retained proof"
    )

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

private func testTerminationPersistenceFailureSettlement() throws {
    let failedPersistence = MacTerminationSettlement.evaluate(
        nativeOwnershipReleased: true,
        terminalStatePersisted: false
    )
    try require(
        failedPersistence.shouldSettleToIdle,
        "a storage failure left the UI owned after native closure"
    )
    try require(
        !failedPersistence.shouldAllowTermination,
        "Quit was accepted after terminal state persistence failed"
    )
    try require(
        failedPersistence.warning == MacTerminationSettlement.storageWarning,
        "a storage failure did not produce the plain recovery warning"
    )

    let unresolvedNativeWork = MacTerminationSettlement.evaluate(
        nativeOwnershipReleased: false,
        terminalStatePersisted: true
    )
    try require(
        !unresolvedNativeWork.shouldSettleToIdle
            && !unresolvedNativeWork.shouldAllowTermination,
        "unresolved native work released Quit ownership"
    )

    let complete = MacTerminationSettlement.evaluate(
        nativeOwnershipReleased: true,
        terminalStatePersisted: true
    )
    try require(
        complete.shouldSettleToIdle && complete.shouldAllowTermination,
        "a fully durable native close did not allow Quit"
    )
}

private func testQuitFencesSuspendedAttemptsBeforePersistence() async throws {
    let pendingPreparationID = UUID()
    let currentAttemptID = UUID()
    let retryAttemptID = UUID()
    let freshAttemptID = UUID()
    let gate = SuspensionGate()
    let fence = await MainActor.run { MacProcessingAttemptFence() }

    let lateCallback = Task { @MainActor in
        guard fence.allows(currentAttemptID) else { return false }
        await gate.suspend()
        // This is the post-await production check. A callback that was
        // admitted before Quit must not mutate after the generation is fenced.
        return fence.allows(currentAttemptID)
    }

    while !gate.isWaiting {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    try await MainActor.run {
        // Quit owns all admitted generations before native close or store
        // persistence can suspend.
        fence.abandon(Set([
            pendingPreparationID,
            currentAttemptID,
            retryAttemptID,
        ]))
        let oneShotPersistenceFailure = MacTerminationSettlement.evaluate(
            nativeOwnershipReleased: true,
            terminalStatePersisted: false
        )
        try require(
            oneShotPersistenceFailure.shouldSettleToIdle
                && !oneShotPersistenceFailure.shouldAllowTermination,
            "a one-shot terminal persistence failure did not refuse Quit and release the UI"
        )
        try require(
            !fence.allows(pendingPreparationID)
                && !fence.allows(currentAttemptID)
                && !fence.allows(retryAttemptID),
            "Quit did not fence every admitted processing generation"
        )
        try require(
            fence.allows(freshAttemptID),
            "an abandoned generation blocked a fresh recording attempt"
        )
    }

    gate.resume()
    let lateWasAllowed = await lateCallback.value
    try require(
        !lateWasAllowed,
        "a suspended pre-Quit callback resumed with mutation ownership"
    )
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
    let store = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/Services/MacAudioProcessingStore.swift"
    ), encoding: .utf8)
    let storeProvider = try String(contentsOf: root.appendingPathComponent(
        "Whishpermate/Whispermate/Services/MacAudioProcessingStoreProvider.swift"
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
            && recorder.contains("nativeCloseProofs.filter")
            && recorder.contains(
                "let ownedRecordingIDs = recordingIDs.union(nativeCloseProofs.keys)"
            ),
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
    let callbackStart = recorder.range(of: "private func processCaptureBuffer(")!.lowerBound
    let callbackEnd = recorder.range(
        of: "private func signalPreparationReady(",
        range: callbackStart..<recorder.endIndex
    )!.lowerBound
    let callbackBody = recorder[callbackStart..<callbackEnd]
    let autoreleaseIndex = callbackBody.range(of: "autoreleasepool(invoking:")!.lowerBound
    let finishWriteIndex = callbackBody.range(of: "session.finishWrite(")!.lowerBound
    try require(
        autoreleaseIndex < finishWriteIndex,
        "capture callback can attest close while a callback-local AVAudioFile still exists"
    )
    try require(
        appState.contains("case .confirmed(let nativeCloseAttestation)")
            && appState.contains("nativeCloseAttestation: nativeCloseAttestation")
            && appState.contains("checkpointRecoverablePartial("),
        "same-process promotion does not require exact native-close attestation"
    )
    try require(
        appState.contains("terminationOwnedNativeIDs.formUnion(nativeProofs.keys)"),
        "Quit can forget a writer that outlived its UI attempt"
    )
    try require(
        store.contains("LOCK_EX | LOCK_NB")
            && store.contains("persistenceOperationID")
            && store.contains("if error == .persistenceTimedOut"),
        "journal locking or ambiguous persistence is not bounded and quarantined"
    )
    try require(
        storeProvider.contains("Task.sleep(nanoseconds: 5_500_000_000)")
            && storeProvider.contains("unavailableStore"),
        "initial journal startup can block UI ownership indefinitely"
    )
    let snapshotCaptureIndex = startRecordingBody.range(
        of: "let attemptSnapshot = makeTranscriptionAttemptSnapshot("
    )!.lowerBound
    let firstTaskIndex = startRecordingBody.range(of: "Task {")!.lowerBound
    try require(
        snapshotCaptureIndex < firstTaskIndex,
        "attempt settings are not frozen before the first persistence suspension"
    )
    try require(
        app.contains("applicationShouldTerminate")
            && app.contains("terminationReplyGuard.resolve(token)"),
        "AppKit Quit does not use the one-reply termination guard"
    )
    try require(
        appState.contains("MacTerminationSettlement.evaluate(")
            && appState.contains("guard settlement.shouldSettleToIdle")
            && appState.contains("return settlement.shouldAllowTermination")
            && appState.contains("guard recordTerminalPersisted else { continue }"),
        "Quit persistence failures do not settle safely after native closure"
    )
    let terminationStart = appState.range(of: "func prepareForTermination(")!.lowerBound
    let terminationEnd = appState.range(
        of: "private func waitForTerminationOwnership(",
        range: terminationStart..<appState.endIndex
    )!.lowerBound
    let terminationBody = appState[terminationStart..<terminationEnd]
    let abandonIndex = terminationBody.range(
        of: "processingAttemptFence.abandon(attemptsToAbandon)"
    )!.lowerBound
    let firstSuspensionIndex = terminationBody.range(of: "let closed = await")!.lowerBound
    try require(
        terminationBody.contains("Set(pendingPreparationStoreIDs.values)")
            && terminationBody.contains("attemptsToAbandon.insert(recordingAttemptID)")
            && terminationBody.contains(
                "attemptsToAbandon.formUnion(retranscriptionAttemptIDs.values)"
            )
            && abandonIndex < firstSuspensionIndex,
        "Quit does not fence pending, current, and retry generations before its first await"
    )
    let finalizationStart = appState.range(
        of: "private func handleRecorderFinalizationTerminal("
    )!.lowerBound
    let finalizationEnd = appState.range(
        of: "private func finishRecordingWithoutTranscription(",
        range: finalizationStart..<appState.endIndex
    )!.lowerBound
    let finalizationBody = appState[finalizationStart..<finalizationEnd]
    try require(
        finalizationBody.components(separatedBy: "ownsProcessingAttempt(").count - 1 >= 10,
        "recorder finalization does not recheck ownership after its suspension points"
    )
    try require(
        appState.contains("private let attemptIsCurrent: @MainActor @Sendable () -> Bool")
            && appState.components(
                separatedBy: "try await requireCurrentAttempt()"
            ).count - 1 >= 10,
        "live and retry store callbacks are not fenced around their suspension points"
    )
    let settlementStart = appState.range(
        of: "private func finishTerminationOwnership()"
    )!.lowerBound
    let settlementEnd = appState.range(
        of: "// MARK: - Private Methods",
        range: settlementStart..<appState.endIndex
    )!.lowerBound
    let settlementBody = appState[settlementStart..<settlementEnd]
    let warningIndex = settlementBody.range(
        of: "presentTerminationStorageWarning(warning)"
    )!.lowerBound
    let returnIndex = settlementBody.range(
        of: "return settlement.shouldAllowTermination"
    )!.lowerBound
    try require(
        warningIndex < returnIndex
            && settlementBody.contains("let alert = NSAlert()")
            && settlementBody.contains("alert.informativeText = warning")
            && settlementBody.contains("alert.runModal()"),
        "eventual Quit settlement does not render its storage warning"
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
    let trustedLegacyDeleteCalls = appState.components(
        separatedBy: "MacHistoryAudioDeletion.remove("
    ).count - 1
    try require(
        trustedLegacyDeleteCalls == 2 && !successBody.isEmpty,
        "Delete and Clear do not both use the trusted legacy deletion helper"
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
            try testTerminationPersistenceFailureSettlement()
            try await testQuitFencesSuspendedAttemptsBeforePersistence()
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
