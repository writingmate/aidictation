import AVFoundation
import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private struct InjectedDeletionCrash: Error, Sendable {}
private struct InjectedHistoryCommitFailure: Error, Sendable {}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class StalledNativeExport: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void

    private let lock = NSLock()
    private var completion: Completion?
    private var cancellationCountStorage = 0

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationCountStorage
    }

    func start(_ completion: @escaping Completion) -> @Sendable () -> Void {
        lock.lock()
        self.completion = completion
        lock.unlock()
        return { [weak self] in
            self?.lock.lock()
            self?.cancellationCountStorage += 1
            self?.lock.unlock()
        }
    }

    func completeLate() {
        lock.lock()
        let completion = completion
        lock.unlock()
        completion?(.success(()))
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.failed(message) }
}

private func requireThrows(
    _ expected: MobileAudioProcessingStore.StoreError,
    _ operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw ValidationFailure.failed("Expected \(expected), but operation succeeded")
    } catch let error as MobileAudioProcessingStore.StoreError {
        try require(error == expected, "Expected \(expected), got \(error)")
    }
}

private func requireInjectedDeletionCrash(
    _ operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw ValidationFailure.failed("Expected injected deletion crash, but operation succeeded")
    } catch is InjectedDeletionCrash {
        return
    }
}

private func makeRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ios-audio-recovery-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

private func writeM4AAudioFixture(to url: URL) throws {
    // Synthetic 0.5-second mono AAC/M4A fixture. Keeping the fixture inline makes the validator
    // independent of optional command-line encoders on CI hosts.
    let fixture = """
    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
    """
    guard let data = Data(base64Encoded: fixture, options: .ignoreUnknownCharacters) else {
        throw ValidationFailure.failed("Could not decode audio fixture")
    }
    try data.write(to: url, options: .atomic)
}

private func writeValidAudio(to url: URL, seconds: Double = 0.5) throws {
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ) else { throw ValidationFailure.failed("Could not create audio format") }
    let frames = AVAudioFrameCount(sampleRate * seconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let samples = buffer.floatChannelData?[0]
    else { throw ValidationFailure.failed("Could not create audio buffer") }
    buffer.frameLength = frames
    for index in 0 ..< Int(frames) {
        samples[index] = sin(Float(index) * 0.03) * 0.2
    }
    let waveURL = url.deletingLastPathComponent()
        .appendingPathComponent("validator-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: waveURL) }

    var file: AVAudioFile? = try AVAudioFile(forWriting: waveURL, settings: format.settings)
    try file?.write(from: buffer)
    file = nil
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: waveURL, to: url)
}

private func makeFinalizedAttempt(
    store: MobileAudioProcessingStore,
    outputMode: String = "dictation",
    transcriptionOptions: TranscriptionOptions = .default
) async throws -> (MobileAudioProcessingStore.Lease, MobileAudioProcessingStore.FinalizedSource) {
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        attemptID: UUID(),
        outputModeRaw: outputMode,
        transcriptionOptions: transcriptionOptions,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await store.captureBecameReady(lease, deadlineAt: Date().addingTimeInterval(30))
    try writeValidAudio(to: lease.sourceURL)
    try await store.beginFinalization(lease, deadlineAt: Date().addingTimeInterval(30))
    let proof = try await store.proveFinalizedSource(
        lease,
        minimumBytes: 1_000,
        minimumDuration: 0.35
    )
    try await store.checkpointFinalizedSourceProof(lease, proof: proof)
    let finalized = try await store.acceptFinalizedSource(
        lease,
        proof: proof
    )
    return (lease, finalized)
}

private func testDeadlineReturnsWithoutWaitingForLateWork() async throws {
    let started = Date()
    do {
        _ = try await IOSAudioProcessingDeadline.run(seconds: 0.05) {
            await withUnsafeContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                    continuation.resume(returning: "late")
                }
            }
        } as String
        throw ValidationFailure.failed("Deadline unexpectedly accepted late work")
    } catch let error as IOSAudioProcessingDeadlineError {
        try require(error == .timedOut, "Expected timeout, got \(error)")
    }
    try require(Date().timeIntervalSince(started) < 0.25, "Deadline waited for abandoned work")

    do {
        _ = try await IOSAudioProcessingDeadline.run(seconds: .infinity) { "never" } as String
        throw ValidationFailure.failed("Infinite deadline was accepted")
    } catch let error as IOSAudioProcessingDeadlineError {
        try require(error == .timedOut, "Infinite deadline did not fail closed")
    }
}

private func testStalledNativeExportReturnsTerminalAndFencesLateCompletion() async throws {
    let root = try makeRoot("stalled-native-export")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let (lease, finalized) = try await makeFinalizedAttempt(store: store)
    _ = try await store.beginRecognition(
        lease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    let workspace = try await store.makeChunkWorkspace(for: lease)
    let derivedLeaf = try workspace.allocateOutputURL()
    let exporter = StalledNativeExport()
    let started = Date()

    do {
        _ = try await IOSAudioProcessingDeadline.run(seconds: 0.05) {
            try await IOSNativeCallbackOperation.run(start: exporter.start)
        } as Void
        throw ValidationFailure.failed("A stalled native export escaped its deadline")
    } catch let error as IOSAudioProcessingDeadlineError {
        try require(error == .timedOut, "Stalled native export returned \(error)")
    }
    try require(
        Date().timeIntervalSince(started) < 0.25,
        "Native export deadline waited for the missing callback"
    )
    try require(
        exporter.cancellationCount == 1,
        "Native export was not cancelled exactly once at the deadline"
    )

    try await store.markFailed(
        lease,
        message: "Audio preparation timed out.",
        integrity: .complete
    )
    let terminal = try await store.snapshot(recordingID: lease.recordingID)
    try require(terminal?.stage == .failed, "Export timeout did not return the store to terminal")
    try require(
        terminal?.sourceIntegrity == .complete
            && FileManager.default.fileExists(atPath: finalized.url.path),
        "Export timeout lost the recoverable source"
    )

    exporter.completeLate()
    try await Task.sleep(nanoseconds: 30_000_000)
    let afterLateCompletion = try await store.snapshot(recordingID: lease.recordingID)
    try require(
        afterLateCompletion?.stage == .failed,
        "A late native export callback revived the abandoned attempt"
    )
    workspace.remove(derivedLeaf)
    workspace.cleanupAll()
}

private func testStickyCancellationBeforeNewAndRetryAllocationReturns() async throws {
    let newEntered = DispatchSemaphore(value: 0)
    let releaseNew = DispatchSemaphore(value: 0)
    let nativeStartCount = LockedCounter()
    let newRoot = try makeRoot("sticky-new-allocation")
    let newStore = MobileAudioProcessingStore(
        rootDirectory: newRoot,
        beforeAttemptAllocation: {
            newEntered.signal()
            releaseNew.wait()
        }
    )
    let newRecordingID = UUID()
    let newAttemptID = UUID()
    let delayedNew = Task {
        let lease = try await newStore.beginNewAttempt(
            recordingID: newRecordingID,
            attemptID: newAttemptID,
            deadlineAt: Date().addingTimeInterval(30)
        )
        guard !Task.isCancelled else {
            try? await newStore.markCancelled(lease)
            throw CancellationError()
        }
        nativeStartCount.increment()
        return lease
    }
    await waitForSemaphore(newEntered)
    delayedNew.cancel()
    releaseNew.signal()
    do {
        _ = try await delayedNew.value
        throw ValidationFailure.failed("Cancelled delayed allocation started native capture")
    } catch is CancellationError {}

    let cancelledNew = try await newStore.snapshot(recordingID: newRecordingID)
    try require(cancelledNew?.stage == .cancelled, "Late new lease was not durably cancelled")
    try require(
        nativeStartCount.value == 0,
        "Microphone start ran after cancellation won before lease allocation"
    )
    try require(
        cancelledNew.map { FileManager.default.fileExists(atPath: $0.sourcePath) } == true,
        "Late new-attempt journal is not recoverable"
    )

    let retryRoot = try makeRoot("sticky-retry-allocation")
    let setupStore = MobileAudioProcessingStore(rootDirectory: retryRoot)
    let (initialLease, _) = try await makeFinalizedAttempt(store: setupStore)
    try await setupStore.markFailed(
        initialLease,
        message: "Retry fixture",
        integrity: .complete
    )
    let retryEntered = DispatchSemaphore(value: 0)
    let releaseRetry = DispatchSemaphore(value: 0)
    let recognitionStartCount = LockedCounter()
    let retryStore = MobileAudioProcessingStore(
        rootDirectory: retryRoot,
        beforeAttemptAllocation: {
            retryEntered.signal()
            releaseRetry.wait()
        }
    )
    let retryAttemptID = UUID()
    let delayedRetry = Task {
        let lease = try await retryStore.beginRetry(
            recordingID: initialLease.recordingID,
            attemptID: retryAttemptID,
            deadlineAt: Date().addingTimeInterval(30)
        )
        guard !Task.isCancelled else {
            try? await retryStore.markCancelled(lease)
            throw CancellationError()
        }
        recognitionStartCount.increment()
        return lease
    }
    await waitForSemaphore(retryEntered)
    delayedRetry.cancel()
    releaseRetry.signal()
    do {
        _ = try await delayedRetry.value
        throw ValidationFailure.failed("Cancelled delayed retry started recognition")
    } catch is CancellationError {}

    let cancelledRetry = try await retryStore.snapshot(recordingID: initialLease.recordingID)
    try require(cancelledRetry?.stage == .cancelled, "Late retry lease was not durably cancelled")
    try require(
        recognitionStartCount.value == 0,
        "Recognition ran after cancellation won before retry allocation"
    )
    try require(
        cancelledRetry?.sourceIntegrity == .complete,
        "Cancelled late retry lost the complete canonical source"
    )
}

private func testAttemptOwnedChunkWorkspaceCrashSweepAndSymlinkFence() async throws {
    let root = try makeRoot("chunk-workspace-sweep")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let (lease, finalized) = try await makeFinalizedAttempt(store: store)
    _ = try await store.beginRecognition(
        lease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    let workspace = try await store.makeChunkWorkspace(for: lease)
    let derivedLeaf = try workspace.allocateOutputURL()
    try Data("derived upload leaf".utf8).write(to: derivedLeaf)
    try require(
        FileManager.default.fileExists(atPath: derivedLeaf.path),
        "Chunk workspace fixture was not created"
    )

    let restarted = MobileAudioProcessingStore(rootDirectory: root)
    _ = try await restarted.normalizeInterruptedAttempts()
    try require(
        !FileManager.default.fileExists(atPath: derivedLeaf.path),
        "Launch recovery did not sweep the crashed attempt workspace"
    )
    let recovered = try await restarted.snapshot(recordingID: lease.recordingID)
    try require(
        recovered?.stage == .failed
            && recovered?.sourceIntegrity == .complete
            && FileManager.default.fileExists(atPath: finalized.url.path),
        "Workspace sweep damaged the durable source or left work active"
    )
    workspace.remove(derivedLeaf)
    workspace.cleanupAll()

    let hostileRoot = try makeRoot("chunk-workspace-symlink")
    let hostileStore = MobileAudioProcessingStore(rootDirectory: hostileRoot)
    _ = try await hostileStore.normalizeInterruptedAttempts()
    let outside = try makeRoot("chunk-workspace-outside")
    let sentinel = outside.appendingPathComponent("sentinel.txt")
    try Data("must survive".utf8).write(to: sentinel)
    let hostileRecordingDirectory = hostileRoot
        .appendingPathComponent("ChunkWorkspaces", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createSymbolicLink(
        at: hostileRecordingDirectory,
        withDestinationURL: outside
    )
    try await requireThrows(.quarantined) {
        _ = try await hostileStore.normalizeInterruptedAttempts()
    }
    try require(
        FileManager.default.fileExists(atPath: sentinel.path),
        "Workspace recovery followed a symlink outside its ownership root"
    )
}

@MainActor
private func testRevisionedHistoryMultiSceneTombstoneAndTruthfulFailure() async throws {
    let root = try makeRoot("history-multi-scene")
    let first = HistoryManager(rootDirectory: root)
    let second = HistoryManager(rootDirectory: root)
    try await first.reload()
    try await second.reload()

    let firstRecording = Recording(transcription: "first durable row")
    let secondRecording = Recording(transcription: "second durable row")
    try await first.upsertRecording(firstRecording)
    try await second.upsertRecording(secondRecording)
    try await first.reload()
    try require(
        first.recordings.map(\.id) == [secondRecording.id, firstRecording.id],
        "Two scenes lost a committed row or changed durable order"
    )

    try await second.deleteRecording(firstRecording)
    do {
        try await first.upsertRecording(firstRecording)
        throw ValidationFailure.failed("A stale scene resurrected a tombstoned recording")
    } catch let error as HistoryPersistenceError {
        try require(error == .deleted, "Tombstone returned the wrong error: \(error)")
    }
    try await first.reload()
    try require(
        !first.recordings.contains(where: { $0.id == firstRecording.id }),
        "Deleted history row reappeared after cross-scene reload"
    )

    let failedCommit = HistoryManager(
        rootDirectory: root,
        beforeCommit: { throw InjectedHistoryCommitFailure() }
    )
    try await failedCommit.reload()
    let beforeFailure = failedCommit.recordings
    do {
        try await failedCommit.upsertRecording(Recording(transcription: "must not publish"))
        throw ValidationFailure.failed("Injected History commit failure was swallowed")
    } catch is InjectedHistoryCommitFailure {}
    try require(
        failedCommit.recordings.map(\.id) == beforeFailure.map(\.id),
        "History projection advanced despite a failed durable commit"
    )

    try Data("{corrupt".utf8).write(
        to: root.appendingPathComponent("history.json"),
        options: .atomic
    )
    try await first.clearAll(recordingIDs: [secondRecording.id])
    try await second.reload()
    try require(second.recordings.isEmpty, "Clear did not repair corrupt History")
    do {
        try await second.upsertRecording(secondRecording)
        throw ValidationFailure.failed("Clear repair lost its deletion tombstone")
    } catch let error as HistoryPersistenceError {
        try require(error == .deleted, "Clear tombstone returned the wrong error")
    }
}

private func testBoundedDeepValidationAndCaptureLimitFinalization() async throws {
    let root = try makeRoot("blocked-deep-validation")
    let store = MobileAudioProcessingStore(
        rootDirectory: root,
        beforeDeepSourceValidation: {
            Thread.sleep(forTimeInterval: 0.4)
        }
    )
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(1)
    )
    try await store.captureBecameReady(lease, deadlineAt: Date().addingTimeInterval(1))
    try writeValidAudio(to: lease.sourceURL)
    try await store.beginFinalization(lease, deadlineAt: Date().addingTimeInterval(0.05))
    let started = Date()
    do {
        _ = try await store.proveFinalizedSource(
            lease,
            minimumBytes: 1,
            minimumDuration: 0.001
        )
        throw ValidationFailure.failed("Blocked deep validation ignored its deadline")
    } catch let error as IOSAudioProcessingDeadlineError {
        try require(error == .timedOut, "Blocked deep validation returned the wrong error")
    }
    try require(
        Date().timeIntervalSince(started) < 0.25,
        "Blocked deep validation held the store actor past its deadline"
    )
    let blockedSnapshot = try await store.snapshot(recordingID: lease.recordingID)
    try require(blockedSnapshot?.stage == .finalizing, "Late deep validation mutated the journal")

    let captureRoot = try makeRoot("capture-limit")
    let captureStore = MobileAudioProcessingStore(rootDirectory: captureRoot)
    let captureLease = try await captureStore.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(1)
    )
    try await captureStore.captureBecameReady(
        captureLease,
        deadlineAt: Date().addingTimeInterval(0.03)
    )
    try await Task.sleep(nanoseconds: 50_000_000)
    // The capture deadline stops new capture work, but bounded finalization receives a distinct
    // grace/deadline so the already captured container can still be closed safely.
    try await captureStore.beginFinalization(
        captureLease,
        deadlineAt: Date().addingTimeInterval(1)
    )
    let finalizing = try await captureStore.snapshot(recordingID: captureLease.recordingID)
    try require(finalizing?.stage == .finalizing, "Capture limit did not enter bounded finalization")
}

@MainActor
private func testRecorderGenerationRetirementAndLateClearCleanup() async throws {
    final class FakeRecorder {
        var starts = 0
        func start() { starts += 1 }
    }

    let sharedSession = IOSExclusiveResourceOwnership<FakeRecorder>()
    var sessionIsActive = false
    var deactivationCount = 0

    let slot = IOSRetirableResourceSlot(factory: FakeRecorder.init)
    let wedged = slot.current
    sharedSession.claim(wedged) {
        sessionIsActive = true
    }
    let wedgedID = ObjectIdentifier(wedged)
    let gate = DispatchSemaphore(value: 0)
    let blockedStop = Task.detached {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                gate.wait()
                continuation.resume(returning: wedgedID)
            }
        }
    }
    let replacement = slot.retire(ifCurrent: wedged)
    try require(replacement !== wedged, "Stalled recorder generation was not retired")
    sharedSession.claim(replacement) {
        sessionIsActive = true
    }
    replacement.start()
    try require(replacement.starts == 1, "Fresh recorder could not start after stalled stop")
    let lateOwnerDeactivated = sharedSession.relinquish(wedged) {
        deactivationCount += 1
        sessionIsActive = false
    }
    try require(!lateOwnerDeactivated, "Retired recorder retained global audio-session authority")
    try require(sessionIsActive, "Retired recorder deactivated the replacement audio session")
    try require(deactivationCount == 0, "Late recorder invoked process-global session teardown")
    gate.signal()
    _ = await blockedStop.value

    let root = try makeRoot("clear-late-writer")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await store.clearAll()
    // Simulates an abandoned native start returning after Clear and recreating its old path.
    try Data("late private audio".utf8).write(to: lease.sourceURL)
    try require(FileManager.default.fileExists(atPath: lease.sourceURL.path), "Late writer fixture missing")
    try await store.purgePayloadsIfDeleted(recordingID: lease.recordingID)
    try require(!FileManager.default.fileExists(atPath: lease.sourceURL.path), "Clear left late audio payload")
    let deleted = try await store.snapshot(recordingID: lease.recordingID)
    try require(deleted?.stage == .deleted, "Late cleanup changed Clear tombstone")
}

private func testManagedCaptureInterruptionFenceContract() throws {
    enum Failure: Equatable {
        case interrupted
        case audioServicesReset
    }

    struct ActiveCapture: Equatable {
        let attemptID: UUID
        let generation: UInt64
        let recorderID: Int
    }

    struct FenceHarness {
        var active: ActiveCapture?
        var failures: [(UUID, Failure)] = []

        mutating func terminalNotification(
            attemptID: UUID,
            generation: UInt64,
            recorderID: Int,
            failure: Failure
        ) {
            guard active == ActiveCapture(
                attemptID: attemptID,
                generation: generation,
                recorderID: recorderID
            ) else { return }
            active = nil
            failures.append((attemptID, failure))
        }
    }

    let firstAttempt = UUID()
    let secondAttempt = UUID()
    var harness = FenceHarness(
        active: ActiveCapture(attemptID: firstAttempt, generation: 1, recorderID: 101)
    )
    harness.terminalNotification(
        attemptID: firstAttempt,
        generation: 1,
        recorderID: 101,
        failure: .interrupted
    )
    try require(harness.active == nil, "Interruption did not terminalize active native capture")
    try require(
        harness.failures.count == 1 && harness.failures[0].1 == .interrupted,
        "Interruption did not report a known-incomplete capture failure"
    )

    harness.active = ActiveCapture(attemptID: secondAttempt, generation: 2, recorderID: 202)
    harness.terminalNotification(
        attemptID: firstAttempt,
        generation: 1,
        recorderID: 101,
        failure: .audioServicesReset
    )
    try require(
        harness.active?.attemptID == secondAttempt && harness.failures.count == 1,
        "Late audio-session callback terminalized a replacement generation"
    )

    harness.terminalNotification(
        attemptID: secondAttempt,
        generation: 2,
        recorderID: 202,
        failure: .audioServicesReset
    )
    try require(harness.active == nil, "Audio-services reset did not terminalize active capture")
    try require(
        harness.failures.count == 2 && harness.failures[1].1 == .audioServicesReset,
        "Audio-services reset did not report a known-incomplete capture failure"
    )
}

private func testDurabilityIntegrityRawRecoveryAndRetry() async throws {
    let root = try makeRoot("durability")
    let store = MobileAudioProcessingStore(rootDirectory: root)

    try await requireThrows(.deadlineExceeded) {
        _ = try await store.beginNewAttempt(
            recordingID: UUID(),
            deadlineAt: Date().addingTimeInterval(-1)
        )
    }

    let invalid = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await store.captureBecameReady(invalid, deadlineAt: Date().addingTimeInterval(30))
    try Data("not audio".utf8).write(to: invalid.sourceURL, options: .atomic)
    try await store.beginFinalization(invalid, deadlineAt: Date().addingTimeInterval(30))
    try await requireThrows(.sourceIncomplete) {
        _ = try await store.proveFinalizedSource(
            invalid,
            minimumBytes: 1,
            minimumDuration: 0.001
        )
    }
    try require(FileManager.default.fileExists(atPath: invalid.sourceURL.path), "Invalid source was deleted")
    try await store.markFailed(invalid, message: "Incomplete", integrity: .knownIncomplete)

    let (lease, finalized) = try await makeFinalizedAttempt(store: store, outputMode: "notes")
    let recognitionDeadline = Date().addingTimeInterval(30)
    _ = try await store.beginRecognition(lease, deadlineAt: recognitionDeadline)
    try await store.checkpointRecognitionPartial("first", lease: lease)
    try await store.checkpointRecognitionPartial("first second", lease: lease)
    try await requireThrows(.checkpointRegression) {
        try await store.checkpointRecognitionPartial("first", lease: lease)
    }
    try await requireThrows(.checkpointRegression) {
        try await store.checkpointRecognitionPartial("different", lease: lease)
    }
    let partialSnapshot = try await store.snapshot(recordingID: lease.recordingID)
    let partialText = try partialSnapshot?.partialTranscriptURL.map {
        try String(contentsOf: $0, encoding: .utf8)
    }
    try require(partialText == "first second", "Cumulative checkpoint duplicated text")
    try await store.checkpointRawTranscript("complete raw tail", lease: lease)
    try await store.cleanupStarted(lease)

    // Simulate termination during cleanup. Restart must resolve to raw and retain the final source.
    let restarted = MobileAudioProcessingStore(rootDirectory: root)
    _ = try await restarted.normalizeInterruptedAttempts()
    let recovered = try await restarted.snapshot(recordingID: lease.recordingID)
    try require(recovered?.stage == .succeeded, "Cleanup restart was not terminal")
    try require(recovered?.sourceIntegrity == .complete, "Complete source lost integrity")
    let recoveredText = try await restarted.recognizedText(for: lease.recordingID)
    try require(recoveredText == "complete raw tail", "Raw fallback was not recovered")
    try require(FileManager.default.fileExists(atPath: finalized.url.path), "Final source was deleted")

    let oldSourceData = try Data(contentsOf: finalized.url)
    let retry = try await restarted.beginRetry(
        recordingID: lease.recordingID,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try require(retry.sourceURL == finalized.url, "Retry changed canonical source")
    let retrySourceData = try Data(contentsOf: finalized.url)
    try require(retrySourceData == oldSourceData, "Retry rewrote canonical source")
    let preservedPriorText = try await restarted.recognizedText(for: lease.recordingID)
    try require(preservedPriorText == "complete raw tail", "Retry discarded the prior result")

    let (partialRetryLease, _) = try await makeFinalizedAttempt(store: restarted)
    _ = try await restarted.beginRecognition(
        partialRetryLease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await restarted.checkpointRecognitionPartial(
        "ordered partial checkpoint",
        lease: partialRetryLease
    )
    try await restarted.markFailed(
        partialRetryLease,
        message: "Later chunk failed",
        integrity: .complete
    )
    _ = try await restarted.beginRetry(
        recordingID: partialRetryLease.recordingID,
        deadlineAt: Date().addingTimeInterval(30)
    )
    let preservedPartial = try await restarted.recognizedText(
        for: partialRetryLease.recordingID
    )
    try require(preservedPartial == "ordered partial checkpoint", "Retry discarded partial text")

    // A second store instance clears globally. Every old lease must then lose.
    let retrySnapshot = try await restarted.snapshot(recordingID: retry.recordingID)
    if let previousResultURL = retrySnapshot?.previousResultURL {
        try FileManager.default.removeItem(at: previousResultURL)
    }
    let secondInstance = MobileAudioProcessingStore(rootDirectory: root)
    try await secondInstance.clearAll()
    try await requireThrows(.staleAttempt) {
        _ = try await restarted.beginRecognition(retry, deadlineAt: Date().addingTimeInterval(30))
    }
    let deleted = try await secondInstance.snapshot(recordingID: retry.recordingID)
    try require(deleted?.stage == .deleted, "Clear did not persist tombstone")
    try require(!FileManager.default.fileExists(atPath: finalized.url.path), "Clear left managed source")
}

private func testFullDecodeRejectsTruncation() async throws {
    let root = try makeRoot("truncated")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await store.captureBecameReady(lease, deadlineAt: Date().addingTimeInterval(30))
    try writeM4AAudioFixture(to: lease.sourceURL)
    let attributes = try FileManager.default.attributesOfItem(atPath: lease.sourceURL.path)
    let originalBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    try require(originalBytes > 2_000, "Audio fixture is unexpectedly small")
    let handle = try FileHandle(forWritingTo: lease.sourceURL)
    try handle.truncate(atOffset: originalBytes / 2)
    try handle.close()
    try await store.beginFinalization(lease, deadlineAt: Date().addingTimeInterval(30))
    try await requireThrows(.sourceIncomplete) {
        _ = try await store.proveFinalizedSource(
            lease,
            minimumBytes: 1,
            minimumDuration: 0.001
        )
    }
    try require(
        FileManager.default.fileExists(atPath: lease.sourceURL.path),
        "Truncated source was deleted"
    )
}

private func testPayloadBeforeManifestRecovery() async throws {
    let rawRoot = try makeRoot("orphan-raw")
    let rawStore = MobileAudioProcessingStore(rootDirectory: rawRoot)
    let (rawLease, _) = try await makeFinalizedAttempt(store: rawStore)
    _ = try await rawStore.beginRecognition(rawLease, deadlineAt: Date().addingTimeInterval(30))
    let rawURL = rawLease.sourceURL.deletingLastPathComponent().appendingPathComponent("raw.txt")
    try Data("durable raw tail".utf8).write(to: rawURL, options: .atomic)
    let rawRestart = MobileAudioProcessingStore(rootDirectory: rawRoot)
    _ = try await rawRestart.normalizeInterruptedAttempts()
    let recoveredRaw = try await rawRestart.recognizedText(for: rawLease.recordingID)
    try require(recoveredRaw == "durable raw tail", "Orphan raw checkpoint was not recovered")

    let resultRoot = try makeRoot("orphan-result")
    let resultStore = MobileAudioProcessingStore(rootDirectory: resultRoot)
    let (resultLease, _) = try await makeFinalizedAttempt(store: resultStore)
    _ = try await resultStore.beginRecognition(resultLease, deadlineAt: Date().addingTimeInterval(30))
    let resultDirectory = resultLease.sourceURL.deletingLastPathComponent()
    try Data("raw before cleanup".utf8).write(
        to: resultDirectory.appendingPathComponent("raw.txt"),
        options: .atomic
    )
    try Data("clean final text".utf8).write(
        to: resultDirectory.appendingPathComponent("result.txt"),
        options: .atomic
    )
    let resultRestart = MobileAudioProcessingStore(rootDirectory: resultRoot)
    _ = try await resultRestart.normalizeInterruptedAttempts()
    let recoveredResult = try await resultRestart.recognizedText(for: resultLease.recordingID)
    try require(recoveredResult == "clean final text", "Orphan final checkpoint was not recovered")

    let partialRoot = try makeRoot("orphan-partial")
    let partialStore = MobileAudioProcessingStore(rootDirectory: partialRoot)
    let (partialLease, _) = try await makeFinalizedAttempt(store: partialStore)
    _ = try await partialStore.beginRecognition(partialLease, deadlineAt: Date().addingTimeInterval(30))
    let partialURL = partialLease.sourceURL.deletingLastPathComponent()
        .appendingPathComponent("recognition-partial.txt")
    try Data("recoverable partial".utf8).write(to: partialURL, options: .atomic)
    let partialRestart = MobileAudioProcessingStore(rootDirectory: partialRoot)
    _ = try await partialRestart.normalizeInterruptedAttempts()
    let partialSnapshot = try await partialRestart.snapshot(recordingID: partialLease.recordingID)
    try require(partialSnapshot?.stage == .failed, "Partial interruption was not terminalized")
    try require(partialSnapshot?.partialTranscriptURL == partialURL, "Partial checkpoint was not exposed")
    let recoveredPartial = try await partialRestart.recognizedText(for: partialLease.recordingID)
    try require(recoveredPartial == "recoverable partial", "Partial checkpoint text was not readable after restart")
}

private func testDurableWriteFailureDoesNotAdvanceManifest() async throws {
    let root = try makeRoot("write-failure")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let (lease, _) = try await makeFinalizedAttempt(store: store)
    _ = try await store.beginRecognition(lease, deadlineAt: Date().addingTimeInterval(30))
    let directory = lease.sourceURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    try await requireThrows(.unavailable) {
        try await store.checkpointRecognitionPartial("must not commit", lease: lease)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let snapshot = try await store.snapshot(recordingID: lease.recordingID)
    try require(snapshot?.stage == .recognizing, "Manifest advanced after durable payload write failed")
    try require(snapshot?.partialTranscriptPath == nil, "Failed checkpoint was referenced")
}

private func testPathEscapeQuarantinesWithoutDeletingOutsideFile() async throws {
    let root = try makeRoot("path-escape")
    let outsideURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ios-audio-outside-\(UUID().uuidString).txt")
    let marker = Data("outside marker".utf8)
    try marker.write(to: outsideURL, options: .atomic)
    defer { try? FileManager.default.removeItem(at: outsideURL) }

    let store = MobileAudioProcessingStore(rootDirectory: root)
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    let manifestURL = lease.sourceURL.deletingLastPathComponent().appendingPathComponent("attempt.json")
    var manifest = try requireDictionary(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)))
    manifest["sourcePath"] = outsideURL.path
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL, options: .atomic)

    let restarted = MobileAudioProcessingStore(rootDirectory: root)
    try await requireThrows(.quarantined) {
        _ = try await restarted.normalizeInterruptedAttempts()
    }
    let preservedOutsideData = try Data(contentsOf: outsideURL)
    try require(preservedOutsideData == marker, "Path escape modified an outside file")
}

private func requireDictionary(_ value: Any) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
        throw ValidationFailure.failed("Expected JSON object")
    }
    return dictionary
}

private func testCrashAfterMoveAndLateCallbackFence() async throws {
    let root = try makeRoot("move")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await store.captureBecameReady(lease, deadlineAt: Date().addingTimeInterval(30))
    try writeValidAudio(to: lease.sourceURL)
    try await store.beginFinalization(lease, deadlineAt: Date().addingTimeInterval(30))
    let proof = try await store.proveFinalizedSource(
        lease,
        minimumBytes: 1,
        minimumDuration: 0.001
    )
    try await store.checkpointFinalizedSourceProof(lease, proof: proof)
    let finalURL = lease.sourceURL.deletingLastPathComponent().appendingPathComponent("source.m4a")
    try FileManager.default.moveItem(at: lease.sourceURL, to: finalURL)

    let restarted = MobileAudioProcessingStore(rootDirectory: root)
    _ = try await restarted.normalizeInterruptedAttempts()
    let snapshot = try await restarted.snapshot(recordingID: lease.recordingID)
    try require(snapshot?.stage == .failed, "Interrupted promoted source was not terminal")
    try require(snapshot?.sourceIntegrity == .complete, "Moved final was not recovered as complete")
    try require(snapshot?.sourceURL == finalURL, "Recovered source path is wrong")

    try await requireThrows(.invalidTransition) {
        try await restarted.checkpointRecognitionPartial("late callback", lease: lease)
    }
}

private func testTerminalSuccessCannotBeDowngradedByDeliveryFailure() async throws {
    let root = try makeRoot("terminal-delivery")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let (lease, _) = try await makeFinalizedAttempt(store: store)
    _ = try await store.beginRecognition(lease, deadlineAt: Date().addingTimeInterval(30))
    try await store.checkpointRawTranscript("durable recognized text", lease: lease)
    try await store.cleanupStarted(lease)
    _ = try await store.checkpointFinalText("durable final text", lease: lease)
    try await store.markSucceeded(lease)

    // Keyboard delivery happens after terminal commit. A stale/failed delivery may try to cancel,
    // but it must never downgrade or erase the already durable success.
    try await requireThrows(.invalidTransition) {
        try await store.markCancelled(lease, message: "Keyboard delivery failed")
    }
    let snapshot = try await store.snapshot(recordingID: lease.recordingID)
    try require(snapshot?.stage == .succeeded, "Delivery failure downgraded terminal success")
    let text = try await store.recognizedText(for: lease.recordingID)
    try require(text == "durable final text", "Delivery failure lost durable text")
    let firstAccountingLease = try await store.beginUsageAccounting(recordingID: lease.recordingID)
    let duplicateAccountingLease = try await store.beginUsageAccounting(recordingID: lease.recordingID)
    try require(firstAccountingLease?.wordCount == 3, "Successful result was not leased for usage")
    try require(duplicateAccountingLease == nil, "Usage accounting was leased concurrently")
    let accountingAfterClaim = try await store.beginUsageAccounting(
        recordingID: lease.recordingID
    )
    try require(
        firstAccountingLease != nil && accountingAfterClaim == nil,
        "Durably claimed usage accounting was sent twice"
    )

    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Whishpermate/WhisperMateIOS/ContentView.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    guard let delivery = source.range(of: "KeyboardDictationHandoff.publishHostResult") else {
        throw ValidationFailure.failed("iOS keyboard delivery path is missing")
    }
    let beforeDelivery = source[..<delivery.lowerBound]
    try require(
        beforeDelivery.range(
            of: "try await processingStore.markSucceeded(lease)",
            options: .backwards
        ) != nil,
        "iOS keyboard delivery occurs before durable terminal success"
    )
    try require(
        beforeDelivery.range(
            of: "try await replaceHistoryRecording(recording, in: historyManager)",
            options: .backwards
        ) != nil,
        "iOS keyboard delivery occurs before durable History publication"
    )

    let rawRoot = try makeRoot("cleanup-failure-fallback")
    let rawStore = MobileAudioProcessingStore(rootDirectory: rawRoot)
    let (rawLease, _) = try await makeFinalizedAttempt(store: rawStore)
    _ = try await rawStore.beginRecognition(rawLease, deadlineAt: Date().addingTimeInterval(30))
    try await rawStore.checkpointRawTranscript("raw survives cleanup failure", lease: rawLease)
    try await rawStore.cleanupStarted(rawLease)
    try await rawStore.markFailed(
        rawLease,
        message: "Cleanup timed out",
        integrity: .complete
    )
    let rawSnapshot = try await rawStore.snapshot(recordingID: rawLease.recordingID)
    try require(rawSnapshot?.stage == .succeeded, "Cleanup failure hid complete raw text")
    let rawText = try await rawStore.recognizedText(for: rawLease.recordingID)
    try require(rawText == "raw survives cleanup failure", "Cleanup failure did not retain raw text")
    guard let rawAccountingLease = try await rawStore.beginUsageAccounting(
        recordingID: rawLease.recordingID
    ) else { throw ValidationFailure.failed("Raw fallback skipped durable usage accounting") }
    try require(rawAccountingLease.wordCount == 4, "Raw fallback accounting count is wrong")
    let rawRetryAccountingLease = try await rawStore.beginUsageAccounting(
        recordingID: rawLease.recordingID
    )
    try require(
        rawRetryAccountingLease == nil,
        "A failed non-idempotent usage delivery was made retryable"
    )
    let rawAccountingRestart = MobileAudioProcessingStore(rootDirectory: rawRoot)
    _ = try await rawAccountingRestart.normalizeInterruptedAttempts()
    let rawRestartAccountingLease = try await rawAccountingRestart.beginUsageAccounting(
        recordingID: rawLease.recordingID
    )
    try require(
        rawRestartAccountingLease == nil,
        "Restart replayed an already claimed usage operation"
    )

    let resultRoot = try makeRoot("result-cancel-fallback")
    let resultStore = MobileAudioProcessingStore(rootDirectory: resultRoot)
    let (resultLease, _) = try await makeFinalizedAttempt(store: resultStore)
    _ = try await resultStore.beginRecognition(resultLease, deadlineAt: Date().addingTimeInterval(30))
    try await resultStore.checkpointRawTranscript("raw", lease: resultLease)
    _ = try await resultStore.checkpointFinalText("complete result", lease: resultLease)
    try await resultStore.markCancelled(resultLease, message: "Late cancellation")
    let resultSnapshot = try await resultStore.snapshot(recordingID: resultLease.recordingID)
    try require(resultSnapshot?.stage == .succeeded, "Late cancellation hid complete result")
    let resultText = try await resultStore.recognizedText(for: resultLease.recordingID)
    try require(resultText == "complete result", "Late cancellation lost complete result")
    let resultAccountingLease = try await resultStore.beginUsageAccounting(
        recordingID: resultLease.recordingID
    )
    try require(resultAccountingLease?.wordCount == 2, "Cancel fallback skipped usage accounting")

    let optionsRoot = try makeRoot("restart-options")
    let optionsStore = MobileAudioProcessingStore(rootDirectory: optionsRoot)
    let (optionsLease, _) = try await makeFinalizedAttempt(
        store: optionsStore,
        outputMode: "meetings",
        transcriptionOptions: TranscriptionOptions(diarization: true)
    )
    try await optionsStore.markFailed(optionsLease, message: "Retry later", integrity: .complete)
    let optionsRestart = MobileAudioProcessingStore(rootDirectory: optionsRoot)
    let optionsSnapshot = try await optionsRestart.snapshot(recordingID: optionsLease.recordingID)
    try require(
        optionsSnapshot?.transcriptionOptions?.diarization == true,
        "Restart lost captured meeting transcription options"
    )
}

private func testUsageClaimIsAtMostOnceAcrossRestartDeleteAndClear() async throws {
    let expiryRoot = try makeRoot("usage-at-most-once")
    let expiryStore = MobileAudioProcessingStore(rootDirectory: expiryRoot)
    let (expiryLease, _) = try await makeFinalizedAttempt(store: expiryStore)
    _ = try await expiryStore.beginRecognition(
        expiryLease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await expiryStore.checkpointRawTranscript("one two three", lease: expiryLease)
    _ = try await expiryStore.checkpointFinalText("one two three", lease: expiryLease)
    try await expiryStore.markSucceeded(expiryLease)

    let claimTime = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let firstClaim = try await expiryStore.beginUsageAccounting(
        recordingID: expiryLease.recordingID,
        now: claimTime
    )
    try require(firstClaim?.wordCount == 3, "Usage accounting did not issue its first claim")
    let nearFormerExpiry = try await expiryStore.beginUsageAccounting(
        recordingID: expiryLease.recordingID,
        now: claimTime.addingTimeInterval(599)
    )
    let afterFormerExpiry = try await expiryStore.beginUsageAccounting(
        recordingID: expiryLease.recordingID,
        now: claimTime.addingTimeInterval(601)
    )
    try require(
        nearFormerExpiry == nil && afterFormerExpiry == nil,
        "Time made a claimed non-idempotent usage operation retryable"
    )
    let expiryRestart = MobileAudioProcessingStore(rootDirectory: expiryRoot)
    _ = try await expiryRestart.normalizeInterruptedAttempts()
    let restartClaim = try await expiryRestart.beginUsageAccounting(
        recordingID: expiryLease.recordingID
    )
    try require(restartClaim == nil, "Restart replayed a claimed usage operation")

    let deleteRoot = try makeRoot("usage-delete")
    let deleteStore = MobileAudioProcessingStore(rootDirectory: deleteRoot)
    let (deleteLease, _) = try await makeFinalizedAttempt(store: deleteStore)
    _ = try await deleteStore.beginRecognition(
        deleteLease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await deleteStore.checkpointRawTranscript("count survives delete", lease: deleteLease)
    _ = try await deleteStore.checkpointFinalText("count survives delete", lease: deleteLease)
    try await deleteStore.markSucceeded(deleteLease)
    let deleteClaim = try await deleteStore.beginUsageAccounting(
        recordingID: deleteLease.recordingID
    )
    try require(deleteClaim?.wordCount == 3, "Delete fixture did not claim usage")
    try await deleteStore.tombstone(recordingID: deleteLease.recordingID)
    try require(
        !FileManager.default.fileExists(atPath: deleteLease.sourceURL.path),
        "Delete retained the private audio payload"
    )
    let deleteRestart = MobileAudioProcessingStore(rootDirectory: deleteRoot)
    _ = try await deleteRestart.normalizeInterruptedAttempts()
    let deletedClaim = try await deleteRestart.beginUsageAccounting(
        recordingID: deleteLease.recordingID
    )
    try require(deletedClaim == nil, "Delete/restart replayed a claimed usage operation")

    let clearRoot = try makeRoot("usage-clear")
    let clearStore = MobileAudioProcessingStore(rootDirectory: clearRoot)
    let (clearLease, _) = try await makeFinalizedAttempt(store: clearStore)
    _ = try await clearStore.beginRecognition(
        clearLease,
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await clearStore.checkpointRawTranscript("clear keeps accounting", lease: clearLease)
    _ = try await clearStore.checkpointFinalText("clear keeps accounting", lease: clearLease)
    try await clearStore.markSucceeded(clearLease)
    let clearClaim = try await clearStore.beginUsageAccounting(
        recordingID: clearLease.recordingID
    )
    try require(clearClaim?.wordCount == 3, "Clear fixture did not claim usage")
    try await clearStore.clearAll()
    let clearRestart = MobileAudioProcessingStore(rootDirectory: clearRoot)
    _ = try await clearRestart.normalizeInterruptedAttempts()
    let clearedClaim = try await clearRestart.beginUsageAccounting(
        recordingID: clearLease.recordingID
    )
    try require(clearedClaim == nil, "Clear/restart replayed a claimed usage operation")
}

private func testLegacyHistoryDeletionIntentSurvivesCrash() async throws {
    let legacyAppRoot = try makeRoot("legacy-delete-crash")
    let legacyDeleteRoot = legacyAppRoot.appendingPathComponent(
        "MobileAudioProcessing",
        isDirectory: true
    )
    let legacyAudioDirectory = legacyAppRoot.appendingPathComponent(
        "Recordings",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: legacyAudioDirectory,
        withIntermediateDirectories: true
    )
    let legacyRecordingID = UUID()
    let legacyAudioURL = legacyAudioDirectory.appendingPathComponent(
        "\(legacyRecordingID.uuidString).m4a"
    )
    try Data("legacy private audio".utf8).write(to: legacyAudioURL, options: .atomic)
    let crashingLegacyStore = MobileAudioProcessingStore(
        rootDirectory: legacyDeleteRoot,
        afterHistoryDeletionIntentPersisted: { throw InjectedDeletionCrash() }
    )
    try await requireInjectedDeletionCrash {
        try await crashingLegacyStore.tombstone(recordingID: legacyRecordingID)
    }
    try require(
        FileManager.default.fileExists(atPath: legacyAudioURL.path),
        "Crash injection did not occur before legacy audio deletion"
    )
    let legacyRestart = MobileAudioProcessingStore(rootDirectory: legacyDeleteRoot)
    _ = try await legacyRestart.normalizeInterruptedAttempts()
    let legacySnapshot = try await legacyRestart.snapshot(recordingID: legacyRecordingID)
    try require(
        legacySnapshot?.stage == .deleted,
        "Crash before legacy history mutation lost the durable Delete intent"
    )
    try HistoryManager.removeCanonicalAudioIfPresent(
        recordingID: legacyRecordingID,
        recordedAudioURL: legacyAudioURL,
        audioDirectory: legacyAudioDirectory
    )
    try require(
        !FileManager.default.fileExists(atPath: legacyAudioURL.path),
        "Launch deletion reconciliation orphaned legacy private audio"
    )

    let unrelatedURL = legacyAppRoot.appendingPathComponent("unrelated.m4a")
    try Data("must survive".utf8).write(to: unrelatedURL, options: .atomic)
    try HistoryManager.removeCanonicalAudioIfPresent(
        recordingID: UUID(),
        recordedAudioURL: unrelatedURL,
        audioDirectory: legacyAudioDirectory
    )
    try require(
        FileManager.default.fileExists(atPath: unrelatedURL.path),
        "A tampered History URL deleted an unrelated regular file"
    )

    let symlinkRecordingID = UUID()
    let symlinkURL = legacyAudioDirectory.appendingPathComponent(
        "\(symlinkRecordingID.uuidString).m4a"
    )
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: unrelatedURL)
    try HistoryManager.removeCanonicalAudioIfPresent(
        recordingID: symlinkRecordingID,
        recordedAudioURL: symlinkURL,
        audioDirectory: legacyAudioDirectory
    )
    try require(
        FileManager.default.fileExists(atPath: symlinkURL.path)
            && FileManager.default.fileExists(atPath: unrelatedURL.path),
        "A symlinked History audio path was followed or removed"
    )

    let escapedDirectoryTarget = legacyAppRoot.appendingPathComponent(
        "escaped-recordings",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: escapedDirectoryTarget,
        withIntermediateDirectories: true
    )
    let escapedRecordingID = UUID()
    let escapedTargetURL = escapedDirectoryTarget.appendingPathComponent(
        "\(escapedRecordingID.uuidString).m4a"
    )
    try Data("must also survive".utf8).write(to: escapedTargetURL, options: .atomic)
    let symlinkedAudioDirectory = legacyAppRoot.appendingPathComponent(
        "linked-recordings",
        isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
        at: symlinkedAudioDirectory,
        withDestinationURL: escapedDirectoryTarget
    )
    try HistoryManager.removeCanonicalAudioIfPresent(
        recordingID: escapedRecordingID,
        recordedAudioURL: symlinkedAudioDirectory.appendingPathComponent(
            "\(escapedRecordingID.uuidString).m4a"
        ),
        audioDirectory: symlinkedAudioDirectory
    )
    try require(
        FileManager.default.fileExists(atPath: escapedTargetURL.path),
        "A symlinked History audio directory escaped its ownership boundary"
    )
    try await requireThrows(.recordingIDAlreadyExists) {
        _ = try await legacyRestart.beginNewAttempt(
            recordingID: legacyRecordingID,
            deadlineAt: Date().addingTimeInterval(30)
        )
    }

    let activeDeleteRoot = try makeRoot("active-delete-crash")
    let crashingActiveStore = MobileAudioProcessingStore(
        rootDirectory: activeDeleteRoot,
        afterHistoryDeletionIntentPersisted: { throw InjectedDeletionCrash() }
    )
    let activeLease = try await crashingActiveStore.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    try await requireInjectedDeletionCrash {
        try await crashingActiveStore.tombstone(recordingID: activeLease.recordingID)
    }
    try await requireThrows(.staleAttempt) {
        try await crashingActiveStore.captureBecameReady(
            activeLease,
            deadlineAt: Date().addingTimeInterval(30)
        )
    }
    let activeRestart = MobileAudioProcessingStore(rootDirectory: activeDeleteRoot)
    _ = try await activeRestart.normalizeInterruptedAttempts()
    let activeSnapshot = try await activeRestart.snapshot(recordingID: activeLease.recordingID)
    try require(
        activeSnapshot?.stage == .deleted,
        "Crash after Delete intent allowed an active attempt to survive"
    )

    let legacyClearRoot = try makeRoot("legacy-clear-crash")
    let legacyClearIDs = [UUID(), UUID()]
    let crashingClearStore = MobileAudioProcessingStore(
        rootDirectory: legacyClearRoot,
        afterHistoryDeletionIntentPersisted: { throw InjectedDeletionCrash() }
    )
    try await requireInjectedDeletionCrash {
        try await crashingClearStore.clearAll(recordingIDs: legacyClearIDs)
    }
    let clearRestart = MobileAudioProcessingStore(rootDirectory: legacyClearRoot)
    _ = try await clearRestart.normalizeInterruptedAttempts()
    let clearedSnapshots = try await clearRestart.allSnapshots()
    let clearedIDs = Set(
        clearedSnapshots
            .filter { $0.stage == .deleted }
            .map(\.recordingID)
    )
    try require(
        clearedIDs.isSuperset(of: legacyClearIDs),
        "Crash before legacy history mutation lost one or more durable Clear intents"
    )
}

private func testCorruptionQuarantinesWithoutOverwrite() async throws {
    let root = try makeRoot("corrupt")
    let store = MobileAudioProcessingStore(rootDirectory: root)
    let lease = try await store.beginNewAttempt(
        recordingID: UUID(),
        deadlineAt: Date().addingTimeInterval(30)
    )
    let marker = Data("source marker".utf8)
    try marker.write(to: lease.sourceURL, options: .atomic)
    let manifest = lease.sourceURL.deletingLastPathComponent().appendingPathComponent("attempt.json")
    try Data("{broken".utf8).write(to: manifest, options: .atomic)

    let restarted = MobileAudioProcessingStore(rootDirectory: root)
    try await requireThrows(.quarantined) {
        _ = try await restarted.normalizeInterruptedAttempts()
    }
    let preservedMarker = try Data(contentsOf: lease.sourceURL)
    try require(preservedMarker == marker, "Quarantine modified source")
    try await requireThrows(.quarantined) {
        _ = try await restarted.beginNewAttempt(
            recordingID: UUID(),
            deadlineAt: Date().addingTimeInterval(30)
        )
    }
}

private func testHistoryDoesNotResurrectEvictedStoreAttempts() async throws {
    let root = try makeRoot("history-101-restarts")
    let initialStore = MobileAudioProcessingStore(rootDirectory: root)
    var expectedIDs = Set<UUID>()

    for _ in 0 ..< 101 {
        let recordingID = UUID()
        expectedIDs.insert(recordingID)
        let lease = try await initialStore.beginNewAttempt(
            recordingID: recordingID,
            deadlineAt: Date().addingTimeInterval(30)
        )
        try await initialStore.markFailed(
            lease,
            message: "Processing did not finish.",
            integrity: .unfinalized
        )
    }

    func reconcile(
        snapshots: [MobileAudioProcessingStore.Snapshot],
        history: inout [UUID]
    ) {
        for snapshot in snapshots where snapshot.stage == .deleted {
            history.removeAll { $0 == snapshot.recordingID }
        }
        let existing = Set(history)
        for snapshot in snapshots
        where snapshot.stage == .succeeded
            || snapshot.stage == .failed
            || snapshot.stage == .cancelled
        {
            guard FileManager.default.fileExists(atPath: snapshot.sourcePath),
                  !existing.contains(snapshot.recordingID)
            else { continue }
            history.insert(snapshot.recordingID, at: 0)
        }
    }

    var history: [UUID] = []
    reconcile(snapshots: try await initialStore.allSnapshots(), history: &history)
    try require(history.count == 101, "History silently discarded a durable recording")
    try require(Set(history) == expectedIDs, "Initial history reconciliation lost an attempt")
    let originalOrder = history

    let firstRestart = MobileAudioProcessingStore(rootDirectory: root)
    _ = try await firstRestart.normalizeInterruptedAttempts()
    reconcile(snapshots: try await firstRestart.allSnapshots(), history: &history)
    try require(history == originalOrder, "First restart reordered or resurrected history entries")

    guard let deletedID = history.last else {
        throw ValidationFailure.failed("History fixture was unexpectedly empty")
    }
    try await firstRestart.tombstone(recordingID: deletedID)
    history.removeAll { $0 == deletedID }
    let orderAfterDelete = history

    let secondRestart = MobileAudioProcessingStore(rootDirectory: root)
    _ = try await secondRestart.normalizeInterruptedAttempts()
    reconcile(snapshots: try await secondRestart.allSnapshots(), history: &history)
    try require(history == orderAfterDelete, "Second restart changed stable history order")
    try require(!history.contains(deletedID), "Deleted recording was resurrected")
}

private func testIOSCallerRecoveryContracts() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    for relativePath in [
        "Whishpermate/WhisperMateIOS/ContentView.swift",
        "Whishpermate/WhisperMateIOS/RecordingSheetView.swift",
    ] {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        guard let capture = source.range(of: "RequestSnapshot.capture("),
              let allocation = source.range(of: "beginNewAttempt(")
        else { throw ValidationFailure.failed("Missing immutable request/allocation in \(relativePath)") }
        try require(capture.lowerBound < allocation.lowerBound, "Settings captured after allocation in \(relativePath)")
        try require(source.contains("request: request"), "Attempt did not reuse captured request in \(relativePath)")
        try require(source.contains("scheduleCaptureDeadline("), "Capture has no max timer in \(relativePath)")
        try require(source.contains("proveFinalizedSource("), "Final source is not deeply proved in \(relativePath)")
        try require(source.contains("checkpointFinalizedSourceProof("), "Proof is not checkpointed in \(relativePath)")
        try require(source.contains("retire(ifCurrent:") || source.contains("retireAudioRecorderIfCurrent("), "Stalled recorder is not retired in \(relativePath)")
        try require(source.contains("managedAttemptFailure"), "Post-first-buffer failure is not observed in \(relativePath)")
        try require(source.contains("purgePayloadsIfDeleted"), "Late Clear payload is not purged in \(relativePath)")
        try require(source.contains("deactivateAudioSession: false"), "Retired recorder can deactivate the replacement session in \(relativePath)")
        try require(source.contains("OpenAIError"), "Actionable cloud errors are collapsed in \(relativePath)")
        try require(source.contains("AppleAudioHTTPRecovery.Failure"), "HTTP recovery failures are collapsed in \(relativePath)")
    }

    let recorderSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Services/AudioRecorder.swift"
        ),
        encoding: .utf8
    )
    try require(recorderSource.contains("audioSessionOwnership.claim"), "Recorder does not claim global audio-session ownership")
    try require(recorderSource.contains("audioSessionOwnership.relinquish"), "Late recorder is not fenced from global session teardown")
    try require(
        recorderSource.contains("AVAudioSession.interruptionNotification"),
        "Managed recorder does not observe native audio interruptions"
    )
    try require(
        recorderSource.contains("AVAudioSession.mediaServicesWereResetNotification"),
        "Managed recorder does not observe audio-services resets"
    )
    guard let terminalFailureStart = recorderSource.range(
        of: "private func terminallyFailManagedCaptureOnQueue("
    )?.lowerBound,
        let terminalFailureEnd = recorderSource.range(
            of: "public func audioRecorderEncodeErrorDidOccur",
            range: terminalFailureStart ..< recorderSource.endIndex
        )?.lowerBound
    else { throw ValidationFailure.failed("Managed native capture terminal-failure path is missing") }
    let terminalFailure = String(recorderSource[terminalFailureStart ..< terminalFailureEnd])
    try require(
        terminalFailure.contains("activeAttemptID == attemptID")
            && terminalFailure.contains("activeManagedCaptureGeneration == generation")
            && terminalFailure.contains("ObjectIdentifier(recorder) == recorderID"),
        "Native capture failure is not fenced by exact attempt, generation, and recorder"
    )
    try require(
        terminalFailure.contains("stopRecordingOnQueue(deactivateAudioSession: true)"),
        "Interrupted capture can leave a valid prefix eligible for submission"
    )
    try require(
        terminalFailure.contains("managedAttemptFailure = failure"),
        "Interrupted capture does not report through the managed failure callback"
    )
    try require(
        recorderSource.contains("removeManagedAudioSessionObserversOnQueue()"),
        "Managed recorder does not remove native audio-session observers"
    )

    let historySource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Storage/HistoryManager.swift"
        ),
        encoding: .utf8
    )
    try require(!historySource.contains("prefix(maxRecordings)"), "History silently evicts durable store metadata")
    try require(!historySource.contains("maxRecordings"), "History still has an uncoordinated recording cap")

    let sheet = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateIOS/RecordingSheetView.swift"
        ),
        encoding: .utf8
    )
    try require(sheet.contains("beginRetry(\n                    recordingID: recording.id"), "Retry does not reuse recording ID")

    let content = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateIOS/ContentView.swift"
        ),
        encoding: .utf8
    )
    guard let appearStart = content.range(of: ".onAppear {")?.lowerBound,
          let appearEnd = content.range(of: ".onDisappear {", range: appearStart ..< content.endIndex)?.lowerBound
    else { throw ValidationFailure.failed("ContentView launch sequence is missing") }
    let launch = String(content[appearStart ..< appearEnd])
    guard let mobileRecovery = launch.range(of: "await recoverMobileAudioProcessingIfNeeded()"),
          let keyboardRecovery = launch.range(of: "recoverKeyboardHostLaunchIfNeeded()")
    else { throw ValidationFailure.failed("Host launch does not recover both audio journals") }
    try require(
        mobileRecovery.lowerBound < keyboardRecovery.lowerBound,
        "Keyboard commands can start before mobile audio recovery finishes"
    )
    try require(
        content.contains("private enum MobileAudioHostLaunchRecoveryGate"),
        "Mobile recovery can rerun and terminalize a live attempt"
    )
    try require(
        content.contains("guard requireMobileAudioRecoveryReady() else { return }"),
        "Normal iOS recording actions are not gated on launch recovery"
    )
    try require(
        content.contains("guard mobileAudioRecoveryReady else {"),
        "Keyboard recording can start before mobile audio recovery"
    )
    try require(
        content.contains("private func reconcileActiveKeyboardAttemptIfNeeded()"),
        "Host does not reconcile a durable keyboard cancel after command expiry"
    )
    try require(
        content.contains("func cancelAndReconcile("),
        "Keyboard cancellation does not reconcile a completed raw transcript"
    )
    try require(
        content.contains("MobileAudioUsageAccounting.flush("),
        "iOS completion paths do not perform durably claimed usage accounting"
    )
    try require(
        content.contains("let usageRecordingIDs = snapshots.compactMap")
            && content.contains("guard snapshot.stage == .succeeded,")
            && !content.contains("snapshot.stage == .deleted,\n                   snapshot.usageAccountingWordCount"),
        "Launch recovery can claim usage for text that Delete/Clear removed from History"
    )
    guard let deletedHistoryLoop = content.range(
        of: "for snapshot in snapshots where snapshot.stage == .deleted"
    ),
    let deletedHistoryLoopEnd = content.range(
        of: "for snapshot in snapshots\n            where snapshot.stage == .succeeded",
        range: deletedHistoryLoop.upperBound ..< content.endIndex
    )
    else { throw ValidationFailure.failed("Launch history deletion reconciliation is missing") }
    let deletedHistoryReconciliation = content[
        deletedHistoryLoop.lowerBound ..< deletedHistoryLoopEnd.lowerBound
    ]
    guard let audioRemoval = deletedHistoryReconciliation.range(
        of: "historyManager.removeAudioFileIfPresent(for: recording)"
    ),
    let rowRemoval = deletedHistoryReconciliation.range(
        of: "historyManager.deleteRecording(recording)"
    )
    else { throw ValidationFailure.failed("Launch deletion does not remove audio and history") }
    try require(
        audioRemoval.lowerBound < rowRemoval.lowerBound,
        "Launch deletion forgets the History row before removing its audio"
    )
    try require(
        content.contains("reset(keepAudioBridgeAlive: false)"),
        "Terminal keyboard completion can leave microphone monitoring active"
    )
    try require(
        content.contains("transcriptionOptions: startOptions"),
        "iOS attempt journal does not capture transcription options"
    )
    try require(
        sheet.contains(
            "private func handleCancel() {\n        cancelAndReconcileActiveAttempt(dismissAfterStart: true)"
        ) && sheet.contains(
            "private func cancelActiveAttemptOnDisappear() {\n        cancelAndReconcileActiveAttempt(dismissAfterStart: false)"
        ),
        "Explicit and swipe dismissal do not share one cancellation reconciler"
    )
    guard let reconciliationStart = sheet.range(
        of: "private func cancelAndReconcileActiveAttempt("
    )?.lowerBound,
    let reconciliationEnd = sheet.range(
        of: "private func userMessage(for error: Error)",
        range: reconciliationStart ..< sheet.endIndex
    )?.lowerBound
    else { throw ValidationFailure.failed("Sheet cancellation reconciler is missing") }
    let cancellationReconciler = String(sheet[reconciliationStart ..< reconciliationEnd])
    try require(
        cancellationReconciler.contains("snapshot?.stage == .succeeded")
            && cancellationReconciler.contains("replaceHistoryRecording(recording)"),
        "Sheet cancellation hides a raw transcript that already completed"
    )
    try require(
        sheet.contains("MobileAudioUsageAccounting.flush("),
        "Sheet raw fallback skips durably claimed usage accounting"
    )
    try require(
        sheet.contains("pendingAttemptID = retryAttemptID")
            && sheet.contains("pendingAttemptID = attemptID")
            && sheet.contains("cancelledPendingAttemptID")
            && sheet.contains("_ = audioRecorderSlot.retire(ifCurrent: pendingAttemptRecorder)")
            && sheet.contains("guard pendingAttemptID == retryAttemptID")
            && sheet.contains("guard pendingAttemptID == attemptID"),
        "Sheet cancellation is not sticky while new/retry allocation is suspended"
    )
    try require(
        sheet.contains("currentRecoverySnapshot = nil"),
        "Successful retry leaves the stale Try Again state visible"
    )
    try require(
        content.contains("private var pendingAttemptID: UUID?")
            && content.contains("cancelledPendingAttemptID")
            && content.contains("guard pendingAttemptID == attemptID"),
        "Inline/keyboard cancellation is not sticky before lease allocation returns"
    )

    let storeSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Services/MobileAudioProcessingStore.swift"
        ),
        encoding: .utf8
    )
    try require(
        storeSource.contains("trustedAppGroupContainerDirectory()")
            && storeSource.contains("MobileAudioProcessingStore(unavailable: ())")
            && !storeSource.contains("defaultRootDirectory()"),
        "Production mobile audio store still falls back outside the App Group"
    )
    try require(
        storeSource.contains("public final class ChunkWorkspace")
            && storeSource.contains("Darwin.unlinkat")
            && storeSource.contains("sweepChunkWorkspacesLocked()"),
        "Attempt-owned derived audio lacks descriptor cleanup or launch sweep"
    )

    try require(
        !historySource.contains("temporaryDirectory")
            && historySource.contains("public func upsertRecording")
            && historySource.contains("async throws")
            && historySource.contains("deletedRecordingIDs"),
        "History still falls back privately or hides durable mutation failures"
    )

    let usageSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Services/MobileAudioUsageAccounting.swift"
        ),
        encoding: .utf8
    )
    guard let durableHistoryCheck = usageSource.range(of: "historyManager.containsDurably"),
          let usageClaim = usageSource.range(of: "store.beginUsageAccounting")
    else { throw ValidationFailure.failed("History-gated usage accounting is missing") }
    try require(
        durableHistoryCheck.lowerBound < usageClaim.lowerBound,
        "Usage is irrevocably claimed before durable History publication"
    )

    let sharedTranscriptionSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Services/SharedTranscriptionService.swift"
        ),
        encoding: .utf8
    )
    try require(
        sharedTranscriptionSource.contains("if cloud.isOneStage")
            && sharedTranscriptionSource.contains("rawTranscript: transcript")
            && sharedTranscriptionSource.contains("cleanedTranscript: transcript"),
        "One-request final response is not retained as recoverable client text"
    )

    let openAIClientSource = try String(
        contentsOf: repositoryRoot.appendingPathComponent(
            "Whishpermate/WhisperMateShared/Networking/OpenAIClient.swift"
        ),
        encoding: .utf8
    )
    try require(
        openAIClientSource.contains("IOSNativeCallbackOperation.run")
            && openAIClientSource.contains("workspace.allocateOutputURL()")
            && openAIClientSource.contains("#if os(iOS)")
            && openAIClientSource.contains(
                "throw MobileAudioProcessingStore.StoreError.unavailable"
            ),
        "Production native chunk export can stall or spill to an iOS temp directory"
    )
}

@main
private struct IOSAudioRecoveryValidator {
    static func main() async {
        do {
            print("testDeadlineReturnsWithoutWaitingForLateWork")
            try await testDeadlineReturnsWithoutWaitingForLateWork()
            print("testStalledNativeExportReturnsTerminalAndFencesLateCompletion")
            try await testStalledNativeExportReturnsTerminalAndFencesLateCompletion()
            print("testStickyCancellationBeforeNewAndRetryAllocationReturns")
            try await testStickyCancellationBeforeNewAndRetryAllocationReturns()
            print("testAttemptOwnedChunkWorkspaceCrashSweepAndSymlinkFence")
            try await testAttemptOwnedChunkWorkspaceCrashSweepAndSymlinkFence()
            print("testRevisionedHistoryMultiSceneTombstoneAndTruthfulFailure")
            try await testRevisionedHistoryMultiSceneTombstoneAndTruthfulFailure()
            print("testBoundedDeepValidationAndCaptureLimitFinalization")
            try await testBoundedDeepValidationAndCaptureLimitFinalization()
            print("testRecorderGenerationRetirementAndLateClearCleanup")
            try await testRecorderGenerationRetirementAndLateClearCleanup()
            print("testManagedCaptureInterruptionFenceContract")
            try testManagedCaptureInterruptionFenceContract()
            print("testDurabilityIntegrityRawRecoveryAndRetry")
            try await testDurabilityIntegrityRawRecoveryAndRetry()
            print("testFullDecodeRejectsTruncation")
            try await testFullDecodeRejectsTruncation()
            print("testPayloadBeforeManifestRecovery")
            try await testPayloadBeforeManifestRecovery()
            print("testDurableWriteFailureDoesNotAdvanceManifest")
            try await testDurableWriteFailureDoesNotAdvanceManifest()
            print("testPathEscapeQuarantinesWithoutDeletingOutsideFile")
            try await testPathEscapeQuarantinesWithoutDeletingOutsideFile()
            print("testCrashAfterMoveAndLateCallbackFence")
            try await testCrashAfterMoveAndLateCallbackFence()
            print("testTerminalSuccessCannotBeDowngradedByDeliveryFailure")
            try await testTerminalSuccessCannotBeDowngradedByDeliveryFailure()
            print("testUsageClaimIsAtMostOnceAcrossRestartDeleteAndClear")
            try await testUsageClaimIsAtMostOnceAcrossRestartDeleteAndClear()
            print("testLegacyHistoryDeletionIntentSurvivesCrash")
            try await testLegacyHistoryDeletionIntentSurvivesCrash()
            print("testCorruptionQuarantinesWithoutOverwrite")
            try await testCorruptionQuarantinesWithoutOverwrite()
            print("testHistoryDoesNotResurrectEvictedStoreAttempts")
            try await testHistoryDoesNotResurrectEvictedStoreAttempts()
            print("testIOSCallerRecoveryContracts")
            try testIOSCallerRecoveryContracts()
            print("iOS audio recovery validation passed")
        } catch {
            fputs("iOS audio recovery validation failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
