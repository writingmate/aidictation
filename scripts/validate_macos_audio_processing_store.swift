import Foundation
import AVFoundation
import CryptoKit
import Darwin

private enum ValidationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date()) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class BlockingOperationHook: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: MacAudioProcessingStore.TestOperation
    private(set) var invocationCount = 0
    let release = DispatchSemaphore(value: 0)

    init(operation: MacAudioProcessingStore.TestOperation = .deepAudioValidation) {
        self.operation = operation
    }

    func before(_ operation: MacAudioProcessingStore.TestOperation) throws {
        guard operation == self.operation else { return }
        lock.lock()
        invocationCount += 1
        lock.unlock()
        release.wait()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocationCount
    }
}

private final class StoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MacAudioProcessingStore?

    func set(_ store: MacAudioProcessingStore) {
        lock.lock()
        value = store
        lock.unlock()
    }

    func get() -> MacAudioProcessingStore? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw ValidationFailure.assertion(message) }
}

private func waitSynchronously(
    for semaphore: DispatchSemaphore,
    timeout: DispatchTime
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: timeout)
}

private func requireStoreError(
    _ expected: MacAudioProcessingStore.StoreError,
    _ message: String,
    operation: () async throws -> Void
) async throws {
    do {
        try await operation()
        throw ValidationFailure.assertion("\(message): operation unexpectedly succeeded")
    } catch let error as MacAudioProcessingStore.StoreError {
        try require(error == expected, "\(message): expected \(expected), got \(error)")
    }
}

private func temporaryRoot(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacAudioProcessingStoreTests", isDirectory: true)
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeBytes(_ bytes: [UInt8], to url: URL) throws {
    try Data(bytes).write(to: url, options: .atomic)
}

private func writeValidAudio(to url: URL, frameCount: AVAudioFrameCount = 1_600) throws {
    try? FileManager.default.removeItem(at: url)
    let sampleRate = 44_100.0
    guard let format = AVAudioFormat(
        standardFormatWithSampleRate: sampleRate,
        channels: 1
    ) else {
        throw ValidationFailure.assertion("could not create a valid audio fixture")
    }
    let waveURL = url.deletingLastPathComponent()
        .appendingPathComponent("fixture-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: waveURL) }
    do {
        let audioFile = try AVAudioFile(forWriting: waveURL, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw ValidationFailure.assertion("could not create an audio buffer")
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                channel[index] = Float(index % 32) / 64.0
            }
        }
        try audioFile.write(from: buffer)
    }
    // AVAudioFile closes its container when released. A WAV fixture is used so
    // this validator does not depend on an AAC encoder being available on CI;
    // the store validates the container contents, not the filename extension.
    try Data(contentsOf: waveURL).write(to: url, options: .atomic)
}

private func futureDeadline() -> Date {
    Date().addingTimeInterval(60)
}

private func closedProof(
    for url: URL,
    attemptID: UUID
) throws -> MacAudioProcessingStore.ClosedAudioProof {
    let byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let frameCount = try AVAudioFile(forReading: url).length
    let digest = SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
    return MacAudioProcessingStore.ClosedAudioProof(
        attemptID: attemptID,
        expectedByteCount: Int64(byteCount),
        expectedFrameCount: Int64(frameCount),
        expectedSHA256: digest,
        nativeCloseAttestation: nil
    )
}

private func onlyRecord(in store: MacAudioProcessingStore) async throws -> MacAudioProcessingStore.Record {
    let records = await store.view().records
    try require(records.count == 1, "expected exactly one journal record")
    return records[0]
}

private func finishValidatedAudio(
    in store: MacAudioProcessingStore,
    mutation: MacAudioProcessingStore.Mutation
) async throws -> MacAudioProcessingStore.Mutation {
    let proof = try await proveNativeClosedAudio(
        in: store,
        lease: mutation.lease
    )
    let checkpoint = try await store.checkpointClosedAudio(mutation.lease, proof: proof)
    return try await store.finishFinalization(checkpoint.lease, proof: proof)
}

private func proveNativeClosedAudio(
    in store: MacAudioProcessingStore,
    lease: MacAudioProcessingStore.Lease
) async throws -> MacAudioProcessingStore.ClosedAudioProof {
    try await store.proveClosedAudio(
        lease,
        nativeCloseAttestation: .init(
            attemptID: lease.attemptID,
            processID: MacAudioProcessingStore.currentProcessID
        )
    )
}

private func beginRecognizing(
    in store: MacAudioProcessingStore,
    recordingID: UUID = UUID()
) async throws -> MacAudioProcessingStore.Mutation {
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(
        mutation.lease,
        captureDeadline: futureDeadline()
    )
    mutation = try await store.beginFinalization(
        mutation.lease,
        deadline: futureDeadline()
    )
    mutation = try await finishValidatedAudio(in: store, mutation: mutation)
    return try await store.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )
}

private func testOldAttemptAndRevisionRejection() async throws {
    let root = try temporaryRoot("old-attempt")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    let captureAttemptID = UUID()
    try await requireStoreError(.invalidDeadline, "an expired attempt must not start") {
        _ = try await store.prepare(
            recordingID: recordingID,
            attemptID: captureAttemptID,
            deadline: Date().addingTimeInterval(-1)
        )
    }
    let prepared = try await store.prepare(
        recordingID: recordingID,
        attemptID: captureAttemptID,
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))

    let recording = try await store.markRecording(
        prepared.lease,
        captureDeadline: futureDeadline()
    )
    try await requireStoreError(.staleLease, "an old revision must not finalize") {
        _ = try await store.beginFinalization(prepared.lease, deadline: futureDeadline())
    }

    let finalizing = try await store.beginFinalization(
        recording.lease,
        deadline: futureDeadline()
    )
    let ready = try await finishValidatedAudio(in: store, mutation: finalizing)
    let recognitionAttemptID = UUID()
    let recognizing = try await store.beginRecognition(
        recordingID: recordingID,
        attemptID: recognitionAttemptID,
        expectedRevision: ready.record.revision,
        deadline: futureDeadline()
    )

    try await requireStoreError(.staleLease, "a completed capture attempt must not overwrite recognition") {
        _ = try await store.fail(ready.lease, message: "late capture callback")
    }

    let raw = try await store.markRawResultReady(recognizing.lease, rawText: "raw transcript")
    let cleaning = try await store.beginCleanup(raw.lease)
    let result = try await store.finishCleanup(cleaning.lease, cleanedText: "complete transcript")
    _ = try await store.markSucceeded(result.lease)
    let stored = try await onlyRecord(in: store)
    try require(stored.stage == .succeeded, "the current recognition attempt should succeed")
    try require(stored.resultText == "complete transcript", "success must retain the durable result")
    try require(stored.attemptID == recognitionAttemptID, "recording and attempt identities must remain separate")
}

private func testConcurrentCASHasOneWinner() async throws {
    let root = try temporaryRoot("concurrent-cas")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    let prepared = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))

    let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for _ in 0..<100 {
            group.addTask {
                do {
                    _ = try await store.markRecording(
                        prepared.lease,
                        captureDeadline: futureDeadline()
                    )
                    return true
                } catch {
                    return false
                }
            }
        }

        var count = 0
        for await won in group where won {
            count += 1
        }
        return count
    }

    try require(winners == 1, "a compare-and-swap lease must have exactly one winner")
    let stored = try await onlyRecord(in: store)
    try require(stored.stage == .recording, "the winning transition should be durable")
}

private func testClearGenerationAndNewRecording() async throws {
    let root = try temporaryRoot("clear-generation")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MacAudioProcessingStore(rootDirectory: root)
    let oldRecordingID = UUID()
    let old = try await store.prepare(
        recordingID: oldRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: oldRecordingID))
    let before = await store.view()
    let cleanup = try await store.clearAll()
    try require(cleanup.completed, "clear should remove known sources")
    let after = await store.view()
    try require(after.clearGeneration == before.clearGeneration + 1, "clear must advance the persisted generation")
    try require(after.records[0].stage == .deleted, "clear must tombstone before cleanup")

    do {
        _ = try await store.markRecording(old.lease, captureDeadline: futureDeadline())
        throw ValidationFailure.assertion("a pre-clear lease unexpectedly mutated state")
    } catch let error as MacAudioProcessingStore.StoreError {
        try require(
            error == .staleLease || error == .recordingDeleted,
            "a pre-clear lease should be rejected"
        )
    }

    let newRecordingID = UUID()
    let newAttemptID = UUID()
    let newRecording = try await store.prepare(
        recordingID: newRecordingID,
        attemptID: newAttemptID,
        deadline: futureDeadline()
    )
    try require(
        newRecording.record.clearGeneration == after.clearGeneration,
        "a recording created after clear should use the new generation"
    )
    try require(
        FileManager.default.fileExists(atPath: store.partialURL(for: newRecordingID).path),
        "a new recording should be allowed after clear"
    )
}

private func testTombstoneBeatsLateCallbackAndRestart() async throws {
    let root = try temporaryRoot("tombstone")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    let prepared = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    let cleanup = try await store.tombstone(recordingID: recordingID)
    try require(cleanup.completed, "tombstone cleanup should complete")

    try await requireStoreError(.recordingDeleted, "a late callback must lose to a tombstone") {
        _ = try await store.markRecording(prepared.lease, captureDeadline: futureDeadline())
    }

    // Simulate native work ignoring cancellation and recreating a source after
    // the tombstone. Healthy restart cleanup must enforce the tombstone again.
    try writeValidAudio(to: store.finalURL(for: recordingID))
    _ = MacAudioProcessingStore(rootDirectory: root)
    try require(
        !FileManager.default.fileExists(atPath: store.finalURL(for: recordingID).path),
        "restart should remove a source recreated by a late callback"
    )
}

private func testRestartStages() async throws {
    // Preparing and recording attempts become terminal failures while retaining
    // any partial source.
    for targetStage in [MacAudioProcessingStore.Stage.preparing, .recording] {
        let root = try temporaryRoot("restart-\(targetStage.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = MacAudioProcessingStore(rootDirectory: root)
        let recordingID = UUID()
        let prepared = try await first.prepare(
            recordingID: recordingID,
            attemptID: UUID(),
            deadline: futureDeadline()
        )
        try writeValidAudio(to: first.partialURL(for: recordingID))
        if targetStage == .recording {
            _ = try await first.markRecording(
                prepared.lease,
                captureDeadline: futureDeadline()
            )
        }

        let restarted = MacAudioProcessingStore(rootDirectory: root)
        let recovered = try await onlyRecord(in: restarted)
        try require(recovered.stage == .failed, "\(targetStage.rawValue) must recover as failed")
        try require(recovered.source == .partial, "interrupted capture source must be retained")
    }

    // Active recognition becomes a terminal failure with the final source and
    // any ordered checkpoint retained.
    let root = try temporaryRoot("restart-recognizing")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await first.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: first.partialURL(for: recordingID))
    mutation = try await first.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await first.beginFinalization(mutation.lease, deadline: futureDeadline())
    mutation = try await finishValidatedAudio(in: first, mutation: mutation)
    let recognizing = try await first.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )
    _ = try await first.checkpointRecognition(
        recognizing.lease,
        partialText: "first completed leaf"
    )

    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let recovered = try await onlyRecord(in: restarted)
    try require(recovered.stage == .failed, "interrupted recognition should become terminal")
    try require(recovered.rawText == "first completed leaf", "restart must retain the ordered checkpoint")
    try require(recovered.source == .final, "restart must retain the final source")
    try require(
        FileManager.default.fileExists(atPath: restarted.finalURL(for: recordingID).path),
        "restart recovery must not delete complete audio"
    )
}

private func testTimeoutAndResultRecoveryPreserveSource() async throws {
    let timeoutRoot = try temporaryRoot("timeout-preserves-source")
    defer { try? FileManager.default.removeItem(at: timeoutRoot) }
    let timeoutStore = MacAudioProcessingStore(rootDirectory: timeoutRoot)
    let timeoutRecordingID = UUID()
    var mutation = try await timeoutStore.prepare(
        recordingID: timeoutRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: timeoutStore.partialURL(for: timeoutRecordingID))
    mutation = try await timeoutStore.markRecording(
        mutation.lease,
        captureDeadline: futureDeadline()
    )
    mutation = try await timeoutStore.beginFinalization(
        mutation.lease,
        deadline: futureDeadline()
    )
    mutation = try await finishValidatedAudio(in: timeoutStore, mutation: mutation)
    mutation = try await timeoutStore.beginRecognition(
        recordingID: timeoutRecordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )
    let failed = try await timeoutStore.timeOut(mutation.lease)
    try require(failed.record.stage == .failed, "a timeout should be terminal")
    try require(failed.record.source == .final, "a timeout should retain the complete source")
    try require(
        FileManager.default.fileExists(atPath: timeoutStore.finalURL(for: timeoutRecordingID).path),
        "a timeout must not delete the only recoverable source"
    )

    let resultRoot = try temporaryRoot("result-restart")
    defer { try? FileManager.default.removeItem(at: resultRoot) }
    let first = MacAudioProcessingStore(rootDirectory: resultRoot)
    let resultRecordingID = UUID()
    mutation = try await first.prepare(
        recordingID: resultRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: first.partialURL(for: resultRecordingID))
    mutation = try await first.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await first.beginFinalization(mutation.lease, deadline: futureDeadline())
    mutation = try await finishValidatedAudio(in: first, mutation: mutation)
    mutation = try await first.beginRecognition(
        recordingID: resultRecordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )
    mutation = try await first.markRawResultReady(mutation.lease, rawText: "durable raw result")
    _ = try await first.beginCleanup(mutation.lease)

    let restarted = MacAudioProcessingStore(rootDirectory: resultRoot)
    let recovered = try await onlyRecord(in: restarted)
    try require(
        recovered.stage == .resultReady,
        "a complete raw result must wait for durable History before success"
    )
    try require(recovered.resultText == "durable raw result", "restart must retain the complete raw result")
    let secondRestart = MacAudioProcessingStore(rootDirectory: resultRoot)
    let stillPendingHistory = try await onlyRecord(in: secondRestart)
    try require(
        stillPendingHistory.stage == .resultReady,
        "restart must not bypass the durable History publication gate"
    )
}

private func testRenameJournalCrashReconciliation() async throws {
    let root = try temporaryRoot("rename-crash")
    defer { try? FileManager.default.removeItem(at: root) }

    let first = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await first.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: first.partialURL(for: recordingID))
    mutation = try await first.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await first.beginFinalization(mutation.lease, deadline: futureDeadline())
    let proof = try await proveNativeClosedAudio(
        in: first,
        lease: mutation.lease
    )
    _ = try await first.checkpointClosedAudio(mutation.lease, proof: proof)

    // This is the precise crash window in finishFinalization: the atomic move
    // completed but the final journal write did not.
    try FileManager.default.moveItem(
        at: first.partialURL(for: recordingID),
        to: first.finalURL(for: recordingID)
    )

    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let recovered = try await onlyRecord(in: restarted)
    try require(recovered.stage == .failed, "restart should terminalize an interrupted proven source rename")
    try require(recovered.source == .final, "reconciled source should be final")

    let restartedAgain = MacAudioProcessingStore(rootDirectory: root)
    let stable = try await onlyRecord(in: restartedAgain)
    try require(stable.stage == .failed, "restart reconciliation should be idempotent")
    try require(stable.revision == recovered.revision, "idempotent restart must not create another revision")
}

private func testTwoStoreClearBeatsStaleWriter() async throws {
    let root = try temporaryRoot("two-store-clear")
    defer { try? FileManager.default.removeItem(at: root) }

    let primary = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    let prepared = try await primary.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: primary.partialURL(for: recordingID))

    let staleStore = MacAudioProcessingStore(
        rootDirectory: root,
        recoverInterruptedWork: false
    )
    let staleRecord = try await onlyRecord(in: staleStore)
    let staleLease = MacAudioProcessingStore.Lease(
        recordingID: staleRecord.recordingID,
        attemptID: staleRecord.attemptID,
        clearGeneration: staleRecord.clearGeneration,
        revision: staleRecord.revision
    )
    try require(staleLease == prepared.lease, "both stores should initially observe the same lease")

    _ = try await primary.clearAll()
    try await requireStoreError(.staleLease, "a stale store must not overwrite Clear") {
        _ = try await staleStore.markRecording(staleLease, captureDeadline: futureDeadline())
    }

    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let durable = try await onlyRecord(in: restarted)
    try require(durable.stage == .deleted, "Clear must remain durable after a stale write")
    try require(
        !FileManager.default.fileExists(atPath: restarted.partialURL(for: recordingID).path),
        "Clear should still own source deletion"
    )

    let newRecordingID = UUID()
    let newPrepared = try await primary.prepare(
        recordingID: newRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: primary.partialURL(for: newRecordingID))
    let staleDeleteStore = MacAudioProcessingStore(
        rootDirectory: root,
        recoverInterruptedWork: false
    )
    let staleDeleteRecord = await staleDeleteStore.record(for: newRecordingID)
    try require(staleDeleteRecord != nil, "the second store should observe the new recording")
    _ = try await primary.tombstone(recordingID: newRecordingID)
    try await requireStoreError(.staleLease, "a stale store must not overwrite Delete") {
        _ = try await staleDeleteStore.markRecording(
            newPrepared.lease,
            captureDeadline: futureDeadline()
        )
    }
    let afterDelete = MacAudioProcessingStore(rootDirectory: root)
    let deleted = await afterDelete.record(for: newRecordingID)
    try require(deleted?.stage == .deleted, "Delete must remain durable after a stale write")
}

private func testInvalidAudioNeverBecomesReady() async throws {
    enum Fixture: String, CaseIterable {
        case invalidHeader
        case truncatedContainer
        case zeroFrames
    }

    for fixture in Fixture.allCases {
        let root = try temporaryRoot("invalid-audio-\(fixture.rawValue)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacAudioProcessingStore(rootDirectory: root)
        let recordingID = UUID()
        var mutation = try await store.prepare(
            recordingID: recordingID,
            attemptID: UUID(),
            deadline: futureDeadline()
        )
        let sourceURL = store.partialURL(for: recordingID)
        switch fixture {
        case .invalidHeader:
            try writeBytes([0x4E, 0x4F, 0x54, 0x41, 0x55, 0x44, 0x49, 0x4F], to: sourceURL)
        case .truncatedContainer:
            try writeValidAudio(to: sourceURL)
        case .zeroFrames:
            break
        }
        mutation = try await store.markRecording(
            mutation.lease,
            captureDeadline: futureDeadline()
        )
        mutation = try await store.beginFinalization(
            mutation.lease,
            deadline: futureDeadline()
        )
        if fixture == .truncatedContainer {
            let proof = try await proveNativeClosedAudio(
                in: store,
                lease: mutation.lease
            )
            let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let handle = try FileHandle(forWritingTo: sourceURL)
            try handle.truncate(atOffset: UInt64(max(1, size / 2)))
            try handle.close()
            try await requireStoreError(.invalidAudio, "truncation after close proof must not become ready") {
                _ = try await store.checkpointClosedAudio(mutation.lease, proof: proof)
            }
        } else {
            try await requireStoreError(.invalidAudio, "\(fixture.rawValue) must not become ready") {
                _ = try await proveNativeClosedAudio(
                    in: store,
                    lease: mutation.lease
                )
            }
        }
        _ = try await store.fail(
            mutation.lease,
            message: "The recording did not finish saving correctly. Your file was preserved."
        )
        let failed = try await onlyRecord(in: store)
        try require(failed.stage == .failed, "invalid audio should reach a terminal failed state")
        try require(
            FileManager.default.fileExists(atPath: sourceURL.path),
            "invalid audio should be preserved for recovery"
        )
    }

    let root = try temporaryRoot("close-proof")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await store.beginFinalization(mutation.lease, deadline: futureDeadline())
    try await requireStoreError(
        .writerCloseUnknown,
        "same-process finalization read audio without exact native close"
    ) {
        _ = try await store.proveClosedAudio(mutation.lease)
    }
    let actualProof = try await proveNativeClosedAudio(
        in: store,
        lease: mutation.lease
    )
    try await requireStoreError(.staleLease, "another attempt cannot attest that the writer closed") {
        _ = try await store.checkpointClosedAudio(
            mutation.lease,
            proof: MacAudioProcessingStore.ClosedAudioProof(
                attemptID: UUID(),
                expectedByteCount: actualProof.expectedByteCount,
                expectedFrameCount: actualProof.expectedFrameCount,
                expectedSHA256: actualProof.expectedSHA256,
                nativeCloseAttestation: nil
            )
        )
    }
    let checkpoint = try await store.checkpointClosedAudio(mutation.lease, proof: actualProof)
    let ready = try await store.finishFinalization(checkpoint.lease, proof: actualProof)
    try require(ready.record.audioIntegrity != nil, "closed valid audio should persist an integrity proof")
}

private func testLateCloseCanBeSalvagedSafely() async throws {
    let root = try temporaryRoot("late-close-salvage")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstProcessID = UUID()
    let first = MacAudioProcessingStore(
        rootDirectory: root,
        processID: firstProcessID
    )
    let recordingID = UUID()
    var mutation = try await first.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: first.partialURL(for: recordingID))
    mutation = try await first.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await first.beginFinalization(mutation.lease, deadline: futureDeadline())
    let failed = try await first.timeOut(mutation.lease)
    try require(failed.record.stage == .failed, "finalization timeout should be terminal")
    try require(failed.record.source == .partial, "timed-out finalization should keep the partial")

    // Restart establishes that the detached writer can no longer mutate this
    // process's source. The failed row stays visible until explicit proof and a
    // fresh salvage lease promote it.
    let restarted = MacAudioProcessingStore(
        rootDirectory: root,
        processID: UUID()
    )
    let recovered = try await onlyRecord(in: restarted)
    let proof = try await restarted.proveRecoverablePartial(
        recordingID: recordingID,
        expectedRevision: recovered.revision,
        expectedClearGeneration: recovered.clearGeneration,
        deadline: futureDeadline()
    )
    let checkpoint = try await restarted.checkpointRecoverablePartial(
        recordingID: recordingID,
        expectedRevision: recovered.revision,
        expectedClearGeneration: recovered.clearGeneration,
        proof: proof,
        deadline: futureDeadline()
    )
    let salvageAttemptID = UUID()
    let ready = try await restarted.salvageFinalizedPartial(
        recordingID: recordingID,
        salvageAttemptID: salvageAttemptID,
        expectedRevision: checkpoint.record.revision,
        expectedClearGeneration: checkpoint.record.clearGeneration,
        deadline: futureDeadline(),
        proof: proof
    )
    try require(ready.record.stage == .readyForRecognition, "a proven closed partial should be salvageable")
    try require(ready.record.attemptID == salvageAttemptID, "salvage must use a fresh attempt owner")
    try require(
        FileManager.default.fileExists(atPath: restarted.finalURL(for: recordingID).path),
        "salvage should atomically promote the recoverable source"
    )
    try require(
        !FileManager.default.fileExists(atPath: restarted.partialURL(for: recordingID).path),
        "salvage should leave no ambiguous partial source"
    )
}

private func testSameProcessRetryRequiresExactNativeClose() async throws {
    let root = try temporaryRoot("same-process-native-close")
    defer { try? FileManager.default.removeItem(at: root) }
    let processID = UUID()
    let store = MacAudioProcessingStore(
        rootDirectory: root,
        processID: processID
    )
    let recordingID = UUID()
    let captureAttemptID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: captureAttemptID,
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(
        mutation.lease,
        captureDeadline: futureDeadline()
    )
    mutation = try await store.beginFinalization(
        mutation.lease,
        deadline: futureDeadline()
    )
    let failed = try await store.timeOut(mutation.lease)

    try await requireStoreError(
        .writerCloseUnknown,
        "same-process retry read a partial without native close"
    ) {
        _ = try await store.proveRecoverablePartial(
            recordingID: recordingID,
            expectedRevision: failed.record.revision,
            expectedClearGeneration: failed.record.clearGeneration,
            deadline: futureDeadline()
        )
    }
    try require(
        !FileManager.default.fileExists(atPath: store.finalURL(for: recordingID).path),
        "retry-before-close promoted the partial source"
    )

    let attestation = MacAudioProcessingStore.NativeWriterCloseAttestation(
        attemptID: captureAttemptID,
        processID: processID
    )
    let proof = try await store.proveRecoverablePartial(
        recordingID: recordingID,
        expectedRevision: failed.record.revision,
        expectedClearGeneration: failed.record.clearGeneration,
        deadline: futureDeadline(),
        nativeCloseAttestation: attestation
    )
    let checkpoint = try await store.checkpointRecoverablePartial(
        recordingID: recordingID,
        expectedRevision: failed.record.revision,
        expectedClearGeneration: failed.record.clearGeneration,
        proof: proof,
        deadline: futureDeadline(),
        nativeCloseAttestation: attestation
    )
    let ready = try await store.salvageFinalizedPartial(
        recordingID: recordingID,
        salvageAttemptID: UUID(),
        expectedRevision: checkpoint.record.revision,
        expectedClearGeneration: checkpoint.record.clearGeneration,
        deadline: futureDeadline(),
        proof: proof
    )
    try require(
        ready.record.stage == .readyForRecognition,
        "exact late native close did not make the same recording retryable"
    )
}

private func testDeleteAndClearFenceLateCloseCheckpoint() async throws {
    for clearsAll in [false, true] {
        let root = try temporaryRoot(clearsAll ? "late-close-clear" : "late-close-delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let processID = UUID()
        let store = MacAudioProcessingStore(
            rootDirectory: root,
            processID: processID
        )
        let recordingID = UUID()
        let captureAttemptID = UUID()
        var mutation = try await store.prepare(
            recordingID: recordingID,
            attemptID: captureAttemptID,
            deadline: futureDeadline()
        )
        try writeValidAudio(to: store.partialURL(for: recordingID))
        mutation = try await store.markRecording(
            mutation.lease,
            captureDeadline: futureDeadline()
        )
        mutation = try await store.beginFinalization(
            mutation.lease,
            deadline: futureDeadline()
        )
        let failed = try await store.timeOut(mutation.lease)
        let attestation = MacAudioProcessingStore.NativeWriterCloseAttestation(
            attemptID: captureAttemptID,
            processID: processID
        )
        let proof = try await store.proveRecoverablePartial(
            recordingID: recordingID,
            expectedRevision: failed.record.revision,
            expectedClearGeneration: failed.record.clearGeneration,
            deadline: futureDeadline(),
            nativeCloseAttestation: attestation
        )

        if clearsAll {
            _ = try await store.clearAll()
        } else {
            _ = try await store.tombstone(recordingID: recordingID)
        }
        do {
            _ = try await store.checkpointRecoverablePartial(
                recordingID: recordingID,
                expectedRevision: failed.record.revision,
                expectedClearGeneration: failed.record.clearGeneration,
                proof: proof,
                deadline: futureDeadline(),
                nativeCloseAttestation: attestation
            )
            throw ValidationFailure.assertion(
                "late close checkpoint recreated a deleted recording"
            )
        } catch let error as MacAudioProcessingStore.StoreError {
            try require(
                error == .recordingDeleted || error == .staleLease,
                "late close after Delete/Clear returned \(error)"
            )
        }
        let deleted = await store.record(for: recordingID)
        try require(deleted?.stage == .deleted, "Delete/Clear tombstone was not durable")
        try require(
            !FileManager.default.fileExists(atPath: store.finalURL(for: recordingID).path),
            "late close promoted audio after Delete/Clear"
        )
    }
}

private func testHeldLockAndStalledPersistenceAreBounded() async throws {
    let heldLockRoot = try temporaryRoot("held-journal-lock")
    defer { try? FileManager.default.removeItem(at: heldLockRoot) }
    let heldLockStore = MacAudioProcessingStore(
        rootDirectory: heldLockRoot,
        testHooks: .init(persistenceTimeout: 0.12)
    )
    let lockURL = heldLockStore.journalURL.deletingLastPathComponent()
        .appendingPathComponent(".journal.lock")
    let descriptor = Darwin.open(
        lockURL.path,
        O_CREAT | O_RDWR,
        S_IRUSR | S_IWUSR
    )
    try require(descriptor >= 0, "validator could not open the macOS journal lock")
    defer {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
    try require(
        flock(descriptor, LOCK_EX) == 0,
        "validator could not hold the macOS journal lock"
    )
    let restartStartedAt = Date()
    let lockedRestart = MacAudioProcessingStore(
        rootDirectory: heldLockRoot,
        testHooks: .init(persistenceTimeout: 0.12)
    )
    try require(
        Date().timeIntervalSince(restartStartedAt) < 0.75,
        "journal initialization waited indefinitely for a held flock"
    )
    guard case .readOnly = await lockedRestart.view().health else {
        throw ValidationFailure.assertion(
            "initialization did not fail closed when its lock deadline expired"
        )
    }
    let lockStartedAt = Date()
    try await requireStoreError(
        .persistenceBusy,
        "held flock did not fail within its persistence deadline"
    ) {
        _ = try await heldLockStore.prepare(
            recordingID: UUID(),
            attemptID: UUID(),
            deadline: futureDeadline()
        )
    }
    try require(
        Date().timeIntervalSince(lockStartedAt) < 0.75,
        "held flock blocked the store past its bounded deadline"
    )
    guard case .healthy = await heldLockStore.view().health else {
        throw ValidationFailure.assertion(
            "a lock timeout with no disk mutation unnecessarily poisoned the store"
        )
    }
    _ = flock(descriptor, LOCK_UN)

    let stalledRoot = try temporaryRoot("stalled-journal-persistence")
    defer { try? FileManager.default.removeItem(at: stalledRoot) }
    let blocker = BlockingOperationHook(operation: .journalDirectorySync)
    let stalledStore = MacAudioProcessingStore(
        rootDirectory: stalledRoot,
        testHooks: .init(
            before: { operation in try blocker.before(operation) },
            persistenceTimeout: 0.12
        )
    )
    let stalledRecordingID = UUID()
    let stallStartedAt = Date()
    try await requireStoreError(
        .persistenceTimedOut,
        "stalled journal fsync did not return at its deadline"
    ) {
        _ = try await stalledStore.prepare(
            recordingID: stalledRecordingID,
            attemptID: UUID(),
            deadline: futureDeadline()
        )
    }
    try require(
        Date().timeIntervalSince(stallStartedAt) < 0.75,
        "stalled journal fsync kept the caller processing"
    )
    guard case .readOnly = await stalledStore.view().health else {
        throw ValidationFailure.assertion(
            "ambiguous late persistence did not quarantine stale in-memory CAS state"
        )
    }
    try await requireStoreError(
        .readOnly,
        "a new attempt raced an ambiguous late journal commit"
    ) {
        _ = try await stalledStore.prepare(
            recordingID: UUID(),
            attemptID: UUID(),
            deadline: futureDeadline()
        )
    }
    try await requireStoreError(
        .readOnly,
        "Delete raced an ambiguous late journal commit"
    ) {
        _ = try await stalledStore.tombstone(recordingID: stalledRecordingID)
    }
    try await requireStoreError(
        .readOnly,
        "Clear raced an ambiguous late journal commit"
    ) {
        _ = try await stalledStore.clearAll()
    }

    blocker.release.signal()
    try await Task.sleep(nanoseconds: 150_000_000)
    let restarted = MacAudioProcessingStore(
        rootDirectory: stalledRoot,
        processID: UUID()
    )
    let recovered = await restarted.record(for: stalledRecordingID)
    try require(
        recovered?.stage == .failed,
        "restart did not terminalize a late committed preparing row"
    )
}

private func testTombstoneCleanupIsBounded() async throws {
    let root = try temporaryRoot("bounded-tombstone-cleanup")
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = BlockingOperationHook(operation: .sourceRemoval)
    let store = MacAudioProcessingStore(
        rootDirectory: root,
        testHooks: .init(
            before: { operation in try blocker.before(operation) },
            persistenceTimeout: 0.12
        )
    )
    let firstRecordingID = UUID()
    _ = try await store.prepare(
        recordingID: firstRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )

    let deleteStartedAt = Date()
    let deletion = try await store.tombstone(recordingID: firstRecordingID)
    try require(
        Date().timeIntervalSince(deleteStartedAt) < 0.75,
        "Delete waited indefinitely for a stalled source unlink"
    )
    try require(
        !deletion.completed,
        "timed-out cleanup claimed every source was removed"
    )
    let deletedRecord = await store.record(for: firstRecordingID)
    try require(
        deletedRecord?.stage == .deleted,
        "Delete cleanup timeout lost its durable tombstone"
    )

    // Cleanup has its own serial worker. A stuck unlink must not occupy the
    // journal worker or prevent a newer, differently identified attempt.
    let secondRecordingID = UUID()
    _ = try await store.prepare(
        recordingID: secondRecordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    let clearStartedAt = Date()
    let clearing = try await store.clearAll()
    try require(
        Date().timeIntervalSince(clearStartedAt) < 0.75,
        "Clear waited behind a previously stalled source cleanup"
    )
    try require(
        !clearing.completed,
        "queued cleanup timeout claimed every source was removed"
    )
    let clearedView = await store.view()
    try require(
        clearedView.records.allSatisfy { $0.stage == .deleted },
        "Clear cleanup timeout reopened mutation ownership"
    )

    blocker.release.signal()
    try await Task.sleep(nanoseconds: 100_000_000)
    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let retried = await restarted.retryDeletedSourceCleanup()
    try require(retried.completed, "restart could not retry tombstoned source cleanup")
    try require(
        !FileManager.default.fileExists(
            atPath: restarted.partialURL(for: firstRecordingID).path
        )
            && !FileManager.default.fileExists(
                atPath: restarted.partialURL(for: secondRecordingID).path
            ),
        "restart cleanup left tombstoned partial audio behind"
    )
}

private func testSourceInspectionIsBounded() async throws {
    let root = try temporaryRoot("bounded-source-inspection")
    defer { try? FileManager.default.removeItem(at: root) }
    let blocker = BlockingOperationHook(operation: .sourceInspection)
    let store = MacAudioProcessingStore(
        rootDirectory: root,
        testHooks: .init(
            before: { operation in
                if blocker.count == 0 {
                    try blocker.before(operation)
                }
            },
            persistenceTimeout: 0.12
        )
    )
    let recordingID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(
        mutation.lease,
        captureDeadline: futureDeadline()
    )
    mutation = try await store.beginFinalization(
        mutation.lease,
        deadline: futureDeadline()
    )

    let startedAt = Date()
    try await requireStoreError(
        .persistenceTimedOut,
        "a pre-commit source stat did not honor its deadline"
    ) {
        _ = try await proveNativeClosedAudio(in: store, lease: mutation.lease)
    }
    try require(
        Date().timeIntervalSince(startedAt) < 0.75,
        "a stalled source stat blocked the store actor"
    )
    guard case .healthy = await store.view().health else {
        throw ValidationFailure.assertion(
            "a read-only source inspection timeout poisoned journal mutation"
        )
    }

    blocker.release.signal()
    try await Task.sleep(nanoseconds: 100_000_000)
    _ = try await proveNativeClosedAudio(in: store, lease: mutation.lease)
}

private func testStaleGenerationJournalFailsClosed() async throws {
    let root = try temporaryRoot("stale-generation")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await store.beginFinalization(mutation.lease, deadline: futureDeadline())
    _ = try await finishValidatedAudio(in: store, mutation: mutation)

    let data = try Data(contentsOf: store.journalURL)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let generation = object["clearGeneration"] as? NSNumber else {
        throw ValidationFailure.assertion("could not inspect the journal fixture")
    }
    object["clearGeneration"] = generation.uint64Value + 1
    let corrupted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try corrupted.write(to: store.journalURL, options: .atomic)

    let readOnly = MacAudioProcessingStore(rootDirectory: root)
    guard case .readOnly = await readOnly.view().health else {
        throw ValidationFailure.assertion("a stale-generation live record must fail closed")
    }
    try require(
        FileManager.default.fileExists(atPath: readOnly.finalURL(for: recordingID).path),
        "stale-generation corruption must preserve audio"
    )
}

private func testLegacyAdoptionAndRawFallback() async throws {
    let root = try temporaryRoot("legacy-adoption")
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyDirectory = root.appendingPathComponent("Legacy", isDirectory: true)
    try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
    let legacyURL = legacyDirectory.appendingPathComponent("legacy.m4a")
    try writeValidAudio(to: legacyURL)
    let original = try Data(contentsOf: legacyURL)

    let store = MacAudioProcessingStore(rootDirectory: root)
    let generation = await store.view().clearGeneration
    let recordingID = UUID()
    let ready = try await store.adoptFinalizedSource(
        recordingID: recordingID,
        attemptID: UUID(),
        sourceURL: legacyURL,
        expectedClearGeneration: generation,
        deadline: futureDeadline()
    )
    try require(ready.record.stage == .readyForRecognition, "legacy audio should be adopted as ready")
    try require(ready.record.audioIntegrity != nil, "legacy adoption should persist integrity")
    let afterAdoption = try Data(contentsOf: legacyURL)
    try require(afterAdoption == original, "legacy adoption must not modify the original")
    try require(
        FileManager.default.fileExists(atPath: store.finalURL(for: recordingID).path),
        "legacy adoption should create a managed copy"
    )

    try await requireStoreError(.duplicateRecording, "adoption must reject an existing recording ID") {
        _ = try await store.adoptFinalizedSource(
            recordingID: recordingID,
            attemptID: UUID(),
            sourceURL: legacyURL,
            expectedClearGeneration: generation,
            deadline: futureDeadline()
        )
    }

    var mutation = try await store.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: ready.record.revision,
        deadline: futureDeadline()
    )
    mutation = try await store.markRawResultReady(
        mutation.lease,
        rawText: "complete raw transcript through the final token"
    )
    mutation = try await store.beginCleanup(mutation.lease)
    let fallback = try await store.finishCleanup(mutation.lease, cleanedText: "   \n")
    try require(
        fallback.record.resultText == "complete raw transcript through the final token",
        "empty cleanup must keep the complete raw transcript"
    )

    _ = try await store.tombstone(recordingID: recordingID)
    let afterDelete = try Data(contentsOf: legacyURL)
    try require(afterDelete == original, "deleting the managed copy must preserve legacy audio")
    _ = try await store.clearAll()
    try await requireStoreError(.staleLease, "pre-clear history cannot be adopted") {
        _ = try await store.adoptFinalizedSource(
            recordingID: UUID(),
            attemptID: UUID(),
            sourceURL: legacyURL,
            expectedClearGeneration: generation,
            deadline: futureDeadline()
        )
    }
    let afterRejectedAdoption = try Data(contentsOf: legacyURL)
    try require(afterRejectedAdoption == original, "failed adoption must preserve the original")
}

private func testOrderedRecognitionCheckpointsAndRetry() async throws {
    let root = try temporaryRoot("ordered-recognition")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await store.beginFinalization(mutation.lease, deadline: futureDeadline())
    mutation = try await finishValidatedAudio(in: store, mutation: mutation)
    mutation = try await store.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )

    mutation = try await store.checkpointRecognition(mutation.lease, partialText: "one")
    mutation = try await store.checkpointRecognition(mutation.lease, partialText: "one two")
    let threeLeaves = try await store.checkpointRecognition(
        mutation.lease,
        partialText: "one two three"
    )
    try await requireStoreError(.invalidTransition, "a checkpoint must never regress") {
        _ = try await store.checkpointRecognition(threeLeaves.lease, partialText: "one two")
    }
    try await requireStoreError(.invalidTransition, "a checkpoint must never be reordered") {
        _ = try await store.checkpointRecognition(threeLeaves.lease, partialText: "two one three")
    }

    let failed = try await store.fail(
        threeLeaves.lease,
        message: "the next leaf failed"
    )
    try require(failed.record.stage == .failed, "a later leaf failure must be terminal")
    try require(
        failed.record.rawText == "one two three",
        "a later leaf failure must retain every completed ordered checkpoint"
    )

    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let recovered = try await onlyRecord(in: restarted)
    try require(recovered.stage == .failed, "checkpoint recovery must remain terminal")
    try require(recovered.rawText == "one two three", "restart lost a completed checkpoint")

    var retry = try await restarted.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: recovered.revision,
        deadline: futureDeadline()
    )
    try require(retry.record.rawText == nil, "a fresh retry must start with a fresh checkpoint")
    retry = try await restarted.checkpointRecognition(retry.lease, partialText: "retry complete")
    retry = try await restarted.markRawResultReady(retry.lease, rawText: "retry complete")
    retry = try await restarted.beginCleanup(retry.lease)
    retry = try await restarted.finishCleanup(retry.lease, cleanedText: "retry complete")
    retry = try await restarted.markSucceeded(retry.lease)

    let secondRetry = try await restarted.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: retry.record.revision,
        deadline: futureDeadline()
    )
    try require(secondRetry.record.stage == .recognizing, "a succeeded recording must be retryable")
    let retryRecordCount = await restarted.view().records.count
    try require(
        retryRecordCount == 1,
        "retry from success must not duplicate the recording"
    )

    _ = try await restarted.tombstone(recordingID: recordingID)
    try await requireStoreError(.recordingDeleted, "Delete must fence a late checkpoint") {
        _ = try await restarted.checkpointRecognition(
            secondRetry.lease,
            partialText: "retry complete late"
        )
    }
}

private func testCheckpointPersistenceFailureStopsLaterLeaves() async throws {
    let root = try temporaryRoot("checkpoint-write-failure")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await store.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: store.partialURL(for: recordingID))
    mutation = try await store.markRecording(mutation.lease, captureDeadline: futureDeadline())
    mutation = try await store.beginFinalization(mutation.lease, deadline: futureDeadline())
    mutation = try await finishValidatedAudio(in: store, mutation: mutation)
    mutation = try await store.beginRecognition(
        recordingID: recordingID,
        attemptID: UUID(),
        expectedRevision: mutation.record.revision,
        deadline: futureDeadline()
    )
    mutation = try await store.checkpointRecognition(mutation.lease, partialText: "leaf one")

    try writeBytes([0x7B, 0x62, 0x61, 0x64], to: store.journalURL)
    var laterLeafWasRequested = false
    do {
        _ = try await store.checkpointRecognition(mutation.lease, partialText: "leaf one leaf two")
        laterLeafWasRequested = true
    } catch let error as MacAudioProcessingStore.StoreError {
        try require(error == .readOnly, "checkpoint persistence corruption must fail closed")
    }
    try require(!laterLeafWasRequested, "a failed checkpoint must stop later leaf processing")
    try require(
        FileManager.default.fileExists(atPath: store.finalURL(for: recordingID).path),
        "checkpoint persistence failure must preserve the complete source"
    )
}

private func testDurableJournalReplacementFailuresPreserveOldJournal() async throws {
    let root = try temporaryRoot("durable-journal")
    defer { try? FileManager.default.removeItem(at: root) }
    let healthy = MacAudioProcessingStore(rootDirectory: root)
    let prepared = try await healthy.prepare(
        recordingID: UUID(),
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    let originalJournal = try Data(contentsOf: healthy.journalURL)

    for operation in [
        MacAudioProcessingStore.TestOperation.journalWrite,
        .journalFileSync,
        .journalRename,
    ] {
        let failing = MacAudioProcessingStore(
            rootDirectory: root,
            recoverInterruptedWork: false,
            testHooks: .init(before: { candidate in
                if candidate == operation {
                    throw ValidationFailure.assertion("injected \(operation) failure")
                }
            })
        )
        try await requireStoreError(
            .storageUnavailable,
            "\(operation) failure must reject the mutation"
        ) {
            _ = try await failing.markRecording(
                prepared.lease,
                captureDeadline: futureDeadline()
            )
        }
        let currentJournal = try Data(contentsOf: healthy.journalURL)
        try require(
            currentJournal == originalJournal,
            "\(operation) failure replaced the last valid journal"
        )
        let readable = MacAudioProcessingStore(
            rootDirectory: root,
            recoverInterruptedWork: false
        )
        let record = try await onlyRecord(in: readable)
        try require(
            record.stage == .preparing && record.revision == prepared.record.revision,
            "\(operation) failure changed the durable journal state"
        )
    }

    let temporaryFiles = try FileManager.default.contentsOfDirectory(
        at: healthy.journalURL.deletingLastPathComponent(),
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasSuffix(".tmp") }
    try require(temporaryFiles.isEmpty, "failed journal replacements left temporary files")
}

private func testSourceDurabilityFailuresNeverBecomeReady() async throws {
    for operation in [
        MacAudioProcessingStore.TestOperation.sourceFileSync,
        .sourceDirectorySync,
        .sourceRename,
    ] {
        let root = try temporaryRoot("source-durability-\(operation)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MacAudioProcessingStore(
            rootDirectory: root,
            testHooks: .init(before: { candidate in
                if candidate == operation {
                    throw ValidationFailure.assertion("injected \(operation) failure")
                }
            })
        )
        let recordingID = UUID()
        var mutation = try await store.prepare(
            recordingID: recordingID,
            attemptID: UUID(),
            deadline: futureDeadline()
        )
        try writeValidAudio(to: store.partialURL(for: recordingID))
        mutation = try await store.markRecording(
            mutation.lease,
            captureDeadline: futureDeadline()
        )
        mutation = try await store.beginFinalization(
            mutation.lease,
            deadline: futureDeadline()
        )

        do {
            let proof = try await proveNativeClosedAudio(
                in: store,
                lease: mutation.lease
            )
            let checkpoint = try await store.checkpointClosedAudio(
                mutation.lease,
                proof: proof
            )
            _ = try await store.finishFinalization(checkpoint.lease, proof: proof)
            throw ValidationFailure.assertion("\(operation) failure unexpectedly became ready")
        } catch let error as MacAudioProcessingStore.StoreError {
            try require(
                error == .storageUnavailable,
                "\(operation) failure returned \(error)"
            )
        }
        let durable = try await onlyRecord(in: store)
        try require(
            durable.stage == .finalizing,
            "\(operation) failure published recognition-ready state"
        )
    }
}

private func testCaptureAndFinalizationUseDistinctDeadlines() async throws {
    let root = try temporaryRoot("stage-deadlines")
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock()
    let store = MacAudioProcessingStore(
        rootDirectory: root,
        testHooks: .init(now: { clock.now() })
    )

    let prepared = try await store.prepare(
        recordingID: UUID(),
        attemptID: UUID(),
        deadline: clock.now().addingTimeInterval(10)
    )
    clock.advance(9)
    let captureDeadline = clock.now().addingTimeInterval(100)
    let recording = try await store.markRecording(
        prepared.lease,
        captureDeadline: captureDeadline
    )
    try require(
        recording.record.deadline == captureDeadline,
        "preparation time consumed the recording allowance"
    )

    clock.advance(100.001)
    let finalizationDeadline = clock.now().addingTimeInterval(60)
    let finalizing = try await store.beginFinalization(
        recording.lease,
        deadline: finalizationDeadline
    )
    try require(
        finalizing.record.stage == .finalizing
            && finalizing.record.deadline == finalizationDeadline,
        "exact max-length stop did not atomically receive finalization grace"
    )
    try await requireStoreError(.staleLease, "capture mutated after finalization took ownership") {
        _ = try await store.beginFinalization(
            recording.lease,
            deadline: clock.now().addingTimeInterval(60)
        )
    }

    let latePrepared = try await store.prepare(
        recordingID: UUID(),
        attemptID: UUID(),
        deadline: clock.now().addingTimeInterval(10)
    )
    let lateRecording = try await store.markRecording(
        latePrepared.lease,
        captureDeadline: clock.now().addingTimeInterval(10)
    )
    clock.advance(15.001)
    try await requireStoreError(.invalidDeadline, "unbounded late finalization was accepted") {
        _ = try await store.beginFinalization(
            lateRecording.lease,
            deadline: clock.now().addingTimeInterval(60)
        )
    }
}

private func makeInterruptedFinalSource(
    root: URL
) async throws -> (recordingID: UUID, failed: MacAudioProcessingStore.Record) {
    let first = MacAudioProcessingStore(rootDirectory: root)
    let recordingID = UUID()
    var mutation = try await first.prepare(
        recordingID: recordingID,
        attemptID: UUID(),
        deadline: futureDeadline()
    )
    try writeValidAudio(to: first.partialURL(for: recordingID))
    mutation = try await first.markRecording(
        mutation.lease,
        captureDeadline: futureDeadline()
    )
    mutation = try await first.beginFinalization(
        mutation.lease,
        deadline: futureDeadline()
    )
    let proof = try await proveNativeClosedAudio(
        in: first,
        lease: mutation.lease
    )
    _ = try await first.checkpointClosedAudio(mutation.lease, proof: proof)
    try FileManager.default.moveItem(
        at: first.partialURL(for: recordingID),
        to: first.finalURL(for: recordingID)
    )
    let restarted = MacAudioProcessingStore(rootDirectory: root)
    return (recordingID, try await onlyRecord(in: restarted))
}

private func testBlockedDeepValidationDeadlineAndPromptRestart() async throws {
    let root = try temporaryRoot("blocked-validation")
    defer { try? FileManager.default.removeItem(at: root) }
    let interrupted = try await makeInterruptedFinalSource(root: root)
    try require(interrupted.failed.stage == .failed, "interrupted source did not terminalize")
    try require(
        interrupted.failed.audioFileIdentity == nil,
        "crash fixture unexpectedly had a cheap finalized identity"
    )

    let restartBlocker = BlockingOperationHook()
    let storeBox = StoreBox()
    let restartFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        storeBox.set(MacAudioProcessingStore(
            rootDirectory: root,
            testHooks: .init(before: { operation in
                try restartBlocker.before(operation)
            })
        ))
        restartFinished.signal()
    }
    let restartResult = await Task.detached {
        waitSynchronously(for: restartFinished, timeout: .now() + 0.5)
    }.value
    restartBlocker.release.signal()
    try require(restartResult == .success, "restart waited for blocked deep audio validation")
    try require(restartBlocker.count == 0, "restart entered deep audio validation")
    guard let store = storeBox.get() else {
        throw ValidationFailure.assertion("prompt restart did not return a store")
    }
    let durableBefore = try await onlyRecord(in: store)

    let retryBlocker = BlockingOperationHook()
    let retryStore = MacAudioProcessingStore(
        rootDirectory: root,
        recoverInterruptedWork: false,
        testHooks: .init(before: { operation in
            try retryBlocker.before(operation)
        })
    )
    let startedAt = Date()
    do {
        _ = try await retryStore.beginRecognition(
            recordingID: interrupted.recordingID,
            attemptID: UUID(),
            expectedRevision: durableBefore.revision,
            deadline: Date().addingTimeInterval(0.15)
        )
        retryBlocker.release.signal()
        throw ValidationFailure.assertion("blocked deep validation unexpectedly started recognition")
    } catch let error as MacAudioProcessingStore.StoreError {
        retryBlocker.release.signal()
        try require(error == .invalidDeadline, "blocked validation returned \(error)")
    }
    try require(
        Date().timeIntervalSince(startedAt) < 0.75,
        "blocked deep validation did not return at its deadline"
    )
    try await Task.sleep(nanoseconds: 100_000_000)
    let durableAfter = try await onlyRecord(in: retryStore)
    try require(
        durableAfter == durableBefore,
        "late deep-validation completion mutated the durable attempt"
    )
}

private func testCorruptJournalPreservesAudio() async throws {
    let root = try temporaryRoot("corrupt-journal")
    defer { try? FileManager.default.removeItem(at: root) }

    let healthy = MacAudioProcessingStore(rootDirectory: root)
    let orphanRecordingID = UUID()
    let orphanURL = healthy.finalURL(for: orphanRecordingID)
    try writeBytes([0x50, 0x52, 0x45, 0x53, 0x45, 0x52, 0x56, 0x45], to: orphanURL)
    try Data("{not valid json".utf8).write(to: healthy.journalURL, options: .atomic)

    let readOnly = MacAudioProcessingStore(rootDirectory: root)
    let view = await readOnly.view()
    guard case .readOnly = view.health else {
        throw ValidationFailure.assertion("a corrupt journal must fail closed")
    }
    try require(
        FileManager.default.fileExists(atPath: orphanURL.path),
        "corrupt-journal recovery must preserve untracked audio"
    )

    try await requireStoreError(.readOnly, "a corrupt journal must reject mutation") {
        _ = try await readOnly.prepare(
            recordingID: UUID(),
            attemptID: UUID(),
            deadline: futureDeadline()
        )
    }
    try require(
        FileManager.default.fileExists(atPath: orphanURL.path),
        "a rejected mutation must not remove preserved audio"
    )
}

private func testMissingJournalWithAudioFailsClosed() async throws {
    let root = try temporaryRoot("missing-journal")
    defer { try? FileManager.default.removeItem(at: root) }

    let layout = MacAudioProcessingStore(rootDirectory: root)
    let orphanRecordingID = UUID()
    let orphanURL = layout.finalURL(for: orphanRecordingID)
    try writeBytes([0x4D, 0x34, 0x41, 0x00], to: orphanURL)
    try? FileManager.default.removeItem(at: layout.journalURL)

    let readOnly = MacAudioProcessingStore(rootDirectory: root)
    guard case .readOnly = await readOnly.view().health else {
        throw ValidationFailure.assertion("audio without its journal must fail closed")
    }
    try require(
        FileManager.default.fileExists(atPath: orphanURL.path),
        "audio without its journal must be preserved"
    )
    try await requireStoreError(.readOnly, "missing ownership metadata must reject mutation") {
        _ = try await readOnly.prepare(
            recordingID: UUID(),
            attemptID: UUID(),
            deadline: futureDeadline()
        )
    }
}

private func testUsageClaimRequiresDurableSuccessAndIsAtMostOnce() async throws {
    let root = try temporaryRoot("usage-claim")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    var mutation = try await beginRecognizing(in: store)
    mutation = try await store.markRawResultReady(
        mutation.lease,
        rawText: "three durable words"
    )
    mutation = try await store.beginCleanup(mutation.lease)
    mutation = try await store.finishCleanup(
        mutation.lease,
        cleanedText: "three durable words"
    )

    try await requireStoreError(
        .staleLease,
        "usage cannot be claimed while History publication is still pending"
    ) {
        _ = try await store.claimPendingUsage(
            recordingID: mutation.record.recordingID,
            expectedRevision: mutation.record.revision
        )
    }

    mutation = try await store.markSucceeded(
        mutation.lease,
        pendingUsageWordCount: 3
    )
    let claimed = try await store.claimPendingUsage(
        recordingID: mutation.record.recordingID,
        expectedRevision: mutation.record.revision
    )
    try require(claimed == 3, "the durable terminal result should expose one usage claim")

    let restarted = MacAudioProcessingStore(rootDirectory: root)
    let recovered = try await onlyRecord(in: restarted)
    let duplicate = try await restarted.claimPendingUsage(
        recordingID: recovered.recordingID,
        expectedRevision: recovered.revision
    )
    try require(duplicate == nil, "a restart must not claim the same usage event twice")
}

private func testTransientWorkspaceCapabilityAndSweeps() async throws {
    let root = try temporaryRoot("transient-capability")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MacAudioProcessingStore(rootDirectory: root)
    let recognizing = try await beginRecognizing(in: store)
    let first = try await store.makeTransientWorkspace(recognizing.lease)
    let firstOutput = try first.makeOutputURL()
    try Data([0x01, 0x02, 0x03]).write(to: firstOutput)
    try first.validateCompletedOutput(firstOutput)

    let second = try await store.makeTransientWorkspace(recognizing.lease)
    let secondOutput = try second.makeOutputURL()
    try Data([0x04, 0x05]).write(to: secondOutput)
    try second.validateCompletedOutput(secondOutput)
    let secondDirectory = second.directoryURL

    first.cleanup()
    second.cleanup()
    try require(
        !FileManager.default.fileExists(atPath: secondDirectory.path),
        "a second workspace cleanup must not inherit the first enumeration offset"
    )

    let tampered = try await store.makeTransientWorkspace(recognizing.lease)
    let originalWorkspace = tampered.directoryURL
    let transientDirectory = store.transientDirectory
    let retainedDirectory = transientDirectory.deletingLastPathComponent()
        .appendingPathComponent("Transient-retained", isDirectory: true)
    try FileManager.default.moveItem(at: transientDirectory, to: retainedDirectory)

    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel.txt")
    try Data("keep".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(
        at: transientDirectory,
        withDestinationURL: outside
    )

    do {
        _ = try tampered.makeOutputURL()
        throw ValidationFailure.assertion(
            "a substituted transient ancestor must reject new path-based writes"
        )
    } catch is MacTransientWorkspace.WorkspaceError {
        // Expected.
    }
    tampered.cleanup()
    let retainedWorkspace = retainedDirectory.appendingPathComponent(
        originalWorkspace.lastPathComponent,
        isDirectory: true
    )
    try require(
        !FileManager.default.fileExists(atPath: retainedWorkspace.path),
        "cleanup must remove the original workspace through its retained capability"
    )
    let sentinelContents = try Data(contentsOf: sentinel)
    try require(
        sentinelContents == Data("keep".utf8),
        "cleanup followed the substituted ancestor and touched an outside sentinel"
    )
}

private func testStartupSweepsOnlyManagedTransientChildren() async throws {
    let root = try temporaryRoot("transient-startup-sweep")
    defer { try? FileManager.default.removeItem(at: root) }
    let layout = MacAudioProcessingStore(rootDirectory: root)
    let orphan = layout.transientDirectory
        .appendingPathComponent("orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data([0x01]).write(to: orphan.appendingPathComponent("chunk.m4a"))
    _ = MacAudioProcessingStore(rootDirectory: root)
    try require(
        !FileManager.default.fileExists(atPath: orphan.path),
        "startup must sweep crash-orphaned derived workspaces"
    )
}

private func testLegacyHistoryDeletionNeverTrustsDecodedPaths() throws {
    let root = try temporaryRoot("legacy-history-delete")
    defer { try? FileManager.default.removeItem(at: root) }
    let applicationSupport = root.appendingPathComponent(
        "Application Support",
        isDirectory: true
    )
    let recordings = applicationSupport
        .appendingPathComponent("WhisperMate", isDirectory: true)
        .appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(
        at: recordings,
        withIntermediateDirectories: true
    )

    let recordingID = UUID()
    let expected = recordings.appendingPathComponent(
        "recording_\(recordingID.uuidString).m4a"
    )
    try Data([0x01]).write(to: expected)
    let removed = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: expected,
        applicationSupportDirectory: applicationSupport
    )
    try require(removed == .removed, "the exact trusted legacy child should be removable")
    try require(
        !FileManager.default.fileExists(atPath: expected.path),
        "the exact trusted legacy child remained after accepted deletion"
    )

    let historicalTimestamp = recordings.appendingPathComponent(
        "recording_1721836800.123456.m4a"
    )
    try Data([0x02]).write(to: historicalTimestamp)
    let removedHistoricalTimestamp = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: historicalTimestamp,
        applicationSupportDirectory: applicationSupport
    )
    try require(
        removedHistoricalTimestamp == .removed,
        "Delete/Clear refused the historical timestamp recording filename"
    )
    try require(
        !FileManager.default.fileExists(atPath: historicalTimestamp.path),
        "the historical timestamp recording remained after accepted deletion"
    )

    let malformedTimestamp = recordings.appendingPathComponent(
        "recording_1721836800e0.m4a"
    )
    try Data("malformed sentinel".utf8).write(to: malformedTimestamp)
    let refusedMalformedTimestamp = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: malformedTimestamp,
        applicationSupportDirectory: applicationSupport
    )
    try require(
        refusedMalformedTimestamp == .refused,
        "legacy deletion accepted a non-decimal timestamp filename"
    )
    let malformedTimestampContents = try Data(contentsOf: malformedTimestamp)
    try require(
        malformedTimestampContents == Data("malformed sentinel".utf8),
        "legacy deletion changed a malformed direct-child sentinel"
    )

    let unicodeNumericTimestamp = recordings.appendingPathComponent(
        "recording_١٧٢١٨٣٦٨٠٠.١٢٣٤٥٦.m4a"
    )
    try Data("unicode sentinel".utf8).write(to: unicodeNumericTimestamp)
    let refusedUnicodeNumericTimestamp = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: unicodeNumericTimestamp,
        applicationSupportDirectory: applicationSupport
    )
    try require(
        refusedUnicodeNumericTimestamp == .refused,
        "legacy deletion accepted Unicode numerics instead of ASCII timestamp digits"
    )
    let unicodeTimestampContents = try Data(contentsOf: unicodeNumericTimestamp)
    try require(
        unicodeTimestampContents == Data("unicode sentinel".utf8),
        "legacy deletion changed a Unicode-numeric direct-child sentinel"
    )

    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideSentinel = outside.appendingPathComponent("sentinel.m4a")
    try Data("outside".utf8).write(to: outsideSentinel)
    let refusedOutside = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: outsideSentinel,
        applicationSupportDirectory: applicationSupport
    )
    try require(refusedOutside == .refused, "an absolute decoded outside path was not refused")
    let outsideContents = try Data(contentsOf: outsideSentinel)
    try require(
        outsideContents == Data("outside".utf8),
        "Delete/Clear followed a decoded outside path and changed its sentinel"
    )

    let trustedRecordings = recordings.deletingLastPathComponent()
        .appendingPathComponent("Recordings-trusted", isDirectory: true)
    try FileManager.default.moveItem(at: recordings, to: trustedRecordings)
    try FileManager.default.createSymbolicLink(
        at: recordings,
        withDestinationURL: outside
    )
    let symlinkedCandidate = recordings.appendingPathComponent(
        "recording_\(recordingID.uuidString).m4a"
    )
    try Data("symlink sentinel".utf8).write(to: outside.appendingPathComponent(
        symlinkedCandidate.lastPathComponent
    ))
    let refusedAncestor = MacHistoryAudioDeletion.remove(
        recordingID: recordingID,
        candidateURL: symlinkedCandidate,
        applicationSupportDirectory: applicationSupport
    )
    try require(
        refusedAncestor == .refused,
        "a symlinked legacy Recordings ancestor was not refused"
    )
    let symlinkSentinel = try Data(
        contentsOf: outside.appendingPathComponent(symlinkedCandidate.lastPathComponent)
    )
    try require(
        symlinkSentinel == Data("symlink sentinel".utf8),
        "legacy deletion followed a symlinked ancestor"
    )
}

@main
private struct MacAudioProcessingStoreValidator {
    static func main() async {
        do {
            print("test: old attempt")
            try await testOldAttemptAndRevisionRejection()
            print("test: concurrent cas")
            try await testConcurrentCASHasOneWinner()
            print("test: clear")
            try await testClearGenerationAndNewRecording()
            print("test: tombstone")
            try await testTombstoneBeatsLateCallbackAndRestart()
            print("test: restart")
            try await testRestartStages()
            print("test: timeout/raw")
            try await testTimeoutAndResultRecoveryPreserveSource()
            print("test: rename crash")
            try await testRenameJournalCrashReconciliation()
            print("test: two store")
            try await testTwoStoreClearBeatsStaleWriter()
            print("test: invalid audio")
            try await testInvalidAudioNeverBecomesReady()
            print("test: salvage")
            try await testLateCloseCanBeSalvagedSafely()
            print("test: same-process native close")
            try await testSameProcessRetryRequiresExactNativeClose()
            print("test: late close Delete/Clear fence")
            try await testDeleteAndClearFenceLateCloseCheckpoint()
            print("test: bounded persistence")
            try await testHeldLockAndStalledPersistenceAreBounded()
            print("test: bounded tombstone cleanup")
            try await testTombstoneCleanupIsBounded()
            print("test: bounded source inspection")
            try await testSourceInspectionIsBounded()
            print("test: stale generation")
            try await testStaleGenerationJournalFailsClosed()
            print("test: adoption/raw")
            try await testLegacyAdoptionAndRawFallback()
            print("test: ordered checkpoints/retry")
            try await testOrderedRecognitionCheckpointsAndRetry()
            print("test: checkpoint persistence failure")
            try await testCheckpointPersistenceFailureStopsLaterLeaves()
            print("test: durable journal replacement")
            try await testDurableJournalReplacementFailuresPreserveOldJournal()
            print("test: source durability")
            try await testSourceDurabilityFailuresNeverBecomeReady()
            print("test: stage deadlines")
            try await testCaptureAndFinalizationUseDistinctDeadlines()
            print("test: blocked validation/restart")
            try await testBlockedDeepValidationDeadlineAndPromptRestart()
            print("test: corrupt")
            try await testCorruptJournalPreservesAudio()
            print("test: missing journal")
            try await testMissingJournalWithAudioFailsClosed()
            print("test: usage claim")
            try await testUsageClaimRequiresDurableSuccessAndIsAtMostOnce()
            print("test: transient capability")
            try await testTransientWorkspaceCapabilityAndSweeps()
            print("test: transient startup sweep")
            try await testStartupSweepsOnlyManagedTransientChildren()
            print("test: legacy decoded path deletion")
            try testLegacyHistoryDeletionNeverTrustsDecodedPaths()
            print("PASS: macOS audio-processing journal recovery and fencing")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
