import Foundation

private enum ContractFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private final class FakeRuntimeBridge: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationCount = 0
    private var cleanupCount = 0
    private var cancelledIDs: [String] = []

    @objc(cancelAttempt:)
    func cancelAttempt(_ attemptID: NSString) {
        lock.lock()
        cancellationCount += 1
        cancelledIDs.append(attemptID as String)
        lock.unlock()
    }

    @objc(cleanupRuntime)
    func cleanupRuntime() {
        lock.lock()
        cleanupCount += 1
        lock.unlock()
    }

    func snapshot() -> (count: Int, cleanupCount: Int, ids: [String]) {
        lock.lock()
        let value = (cancellationCount, cleanupCount, cancelledIDs)
        lock.unlock()
        return value
    }
}

@main
private struct ParakeetRuntimeRecoveryContract {
    static func main() async throws {
        try await testResultBeforeContinuationInstallation()
        try await testExactlyOnceAndLateCallbackFence()
        try await testCancellationBeforeNativeCallback()
        try await testCancellationSelectorIsExactlyOnce()
        try testCancellationRetiresGenerationSynchronously()
        try validateSourceIntegration()
        print("Parakeet runtime recovery contract: PASS")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ContractFailure.failed(message) }
    }

    private static func testResultBeforeContinuationInstallation() async throws {
        let gate = RuntimeCallbackAttempt<Int>()
        try require(gate.resolve(.success(41)), "first result must win before install")

        let value = try await withCheckedThrowingContinuation { continuation in
            let installed = gate.install(continuation)
            precondition(!installed, "pre-resolved result must be delivered immediately")
        }
        try require(value == 41, "pre-install result must be preserved")
        try require(!gate.resolve(.success(42)), "late result must be fenced")
    }

    private static func testExactlyOnceAndLateCallbackFence() async throws {
        let gate = RuntimeCallbackAttempt<String>()
        let waiter = Task<String, Error> {
            try await withCheckedThrowingContinuation { continuation in
                precondition(gate.install(continuation), "fresh gate must install")
            }
        }

        await Task.yield()
        let winnerCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    gate.resolve(.success("winner-\(index)"))
                }
            }
            var winners = 0
            for await didWin in group where didWin {
                winners += 1
            }
            return winners
        }

        _ = try await waiter.value
        try require(winnerCount == 1, "concurrent native callbacks must have exactly one winner")
        try require(!gate.resolve(.success("late")), "callback after completion must be ignored")
    }

    private static func testCancellationBeforeNativeCallback() async throws {
        let gate = RuntimeCallbackAttempt<String>()
        let waiter = Task<String, Error> {
            try await withCheckedThrowingContinuation { continuation in
                precondition(gate.install(continuation), "fresh cancellation gate must install")
            }
        }

        await Task.yield()
        try require(gate.resolve(.failure(CancellationError())), "cancellation must win")
        do {
            _ = try await waiter.value
            throw ContractFailure.failed("cancelled waiter unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }
        try require(!gate.resolve(.success("late native result")), "late native callback must not revive a cancelled attempt")
    }

    private static func testCancellationSelectorIsExactlyOnce() async throws {
        let bridge = FakeRuntimeBridge()
        let cancellation = RuntimeAttemptCancellation(bridge: bridge, attemptID: "attempt-7")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { cancellation.cancel() }
            }
        }

        let snapshot = bridge.snapshot()
        try require(snapshot.count == 1, "native cancel selector must run exactly once")
        try require(snapshot.ids == ["attempt-7"], "native cancel must use the stable attempt ID")
    }

    private static func testCancellationRetiresGenerationSynchronously() throws {
        let slot = RuntimeBridgeSlot()
        let oldBridge = FakeRuntimeBridge()
        _ = slot.installIfEmpty(oldBridge)
        let oldGeneration = try requireValue(
            slot.generation(of: oldBridge),
            "old runtime generation was not assigned"
        )
        let cancellation = RuntimeAttemptCancellation(
            bridge: oldBridge,
            attemptID: "old-generation",
            bridgeSlot: slot
        )

        cancellation.cancel()
        try require(slot.current() == nil, "cancel must retire the old generation before returning")
        let oldSnapshot = oldBridge.snapshot()
        try require(oldSnapshot.cleanupCount == 1, "retired generation must be asked to clean up")

        let retryBridge = FakeRuntimeBridge()
        try require(
            slot.installIfEmpty(retryBridge) === retryBridge,
            "an immediate explicit retry must install a fresh generation"
        )
        try require(slot.current() === retryBridge, "late old-generation work replaced the retry bridge")
        let retryGeneration = try requireValue(
            slot.generation(of: retryBridge),
            "retry runtime generation was not assigned"
        )

        var staleCatchPublished = false
        try require(
            !slot.withLatestGeneration(oldGeneration) { staleCatchPublished = true },
            "an old cancelled catch was allowed to publish into the retry generation"
        )
        try require(!staleCatchPublished, "old catch overwrote retry-visible state")

        var retryPublished = false
        try require(
            slot.withLatestGeneration(retryGeneration) { retryPublished = true },
            "current retry generation could not publish state"
        )
        try require(retryPublished, "retry state publication did not run")
    }

    private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ContractFailure.failed(message) }
        return value
    }

    private static func validateSourceIntegration() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/ParakeetRuntime/ParakeetRuntimeBridge.swift"),
            encoding: .utf8
        )
        let macService = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/Whispermate/Services/ParakeetTranscriptionService.swift"),
            encoding: .utf8
        )
        let sharedService = try String(
            contentsOf: root.appendingPathComponent("Whishpermate/WhisperMateShared/Services/SharedParakeetTranscriptionService.swift"),
            encoding: .utf8
        )

        for required in [
            "initializeAttempt:completion:",
            "transcribeAudioAtPath:attemptID:completion:",
            "transcribeDiarizedAudioAtPath:attemptID:completion:",
            "cancelAttempt:",
            "preCancelledAttemptIDs",
            "activeOperation?.abandoned = true",
            "activeOperation?.cleanupRequested = true",
            "task?.cancel()",
            "guard resolution.shouldDeliver else { return }",
        ] {
            try require(runtime.contains(required), "runtime bridge is missing recovery fence: \(required)")
        }

        for source in [macService, sharedService] {
            try require(source.contains("RuntimeCallbackAttempt<String>()"), "service must use an exactly-once callback gate")
            try require(source.contains("RuntimeAttemptCancellation"), "service must own native cancellation")
            try require(source.contains("withTaskCancellationHandler"), "service must propagate Swift cancellation")
            try require(source.contains("transcribeDiarizedAudioAtPath:attemptID:completion:"), "diarized runtime call must be attempt-scoped")
            try require(source.contains("catch is CancellationError"), "service must preserve cancellation semantics")
            try require(source.contains("retireRuntimeBridge(bridge)"), "cancelled native generation must be retired for explicit retry")
            try require(source.contains("private let runtimeBridgeSlot = RuntimeBridgeSlot()"), "runtime generations need an atomic slot")
            try require(source.contains("bridgeSlot: runtimeBridgeSlot"), "cancellation must synchronously retire the generation")
            try require(source.contains("withLatestGeneration(generation)"), "state publication must be generation-fenced")
        }
    }
}
