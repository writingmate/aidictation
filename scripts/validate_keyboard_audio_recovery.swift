import Darwin
import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw ValidationFailure.assertion("\(message): expected \(expected), got \(actual)")
    }
}

private func resetStore(_ suite: String) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    UserDefaults(suiteName: suite)?.synchronize()
    try? FileManager.default.removeItem(at: testStoreDirectory(suite))
}

private func testStoreDirectory(_ suite: String) -> URL {
    let safeName = suite.replacingOccurrences(of: "/", with: "_")
    return FileManager.default.temporaryDirectory.appendingPathComponent(safeName, isDirectory: true)
}

private func testJournalURL(_ suite: String) -> URL {
    testStoreDirectory(suite).appendingPathComponent("KeyboardDictationHandoff.v2.json")
}

private func withHeldJournalLock<T>(_ suite: String, body: () throws -> T) throws -> T {
    let directory = testStoreDirectory(suite)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lockURL = directory.appendingPathComponent("KeyboardDictationHandoff.lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw ValidationFailure.assertion("validator could not open the journal lock")
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
        _ = close(descriptor)
        throw ValidationFailure.assertion("validator could not hold the journal lock")
    }
    defer {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
    return try body()
}

private func beginAndAcknowledgeRecording(
    at now: Date,
    recordingID: String
) throws -> KeyboardDictationHandoff.AttemptIdentity {
    let identity = try KeyboardDictationHandoff.beginAttempt(now: now)
    try expect(KeyboardDictationHandoff.publish(command: .start, identity: identity, now: now), "start must enqueue")
    let start = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: now)
    try expectEqual(start?.command, .start, "host must receive start")
    try expectEqual(start?.identity, identity, "start must carry the exact attempt identity")
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .recording,
            identity: identity,
            recordingID: recordingID,
            now: now.addingTimeInterval(1)
        ),
        "host must acknowledge ready recording"
    )
    return identity
}

private func run() throws {
    let suite = "KeyboardAudioRecoveryValidation.\(UUID().uuidString)"
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", suite, 1)
    resetStore(suite)
    defer {
        resetStore(suite)
        unsetenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE")
    }

    let base = Date(timeIntervalSince1970: 2_000_000_000)

    // No host / start acknowledgement timeout: preparing is persisted before the command,
    // its deadline is bounded, and the cancellation tombstone rejects a late acknowledgement.
    let noHost = try KeyboardDictationHandoff.beginAttempt(
        sessionID: "session-no-host",
        attemptID: "attempt-no-host",
        now: base
    )
    let preparing = KeyboardDictationHandoff.snapshot(for: noHost)
    try expectEqual(preparing?.phase, .preparing, "begin must persist preparing")
    try expectEqual(preparing?.hostAcknowledged, false, "preparing must await host acknowledgement")
    try expectEqual(
        preparing?.deadlineAt,
        base.addingTimeInterval(KeyboardDictationHandoff.startAcknowledgementTimeout),
        "preparing must persist the start deadline"
    )
    try expect(KeyboardDictationHandoff.publish(command: .start, identity: noHost, now: base), "start must publish")
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: noHost,
            reason: "Recording did not start in time.",
            now: preparing!.deadlineAt!
        ),
        "start timeout must durably cancel"
    )
    try expectEqual(KeyboardDictationHandoff.snapshot(for: noHost)?.phase, .cancelled, "start timeout must be terminal")
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .recording,
            identity: noHost,
            recordingID: "late-source",
            now: base.addingTimeInterval(30)
        ),
        "late start acknowledgement must be fenced"
    )

    // Stop timeout: stop intent and deadline are persisted atomically; repeated stop is a no-op.
    let stopTimeout = try beginAndAcknowledgeRecording(
        at: base.addingTimeInterval(100),
        recordingID: "recording-stop-timeout"
    )
    let stopAt = base.addingTimeInterval(102)
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: stopTimeout, now: stopAt), "stop must publish")
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: stopTimeout, now: stopAt), "duplicate stop must be idempotent")
    let finalizing = KeyboardDictationHandoff.snapshot(for: stopTimeout)
    try expectEqual(finalizing?.phase, .finalizing, "stop must persist finalizing")
    try expectEqual(finalizing?.hostAcknowledged, false, "stop must await host acknowledgement")
    try expectEqual(
        finalizing?.deadlineAt,
        stopAt.addingTimeInterval(KeyboardDictationHandoff.stopAcknowledgementTimeout),
        "stop must persist its deadline"
    )
    try expectEqual(
        KeyboardDictationHandoff.hostReconciliationAction(
            activeIdentity: stopTimeout,
            snapshot: finalizing,
            now: stopAt.addingTimeInterval(1)
        ),
        .stop,
        "host must enforce an unacknowledged durable stop when its envelope is lost"
    )
    try expectEqual(
        KeyboardDictationHandoff.hostReconciliationAction(
            activeIdentity: stopTimeout,
            snapshot: finalizing,
            now: finalizing!.deadlineAt!
        ),
        .cancel,
        "expired unacknowledged stop must fail closed"
    )
    try expectEqual(KeyboardDictationHandoff.consumePendingCommandEnvelope(now: stopAt)?.command, .stop, "host must receive one stop")
    try expect(KeyboardDictationHandoff.consumePendingCommandEnvelope(now: stopAt) == nil, "duplicate stop must not create another command")
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: stopTimeout,
            reason: "Recording did not finish in time.",
            now: finalizing!.deadlineAt!
        ),
        "stop timeout must cancel"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .processing,
            identity: stopTimeout,
            recordingID: "recording-stop-timeout",
            now: base.addingTimeInterval(150)
        ),
        "late stop callback must not leave the keyboard processing"
    )

    // Immediate retry can replace an old cancellation tombstone before its command TTL. The host
    // still owns the old native attempt and must cancel it before consuming the replacement start.
    let replacedHost = try beginAndAcknowledgeRecording(
        at: base.addingTimeInterval(160),
        recordingID: "recording-replaced-host"
    )
    let replacedAt = base.addingTimeInterval(162)
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: replacedHost,
            reason: "Cancelled before retry.",
            now: replacedAt
        ),
        "old host attempt must cancel durably"
    )
    let replacement = try KeyboardDictationHandoff.beginAttempt(
        sessionID: "session-replacement",
        attemptID: "attempt-replacement",
        now: replacedAt.addingTimeInterval(1)
    )
    try expectEqual(
        KeyboardDictationHandoff.hostReconciliationAction(
            activeIdentity: replacedHost,
            snapshot: KeyboardDictationHandoff.snapshot(for: replacement),
            now: replacedAt.addingTimeInterval(31)
        ),
        .cancel,
        "replacement generation must retire the old host attempt after cancel TTL"
    )
    try expect(
        KeyboardDictationHandoff.publish(
            command: .start,
            identity: replacement,
            now: replacedAt.addingTimeInterval(31)
        ),
        "replacement start must publish"
    )
    let retryReplacementStart = KeyboardDictationHandoff.consumePendingCommandEnvelope(
        now: replacedAt.addingTimeInterval(31)
    )
    try expectEqual(retryReplacementStart?.command, .start, "replacement start must survive old cancel expiry")
    try expectEqual(retryReplacementStart?.identity, replacement, "replacement start lost its identity")
    try expect(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(
            now: replacedAt.addingTimeInterval(31)
        ) == nil,
        "expired old cancel must not replay after replacement start"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: replacement,
            now: replacedAt.addingTimeInterval(32)
        ),
        "replacement fixture must terminate"
    )
    let retryReplacementCancel = KeyboardDictationHandoff.consumePendingCommandEnvelope(
        now: replacedAt.addingTimeInterval(32)
    )
    try expectEqual(retryReplacementCancel?.command, .cancel, "replacement cancel must be drained")
    try expectEqual(retryReplacementCancel?.identity, replacement, "replacement cancel lost its identity")

    // Result timeout: final source ownership survives in the tombstone and late text is rejected.
    let resultTimeout = try beginAndAcknowledgeRecording(
        at: base.addingTimeInterval(200),
        recordingID: "recording-result-timeout"
    )
    let resultStopAt = base.addingTimeInterval(202)
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: resultTimeout, now: resultStopAt), "result-timeout stop must publish")
    _ = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: resultStopAt)
    let hostFinalizationDeadline = base.addingTimeInterval(323)
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .finalizing,
            identity: resultTimeout,
            recordingID: "recording-result-timeout",
            deadlineAt: hostFinalizationDeadline,
            now: base.addingTimeInterval(203)
        ),
        "host must acknowledge finalization"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: resultTimeout)?.deadlineAt,
        hostFinalizationDeadline,
        "host acknowledgement must replace the short stop deadline with its finalization budget"
    )
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .processing,
            identity: resultTimeout,
            recordingID: "recording-result-timeout",
            now: base.addingTimeInterval(204)
        ),
        "host must begin processing after finalization"
    )
    let processing = KeyboardDictationHandoff.snapshot(for: resultTimeout)
    try expectEqual(
        processing?.deadlineAt,
        base.addingTimeInterval(204 + KeyboardDictationHandoff.resultTimeout),
        "processing must persist a bounded result deadline"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: resultTimeout,
            reason: "Transcription did not finish in time.",
            now: processing!.deadlineAt!
        ),
        "result timeout must cancel"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: resultTimeout)?.recordingID,
        "recording-result-timeout",
        "timeout tombstone must retain the host recording ID"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostResult(
            text: "late text",
            identity: resultTimeout,
            recordingID: "recording-result-timeout",
            now: base.addingTimeInterval(900)
        ),
        "late result after timeout must be rejected"
    )

    // Successful result is non-empty, exact-ID, stable-recording, and consumed at most once.
    let success = try beginAndAcknowledgeRecording(
        at: base.addingTimeInterval(1_000),
        recordingID: "recording-success"
    )
    let successStopAt = base.addingTimeInterval(1_002)
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: success, now: successStopAt), "success stop must publish")
    _ = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: successStopAt)
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .finalizing,
            identity: success,
            recordingID: "recording-success",
            now: base.addingTimeInterval(1_003)
        ),
        "success must acknowledge finalizing"
    )
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .processing,
            identity: success,
            recordingID: "recording-success",
            now: base.addingTimeInterval(1_004)
        ),
        "success must enter processing"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostResult(
            text: "  \n",
            identity: success,
            recordingID: "recording-success"
        ),
        "empty output must not become a successful result"
    )
    let wrongIdentity = KeyboardDictationHandoff.AttemptIdentity(
        sessionID: success.sessionID,
        attemptID: "wrong-attempt",
        generation: success.generation
    )
    try expect(
        !KeyboardDictationHandoff.publishHostResult(
            text: "wrong",
            identity: wrongIdentity,
            recordingID: "recording-success"
        ),
        "wrong-attempt result must be ignored"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostResult(
            text: "wrong recording",
            identity: success,
            recordingID: "different-recording"
        ),
        "recording ID must remain stable"
    )
    try expect(
        KeyboardDictationHandoff.publishHostResult(
            text: "complete transcript",
            identity: success,
            recordingID: "recording-success"
        ),
        "valid result must publish"
    )
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES", "1", 1)
    do {
        _ = try KeyboardDictationHandoff.consumeResultPersisted(for: success)
        throw ValidationFailure.assertion("result consumption must report a durable write failure")
    } catch KeyboardDictationHandoff.PersistenceError.journalWriteFailed {
        // Expected.
    }
    unsetenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES")
    try expect(
        !KeyboardDictationHandoff.cancelAttempt(identity: success),
        "a cancellation racing after durable success must not erase the transcript"
    )
    try expectEqual(KeyboardDictationHandoff.consumeResult(for: success), "complete transcript", "result must be delivered")
    try expect(KeyboardDictationHandoff.consumeResult(for: success) == nil, "result must not be inserted twice")

    // Bulk/duplicate events remain ordered and exact duplicates collapse. A stop that arrives
    // before the host acknowledges start wins durably, so capture cannot begin afterward.
    let bulkAt = base.addingTimeInterval(2_000)
    let bulk = try KeyboardDictationHandoff.beginAttempt(
        sessionID: "session-bulk",
        attemptID: "attempt-bulk",
        now: bulkAt
    )
    try expect(KeyboardDictationHandoff.publish(command: .start, identity: bulk, now: bulkAt), "bulk start must publish")
    try expect(KeyboardDictationHandoff.publish(command: .start, identity: bulk, now: bulkAt), "bulk duplicate start must dedupe")
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: bulk, now: bulkAt), "bulk stop must queue after start")
    try expect(KeyboardDictationHandoff.publish(command: .stop, identity: bulk, now: bulkAt), "bulk duplicate stop must dedupe")
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: bulk)?.phase,
        .finalizing,
        "a stop queued during preparation must immediately become authoritative"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: bulk)?.recordingID,
        nil,
        "stop-before-start must not invent a recording ID"
    )
    let first = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: bulkAt)
    try expectEqual(first?.command, .start, "bulk start must remain first")
    try expectEqual(first?.sequence, 1, "bulk start sequence")
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .recording,
            identity: bulk,
            recordingID: "recording-bulk",
            now: bulkAt.addingTimeInterval(1)
        ),
        "the host must not start capture after a durable pre-start stop"
    )
    let second = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: bulkAt.addingTimeInterval(1))
    try expectEqual(second?.command, .stop, "bulk stop must remain second")
    try expectEqual(second?.sequence, 2, "bulk stop sequence")
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: bulk)?.phase,
        .finalizing,
        "consuming rapid start and stop must retain the stopped-before-start state"
    )
    try expect(KeyboardDictationHandoff.consumePendingCommandEnvelope(now: bulkAt.addingTimeInterval(1)) == nil, "bulk duplicates must be absent")

    // Cancel/delete wins durably, and a new generation fences every old callback.
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: bulk,
            reason: "Recording deleted.",
            now: bulkAt.addingTimeInterval(2)
        ),
        "delete tombstone must persist"
    )
    let bulkReplacement = try KeyboardDictationHandoff.beginAttempt(
        sessionID: "session-replacement",
        attemptID: "attempt-replacement",
        now: bulkAt.addingTimeInterval(10)
    )
    try expect(bulkReplacement.generation > bulk.generation, "new attempt generation must increase")
    try expect(
        KeyboardDictationHandoff.publish(
            command: .start,
            identity: bulkReplacement,
            now: bulkAt.addingTimeInterval(10)
        ),
        "replacement start must publish after the older cancellation"
    )
    let carriedCancel = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: bulkAt.addingTimeInterval(10))
    try expectEqual(carriedCancel?.command, .cancel, "immediate retry must deliver the older cancel first")
    try expectEqual(carriedCancel?.identity, bulk, "carried cancel must retain the older exact identity")
    let replacementStart = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: bulkAt.addingTimeInterval(10))
    try expectEqual(replacementStart?.command, .start, "replacement start must follow the older cancel")
    try expectEqual(replacementStart?.identity, bulkReplacement, "replacement start must retain its exact identity")
    do {
        _ = try KeyboardDictationHandoff.beginAttempt(now: bulkAt.addingTimeInterval(10.5))
        throw ValidationFailure.assertion("active work must not be overwritten by another begin")
    } catch KeyboardDictationHandoff.PersistenceError.activeAttemptExists {
        // Expected.
    }
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .processing,
            identity: bulk,
            recordingID: "recording-bulk"
        ),
        "old callback must not mutate a replacement attempt"
    )
    try expectEqual(
        KeyboardDictationHandoff.currentSnapshot()?.identity,
        bulkReplacement,
        "replacement attempt must remain authoritative"
    )
    try expect(
        !KeyboardDictationHandoff.publish(command: .cancel, sessionID: nil),
        "a legacy command without a session must not target the current attempt"
    )
    try expect(
        !KeyboardDictationHandoff.publish(command: .stop, sessionID: "wrong-session"),
        "a legacy command for another session must not target the current attempt"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: bulkReplacement,
            now: bulkAt.addingTimeInterval(11)
        ),
        "replacement cleanup must persist"
    )

    // The cancellation snapshot, rather than its short-lived notification envelope, is the
    // durable authority for host teardown after suspension.
    let staleCancelAt = base.addingTimeInterval(2_300)
    let staleCancel = try beginAndAcknowledgeRecording(
        at: staleCancelAt,
        recordingID: "recording-stale-cancel"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: staleCancel,
            now: staleCancelAt.addingTimeInterval(2)
        ),
        "suspended-host cancellation must persist"
    )
    try expect(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(
            now: staleCancelAt.addingTimeInterval(33)
        ) == nil,
        "an expired cancellation notification must not be replayed"
    )
    let authoritativeCancellation = try KeyboardDictationHandoff.loadSnapshot(for: staleCancel)
    try expectEqual(
        authoritativeCancellation?.phase,
        .cancelled,
        "the persisted cancellation must remain authoritative after command expiry"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .finalizing,
            identity: staleCancel,
            recordingID: "recording-stale-cancel",
            now: staleCancelAt.addingTimeInterval(34)
        ),
        "the expired notification must not weaken the cancellation callback fence"
    )

    // A live recording heartbeat keeps the keyboard active; losing it expires the attempt and
    // fences every callback from the vanished host process.
    let heartbeatAt = base.addingTimeInterval(2_500)
    let heartbeat = try beginAndAcknowledgeRecording(
        at: heartbeatAt,
        recordingID: "recording-heartbeat"
    )
    KeyboardDictationHandoff.publishMeter(
        audioLevel: 0.2,
        frequencyBands: [0.1, 0.2],
        identity: heartbeat,
        now: heartbeatAt.addingTimeInterval(2)
    )
    let heartbeatFreshAt = heartbeatAt.addingTimeInterval(
        2 + KeyboardDictationHandoff.recordingHeartbeatTimeout - 0.1
    )
    try expectEqual(
        try KeyboardDictationHandoff.expireStaleAttempt(now: heartbeatFreshAt)?.phase,
        .recording,
        "an exact fresh heartbeat must keep recording active"
    )
    let heartbeatExpiredAt = heartbeatAt.addingTimeInterval(
        2 + KeyboardDictationHandoff.recordingHeartbeatTimeout + 0.1
    )
    try expectEqual(
        try KeyboardDictationHandoff.expireStaleAttempt(now: heartbeatExpiredAt)?.phase,
        .cancelled,
        "a missing recording heartbeat must become terminal"
    )
    try expect(
        !KeyboardDictationHandoff.publishHostPhase(
            .finalizing,
            identity: heartbeat,
            recordingID: "recording-heartbeat",
            now: heartbeatExpiredAt.addingTimeInterval(1)
        ),
        "a late callback after heartbeat expiry must be fenced"
    )

    // A fresh exact start survives a containing-app launch, but work owned by a process that
    // subsequently dies is terminalized on the next launch.
    let launchAt = base.addingTimeInterval(2_700)
    let launchAttempt = try KeyboardDictationHandoff.beginAttempt(
        sessionID: "session-host-launch",
        attemptID: "attempt-host-launch",
        now: launchAt
    )
    try expect(
        KeyboardDictationHandoff.publish(command: .start, identity: launchAttempt, now: launchAt),
        "host-launch start must publish"
    )
    let freshLaunchNormalization = try KeyboardDictationHandoff.normalizeAfterHostLaunch(
        now: launchAt.addingTimeInterval(1)
    )
    try expect(
        freshLaunchNormalization == nil,
        "a fresh exact queued start must survive host launch normalization"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: launchAttempt)?.phase,
        .preparing,
        "fresh host-launch start must remain preparing"
    )
    _ = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: launchAt.addingTimeInterval(1))

    let hostChild = Process()
    hostChild.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    hostChild.arguments = [
        "--ack-recording",
        launchAttempt.sessionID,
        launchAttempt.attemptID,
        String(launchAttempt.generation),
        "recording-host-launch",
        String(launchAt.addingTimeInterval(2).timeIntervalSince1970),
    ]
    try hostChild.run()
    hostChild.waitUntilExit()
    try expect(hostChild.terminationStatus == 0, "child host must durably acknowledge recording before exit")
    try expectEqual(
        try KeyboardDictationHandoff.normalizeAfterHostLaunch(now: launchAt.addingTimeInterval(3)),
        launchAttempt,
        "the next host process must report the abandoned identity it terminalized"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: launchAttempt)?.phase,
        .cancelled,
        "process death during recording must normalize to a terminal state"
    )

    // Relaunch also expires finalization and processing; their stable recording IDs survive.
    let relaunchFinalizingAt = base.addingTimeInterval(2_800)
    let relaunchFinalizing = try beginAndAcknowledgeRecording(
        at: relaunchFinalizingAt,
        recordingID: "recording-relaunch-finalizing"
    )
    try expect(
        KeyboardDictationHandoff.publish(
            command: .stop,
            identity: relaunchFinalizing,
            now: relaunchFinalizingAt.addingTimeInterval(2)
        ),
        "relaunch finalizing stop must publish"
    )
    try expectEqual(
        try KeyboardDictationHandoff.normalizeAfterHostLaunch(now: relaunchFinalizingAt.addingTimeInterval(3)),
        relaunchFinalizing,
        "host launch must terminalize abandoned finalization"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: relaunchFinalizing)?.recordingID,
        "recording-relaunch-finalizing",
        "finalization recovery must retain the stable recording ID"
    )

    let relaunchProcessingAt = base.addingTimeInterval(2_900)
    let relaunchProcessing = try beginAndAcknowledgeRecording(
        at: relaunchProcessingAt,
        recordingID: "recording-relaunch-processing"
    )
    try expect(
        KeyboardDictationHandoff.publish(
            command: .stop,
            identity: relaunchProcessing,
            now: relaunchProcessingAt.addingTimeInterval(2)
        ),
        "relaunch processing stop must publish"
    )
    _ = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: relaunchProcessingAt.addingTimeInterval(2))
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .finalizing,
            identity: relaunchProcessing,
            recordingID: "recording-relaunch-processing",
            now: relaunchProcessingAt.addingTimeInterval(3)
        ),
        "host must acknowledge finalizing before processing"
    )
    try expect(
        KeyboardDictationHandoff.publishHostPhase(
            .processing,
            identity: relaunchProcessing,
            recordingID: "recording-relaunch-processing",
            now: relaunchProcessingAt.addingTimeInterval(4)
        ),
        "host must enter processing"
    )
    try expectEqual(
        try KeyboardDictationHandoff.normalizeAfterHostLaunch(now: relaunchProcessingAt.addingTimeInterval(5)),
        relaunchProcessing,
        "host launch must terminalize abandoned processing"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: relaunchProcessing)?.recordingID,
        "recording-relaunch-processing",
        "processing recovery must retain the stable recording ID"
    )

    // Separate processes serialize through the app-group lock and cannot enqueue duplicate stops.
    let crossProcess = try beginAndAcknowledgeRecording(
        at: base.addingTimeInterval(3_000),
        recordingID: "recording-cross-process"
    )
    var childProcesses: [Process] = []
    for _ in 0 ..< 6 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = [
            "--publish-stop",
            crossProcess.sessionID,
            crossProcess.attemptID,
            String(crossProcess.generation),
            String(base.addingTimeInterval(3_002).timeIntervalSince1970),
        ]
        try child.run()
        childProcesses.append(child)
    }
    for child in childProcesses {
        child.waitUntilExit()
        try expect(child.terminationStatus == 0, "cross-process stop must be accepted idempotently")
    }
    try expectEqual(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(now: base.addingTimeInterval(3_002))?.command,
        .stop,
        "cross-process duplicate stop must yield one command"
    )
    try expect(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(now: base.addingTimeInterval(3_002)) == nil,
        "cross-process duplicate stop must not be replayed"
    )

    // A suspended peer holding the cross-process lock cannot freeze the keyboard indefinitely.
    let lockTimeoutSuite = "KeyboardAudioRecoveryLockTimeout.\(UUID().uuidString)"
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", lockTimeoutSuite, 1)
    resetStore(lockTimeoutSuite)
    _ = try KeyboardDictationHandoff.beginAttempt(now: base)
    try withHeldJournalLock(lockTimeoutSuite) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            _ = try KeyboardDictationHandoff.loadCurrentSnapshot()
            throw ValidationFailure.assertion("a held journal lock must not be bypassed")
        } catch KeyboardDictationHandoff.PersistenceError.storageUnavailable {
            // Expected.
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        try expect(elapsed < 2, "journal lock acquisition must fail within its bounded deadline")
    }
    resetStore(lockTimeoutSuite)
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", suite, 1)

    // A failed fsynced journal write is reported and cannot leak an undurable command.
    let writeFailureSuite = "KeyboardAudioRecoveryWriteFailure.\(UUID().uuidString)"
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", writeFailureSuite, 1)
    resetStore(writeFailureSuite)
    let writeFailureIdentity = try KeyboardDictationHandoff.beginAttempt(now: base)
    try expect(FileManager.default.fileExists(atPath: testJournalURL(writeFailureSuite).path), "begin must create the durable journal")
    try expect(
        KeyboardDictationHandoff.publish(command: .start, identity: writeFailureIdentity, now: base),
        "write-failure fixture start must publish before consumption"
    )
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES", "1", 1)
    do {
        _ = try KeyboardDictationHandoff.consumePendingCommandEnvelopePersisted(now: base)
        throw ValidationFailure.assertion("command consumption must report a durable write failure")
    } catch KeyboardDictationHandoff.PersistenceError.journalWriteFailed {
        // Expected.
    }
    try expect(
        !KeyboardDictationHandoff.publish(command: .stop, identity: writeFailureIdentity, now: base),
        "command write failure must be returned"
    )
    unsetenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES")
    try expectEqual(
        try KeyboardDictationHandoff.consumePendingCommandEnvelopePersisted(now: base)?.command,
        .start,
        "failed command consumption must leave the original command durable"
    )
    let commandAfterFailedStop = try KeyboardDictationHandoff.consumePendingCommandEnvelopePersisted(now: base)
    try expect(
        commandAfterFailedStop == nil,
        "a failed stop write must not leak into the queue"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(
            identity: writeFailureIdentity,
            now: base.addingTimeInterval(1)
        ),
        "write-failure fixture must be terminalized after storage recovers"
    )
    _ = KeyboardDictationHandoff.consumePendingCommandEnvelope(now: base.addingTimeInterval(1))
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES", "1", 1)
    do {
        _ = try KeyboardDictationHandoff.beginAttempt(now: base.addingTimeInterval(2))
        throw ValidationFailure.assertion("begin must throw when the durable write fails")
    } catch KeyboardDictationHandoff.PersistenceError.journalWriteFailed {
        // Expected.
    }
    unsetenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_WRITES")
    try expect(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(now: base) == nil,
        "failed command write must not appear after storage recovers"
    )

    // Read/corruption failures are distinguishable from an empty store and every mutation fails closed.
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_READS", "1", 1)
    do {
        _ = try KeyboardDictationHandoff.loadCurrentSnapshot()
        throw ValidationFailure.assertion("read failure must throw")
    } catch KeyboardDictationHandoff.PersistenceError.journalReadFailed {
        // Expected.
    }
    do {
        _ = try KeyboardDictationHandoff.consumePendingCommandEnvelopePersisted(now: base)
        throw ValidationFailure.assertion("command consumer must report a journal read failure")
    } catch KeyboardDictationHandoff.PersistenceError.journalReadFailed {
        // Expected.
    }
    try expect(
        !KeyboardDictationHandoff.publish(command: .start, identity: writeFailureIdentity, now: base),
        "mutation must fail closed during a journal read failure"
    )
    unsetenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_FAIL_READS")
    try Data("{".utf8).write(to: testJournalURL(writeFailureSuite), options: .atomic)
    do {
        _ = try KeyboardDictationHandoff.loadCurrentSnapshot()
        throw ValidationFailure.assertion("corrupt journal must throw")
    } catch KeyboardDictationHandoff.PersistenceError.journalCorrupt {
        // Expected.
    }
    do {
        _ = try KeyboardDictationHandoff.beginAttempt(now: base.addingTimeInterval(2))
        throw ValidationFailure.assertion("begin must not replace a corrupt journal")
    } catch KeyboardDictationHandoff.PersistenceError.journalCorrupt {
        // Expected.
    }
    resetStore(writeFailureSuite)

    // Sequence and generation exhaustion stop instead of wrapping to reusable values.
    let sequenceSuite = "KeyboardAudioRecoverySequenceOverflow.\(UUID().uuidString)"
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", sequenceSuite, 1)
    resetStore(sequenceSuite)
    let sequenceIdentity = try KeyboardDictationHandoff.beginAttempt(now: base)
    let sequenceData = try Data(contentsOf: testJournalURL(sequenceSuite))
    let sequenceJSON = String(decoding: sequenceData, as: UTF8.self)
    let exhaustedSequenceJSON = sequenceJSON.replacingOccurrences(
        of: "\"nextCommandSequence\":1",
        with: "\"nextCommandSequence\":\(UInt64.max)"
    )
    try expect(sequenceJSON != exhaustedSequenceJSON, "validator must locate sequence counter")
    try Data(exhaustedSequenceJSON.utf8).write(to: testJournalURL(sequenceSuite), options: .atomic)
    try expect(
        !KeyboardDictationHandoff.publish(command: .start, identity: sequenceIdentity, now: base),
        "sequence exhaustion must reject the command"
    )
    try expect(
        KeyboardDictationHandoff.cancelAttempt(identity: sequenceIdentity, now: base.addingTimeInterval(1)),
        "sequence exhaustion must still permit a durable terminal tombstone without wrapping"
    )
    try expectEqual(
        KeyboardDictationHandoff.snapshot(for: sequenceIdentity)?.phase,
        .cancelled,
        "sequence exhaustion cancellation must be terminal"
    )
    try expect(
        KeyboardDictationHandoff.consumePendingCommandEnvelope(now: base.addingTimeInterval(1)) == nil,
        "sequence exhaustion must never reuse a command sequence"
    )
    resetStore(sequenceSuite)

    let generationSuite = "KeyboardAudioRecoveryGenerationOverflow.\(UUID().uuidString)"
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", generationSuite, 1)
    resetStore(generationSuite)
    _ = try KeyboardDictationHandoff.beginAttempt(now: base)
    let generationData = try Data(contentsOf: testJournalURL(generationSuite))
    let generationJSON = String(decoding: generationData, as: UTF8.self)
    let exhaustedGenerationJSON = generationJSON.replacingOccurrences(
        of: "\"generation\":1",
        with: "\"generation\":\(UInt64.max)"
    )
    try expect(generationJSON != exhaustedGenerationJSON, "validator must locate generation counter")
    try Data(exhaustedGenerationJSON.utf8).write(to: testJournalURL(generationSuite), options: .atomic)
    do {
        _ = try KeyboardDictationHandoff.beginAttempt(now: base.addingTimeInterval(1))
        throw ValidationFailure.assertion("generation exhaustion must throw")
    } catch KeyboardDictationHandoff.PersistenceError.generationExhausted {
        // Expected.
    }
    resetStore(generationSuite)
    setenv("AIDICTATION_KEYBOARD_HANDOFF_TEST_SUITE", suite, 1)

    let contentURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Whishpermate/WhisperMateIOS/ContentView.swift")
    let contentSource = try String(contentsOf: contentURL, encoding: .utf8)
    let failClosedCallCount = contentSource.components(
        separatedBy: "cancelActiveKeyboardHostWork()"
    ).count - 1
    try expect(
        failClosedCallCount >= 4,
        "host journal load/consume failures do not retire active native work"
    )

    print("Keyboard audio recovery validation passed")
}

@main
private enum KeyboardAudioRecoveryValidator {
    static func main() {
        if CommandLine.arguments.count == 7, CommandLine.arguments[1] == "--ack-recording" {
            guard let generation = UInt64(CommandLine.arguments[4]),
                  let timestamp = TimeInterval(CommandLine.arguments[6])
            else {
                exit(2)
            }
            let identity = KeyboardDictationHandoff.AttemptIdentity(
                sessionID: CommandLine.arguments[2],
                attemptID: CommandLine.arguments[3],
                generation: generation
            )
            let accepted = KeyboardDictationHandoff.publishHostPhase(
                .recording,
                identity: identity,
                recordingID: CommandLine.arguments[5],
                now: Date(timeIntervalSince1970: timestamp)
            )
            exit(accepted ? 0 : 1)
        }

        if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--publish-stop" {
            guard let generation = UInt64(CommandLine.arguments[4]),
                  let timestamp = TimeInterval(CommandLine.arguments[5])
            else {
                exit(2)
            }
            let identity = KeyboardDictationHandoff.AttemptIdentity(
                sessionID: CommandLine.arguments[2],
                attemptID: CommandLine.arguments[3],
                generation: generation
            )
            let accepted = KeyboardDictationHandoff.publish(
                command: .stop,
                identity: identity,
                now: Date(timeIntervalSince1970: timestamp)
            )
            exit(accepted ? 0 : 1)
        }

        do {
            try run()
        } catch {
            fputs("Keyboard audio recovery validation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
