import Foundation

// A live dictation records its durable success in a task that AppState spawns
// on the main actor and that runs only after the same synchronous code has
// released recording ownership. These checks reproduce that ordering with a
// minimal owner, session, and store, then check that AppState uses the
// release-safe path.

private enum CheckError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.failed(message) }
}

private actor FakeStore {
    private(set) var succeededCount = 0
    private(set) var claimedCount = 0

    func markSucceeded() { succeededCount += 1 }
    func claimPendingUsage() { claimedCount += 1 }
}

/// Mirrors `MacStoreTranscriptionSession.markSucceededAndClaimUsage`.
private actor FakeSession {
    private let store: FakeStore
    private let attemptIsCurrent: @MainActor @Sendable () -> Bool
    private let attemptMayFinalizeAfterRelease: @MainActor @Sendable () -> Bool

    init(
        store: FakeStore,
        attemptIsCurrent: @escaping @MainActor @Sendable () -> Bool,
        attemptMayFinalizeAfterRelease: (@MainActor @Sendable () -> Bool)? = nil
    ) {
        self.store = store
        self.attemptIsCurrent = attemptIsCurrent
        self.attemptMayFinalizeAfterRelease = attemptMayFinalizeAfterRelease ?? attemptIsCurrent
    }

    func markSucceededAndClaimUsage(afterOwnershipRelease: Bool) async throws {
        try await requireAttempt(afterOwnershipRelease: afterOwnershipRelease)
        await store.markSucceeded()
        try await requireAttempt(afterOwnershipRelease: afterOwnershipRelease)
        await store.claimPendingUsage()
        try await requireAttempt(afterOwnershipRelease: afterOwnershipRelease)
    }

    private func requireAttempt(afterOwnershipRelease: Bool) async throws {
        let allowed = afterOwnershipRelease
            ? await attemptMayFinalizeAfterRelease()
            : await attemptIsCurrent()
        guard allowed else { throw CancellationError() }
    }
}

/// Mirrors the parts of AppState the live success path touches.
@MainActor
private final class FakeOwner {
    var activeRecordingID: UUID?
    var terminationBarrierActive = false

    func isCurrentAttempt(_ recordingID: UUID) -> Bool {
        !terminationBarrierActive && activeRecordingID == recordingID
    }

    func liveAttemptMayFinalizeAfterRelease() -> Bool {
        !terminationBarrierActive
    }

    /// Spawns the off-critical-path task, then releases ownership in the same
    /// synchronous run, as `AppState` does after a live transcript arrives.
    func finishLiveDictation(
        session: FakeSession,
        afterOwnershipRelease: Bool,
        quitBeforeTaskRuns: Bool = false
    ) -> Task<Bool, Never> {
        let task = Task { @MainActor in
            do {
                try await session.markSucceededAndClaimUsage(
                    afterOwnershipRelease: afterOwnershipRelease
                )
                return true
            } catch {
                return false
            }
        }
        activeRecordingID = nil
        if quitBeforeTaskRuns {
            terminationBarrierActive = true
        }
        return task
    }
}

@MainActor
private func makeSession(owner: FakeOwner, recordingID: UUID, store: FakeStore) -> FakeSession {
    FakeSession(
        store: store,
        attemptIsCurrent: { @MainActor in owner.isCurrentAttempt(recordingID) },
        attemptMayFinalizeAfterRelease: { @MainActor in
            owner.liveAttemptMayFinalizeAfterRelease()
        }
    )
}

@MainActor
private func testOwnershipCheckLeavesLiveDictationUnfinished() async throws {
    let owner = FakeOwner()
    let recordingID = UUID()
    owner.activeRecordingID = recordingID
    let store = FakeStore()
    let session = makeSession(owner: owner, recordingID: recordingID, store: store)

    let finished = await owner.finishLiveDictation(
        session: session,
        afterOwnershipRelease: false
    ).value

    try check(!finished, "requiring a current attempt should fail once ownership is released")
    let succeeded = await store.succeededCount
    try check(succeeded == 0, "the ownership check should block markSucceeded")
}

@MainActor
private func testReleaseSafeCheckFinishesLiveDictation() async throws {
    let owner = FakeOwner()
    let recordingID = UUID()
    owner.activeRecordingID = recordingID
    let store = FakeStore()
    let session = makeSession(owner: owner, recordingID: recordingID, store: store)

    let finished = await owner.finishLiveDictation(
        session: session,
        afterOwnershipRelease: true
    ).value

    try check(finished, "a released live attempt should record its success")
    let succeeded = await store.succeededCount
    let claimed = await store.claimedCount
    try check(succeeded == 1, "markSucceeded should run once, ran \(succeeded)")
    try check(claimed == 1, "claimPendingUsage should run once, ran \(claimed)")
}

@MainActor
private func testQuitStillFencesReleasedLiveDictation() async throws {
    let owner = FakeOwner()
    let recordingID = UUID()
    owner.activeRecordingID = recordingID
    let store = FakeStore()
    let session = makeSession(owner: owner, recordingID: recordingID, store: store)

    let finished = await owner.finishLiveDictation(
        session: session,
        afterOwnershipRelease: true,
        quitBeforeTaskRuns: true
    ).value

    try check(!finished, "the termination barrier should still fence a released attempt")
    let succeeded = await store.succeededCount
    try check(succeeded == 0, "no journal write should start after Quit")
}

private func section(_ source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        throw CheckError.failed("missing anchor: \(start)")
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        throw CheckError.failed("missing end anchor after \(start): \(end)")
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func testAppStateWiring() throws {
    let source = try String(
        contentsOfFile: "Whishpermate/Whispermate/Services/AppState.swift",
        encoding: .utf8
    )

    let liveTask = try section(
        source,
        from: "if historyWasPersisted, isLiveRecording {",
        to: "guard isCurrentAttempt("
    )
    try check(
        liveTask.contains("afterOwnershipRelease: true"),
        "the live success task must finalize with afterOwnershipRelease: true"
    )

    let nonLive = try section(
        source,
        from: "if historyWasPersisted, !isLiveRecording {",
        to: "if historyWasPersisted, isLiveRecording {"
    )
    try check(
        !nonLive.contains("afterOwnershipRelease"),
        "a retry still owns its attempt and must keep the ownership check"
    )

    let liveSession = try section(
        source,
        from: "recordingAttemptID = recognitionAttemptID\n            let session = MacStoreTranscriptionSession(",
        to: "guard let snapshot = activeTranscriptionSnapshot"
    )
    try check(
        liveSession.contains("attemptMayFinalizeAfterRelease:")
            && liveSession.contains("liveAttemptMayFinalizeAfterRelease("),
        "the live session must pass the release-safe finalize check"
    )

    let helper = try section(
        source,
        from: "private func liveAttemptMayFinalizeAfterRelease(attemptID: UUID) -> Bool {",
        to: "private func isCurrentAttempt("
    )
    try check(
        helper.contains("!terminationBarrierActive")
            && helper.contains("processingAttemptFence.allows(attemptID)"),
        "the release-safe check must keep the termination barrier and fence"
    )
    try check(
        !helper.contains("activeRecordingID"),
        "the release-safe check must not require recording ownership"
    )

    let method = try section(
        source,
        from: "func markSucceededAndClaimUsage(",
        to: "func fail(_ message: String)"
    )
    try check(
        method.components(separatedBy: "try await requireAttempt(afterOwnershipRelease: afterOwnershipRelease)").count - 1 == 3,
        "markSucceededAndClaimUsage must check the attempt before and after each store write"
    )
    try check(
        method.contains("await attemptMayFinalizeAfterRelease()")
            && method.contains("try await requireCurrentAttempt()"),
        "requireAttempt must choose between the release-safe and ownership checks"
    )
}

@main
private enum ValidateMacOSLiveSuccessFinalization {
    static func main() async {
        do {
            try await testOwnershipCheckLeavesLiveDictationUnfinished()
            try await testReleaseSafeCheckFinishesLiveDictation()
            try await testQuitStillFencesReleasedLiveDictation()
            try testAppStateWiring()
            print("macOS live success finalization validation passed")
        } catch {
            fputs("macOS live success finalization validation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
