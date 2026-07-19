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
    private var synchronousCancelHook: (() -> Void)?

    @objc(cancelAttempt:)
    func cancelAttempt(_ attemptID: NSString) {
        let hook: (() -> Void)?
        lock.lock()
        cancellationCount += 1
        cancelledIDs.append(attemptID as String)
        hook = synchronousCancelHook
        lock.unlock()
        hook?()
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

    func setSynchronousCancelHook(_ hook: @escaping () -> Void) {
        lock.lock()
        synchronousCancelHook = hook
        lock.unlock()
    }
}

@main
private struct ParakeetRuntimeRecoveryContract {
    static func main() async throws {
        try await testResultBeforeContinuationInstallation()
        try await testExactlyOnceAndLateCallbackFence()
        try await testCancellationBeforeNativeCallback()
        try await testCancellationSelectorIsExactlyOnce()
        try testPreCancelledAttemptCannotAcquireRetryBridge()
        try testOwnedCancellationRetiresGenerationSynchronously()
        try testSynchronousCancelCallbackCannotReleaseBeforeRetirement()
        try testRetryStartsBeforeLateOldAttemptResumes()
        try testLateCatchCannotPublishAfterRetryReady()
        try testExplicitCleanupInvalidatesPublicationGeneration()
        try testGenerationOverflowFailsClosed()
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

    private static func testPreCancelledAttemptCannotAcquireRetryBridge() throws {
        let slot = RuntimeBridgeSlot()
        let abandoned = RuntimeBridgeAttemptOwnership(slot: slot)
        abandoned.cancel()

        let retryBridge = FakeRuntimeBridge()
        try require(
            slot.installIfEmpty(retryBridge) === retryBridge,
            "retry bridge was not installed"
        )
        let retry = RuntimeBridgeAttemptOwnership(slot: slot)
        try require(retry.reserve(retryBridge) != nil, "retry could not reserve its bridge")

        try require(
            abandoned.reserve(retryBridge) == nil,
            "a pre-cancelled old attempt reserved the retry bridge"
        )
        abandoned.cancel()
        try require(slot.current() === retryBridge, "late old cancellation retired the retry bridge")
        try require(retryBridge.snapshot().cleanupCount == 0, "retry bridge was cleaned by the old attempt")
        try require(retry.release(), "retry owner could not release its bridge")
    }

    private static func testOwnedCancellationRetiresGenerationSynchronously() throws {
        let slot = RuntimeBridgeSlot()
        let oldBridge = FakeRuntimeBridge()
        try require(slot.installIfEmpty(oldBridge) === oldBridge, "old bridge was not installed")
        let oldOwner = RuntimeBridgeAttemptOwnership(slot: slot)
        _ = try requireValue(
            oldOwner.reserve(oldBridge),
            "old runtime generation was not reserved"
        )
        let cancellation = RuntimeAttemptCancellation(
            bridge: oldBridge,
            attemptID: "old-generation",
            bridgeOwnership: oldOwner
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
        let retryOwner = RuntimeBridgeAttemptOwnership(slot: slot)
        try require(retryOwner.reserve(retryBridge) != nil, "retry generation was not reserved")
        cancellation.cancel()
        try require(slot.current() === retryBridge, "late repeated cancellation replaced the retry bridge")
        try require(retryOwner.release(), "retry owner could not release")
    }

    private static func testRetryStartsBeforeLateOldAttemptResumes() throws {
        let slot = RuntimeBridgeSlot()
        let lateOldOwner = RuntimeBridgeAttemptOwnership(slot: slot)
        lateOldOwner.cancel()

        let retryBridge = FakeRuntimeBridge()
        try require(slot.installIfEmpty(retryBridge) === retryBridge, "retry-first bridge was not installed")
        let retryOwner = RuntimeBridgeAttemptOwnership(slot: slot)
        try require(retryOwner.reserve(retryBridge) != nil, "retry-first owner did not reserve")

        // This is the old task resuming after its only cancellation callback.
        try require(lateOldOwner.reserve(retryBridge) == nil, "late old task acquired retry-first bridge")
        try require(slot.current() === retryBridge, "late old task disturbed retry-first bridge")
        try require(retryOwner.release(), "retry-first owner could not release")
    }

    private static func testSynchronousCancelCallbackCannotReleaseBeforeRetirement() throws {
        let slot = RuntimeBridgeSlot()
        let bridge = FakeRuntimeBridge()
        try require(slot.installIfEmpty(bridge) === bridge, "synchronous-callback bridge was not installed")
        let owner = RuntimeBridgeAttemptOwnership(slot: slot)
        try require(owner.reserve(bridge) != nil, "synchronous-callback owner did not reserve")
        bridge.setSynchronousCancelHook {
            _ = owner.release()
        }

        RuntimeAttemptCancellation(
            bridge: bridge,
            attemptID: "synchronous-callback",
            bridgeOwnership: owner
        ).cancel()

        try require(slot.current() == nil, "synchronous callback released the bridge before retirement")
        try require(bridge.snapshot().cleanupCount == 1, "retired bridge was not cleaned after synchronous callback")

        let retry = FakeRuntimeBridge()
        try require(slot.installIfEmpty(retry) === retry, "retry could not install after synchronous callback")
        try require(slot.current() === retry, "synchronous old callback disturbed the retry bridge")
    }

    private static func testLateCatchCannotPublishAfterRetryReady() throws {
        var fence = RuntimeGenerationPublicationFence()
        try require(fence.register(41), "old generation did not register")
        try require(fence.accepts(41), "old generation was not initially current")
        try require(fence.register(42), "retry generation did not register")
        try require(!fence.accepts(41), "late old catch could publish after retry registered")
        try require(fence.accepts(42), "retry-ready state was not accepted")
        try require(!fence.register(41), "publication fence moved backwards")
    }

    private static func testExplicitCleanupInvalidatesPublicationGeneration() throws {
        let slot = RuntimeBridgeSlot()
        let bridge = FakeRuntimeBridge()
        try require(slot.installIfEmpty(bridge) === bridge, "cleanup test bridge was not installed")
        let oldGeneration = try requireValue(slot.generation(of: bridge), "cleanup test generation missing")
        var fence = RuntimeGenerationPublicationFence()
        try require(fence.register(oldGeneration), "cleanup test generation did not register")

        let invalidation = slot.invalidateAndTake()
        try require(invalidation.bridge === bridge, "cleanup did not take the exact bridge")
        let tombstone = invalidation.generation
        try require(tombstone > oldGeneration, "cleanup tombstone did not advance generation")
        try require(fence.invalidate(tombstone), "cleanup tombstone did not invalidate publication")
        try require(!fence.accepts(oldGeneration), "same-generation completion could publish ready after cleanup")
        try require(!fence.accepts(tombstone), "cleanup tombstone accepted a runtime completion")
    }

    private static func testGenerationOverflowFailsClosed() throws {
        let exhausted = RuntimeBridgeSlot(initialGeneration: UInt64.max)
        let bridge = FakeRuntimeBridge()
        try require(exhausted.installIfEmpty(bridge) == nil, "generation identity wrapped at UInt64.max")
        try require(exhausted.current() == nil, "exhausted slot installed an unidentifiable bridge")

        let finalSlot = RuntimeBridgeSlot(initialGeneration: UInt64.max - 1)
        let finalBridge = FakeRuntimeBridge()
        try require(finalSlot.installIfEmpty(finalBridge) === finalBridge, "final unique generation was not installed")
        let finalGeneration = try requireValue(finalSlot.generation(of: finalBridge), "final generation missing")
        var fence = RuntimeGenerationPublicationFence()
        try require(fence.register(finalGeneration), "final generation did not register")
        let invalidation = finalSlot.invalidateAndTake()
        try require(invalidation.generation == UInt64.max, "final cleanup wrapped generation")
        try require(fence.invalidate(invalidation.generation), "final generation did not invalidate")
        try require(!fence.accepts(finalGeneration), "final-generation callback survived cleanup")
        try require(finalSlot.installIfEmpty(FakeRuntimeBridge()) == nil, "slot reused exhausted identity after cleanup")
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
            try require(source.contains("private let runtimeBridgeSlot = RuntimeBridgeSlot()"), "runtime generations need an atomic slot")
            try require(source.contains("RuntimeBridgeAttemptOwnership(slot: runtimeBridgeSlot)"), "outer attempt must remember cancellation before bridge acquisition")
            try require(source.contains("bridgeOwnership: ownership"), "native cancellation must retire only its owned generation")
            try require(source.contains("ownership.reserve(bridge)"), "attempt must exclusively reserve its exact bridge")
            try require(source.contains("RuntimeGenerationPublicationFence"), "state publication must use a monotonic MainActor fence")
            try require(source.contains("registerRuntimeGeneration(generation)"), "generation must register before visible transcription state")
            try require(source.contains("publishRuntimeState(generation"), "later state writes must require exact generation")
            try require(source.contains("runtimeBridgeSlot.invalidateAndTake()"), "explicit cleanup must advance a tombstone generation")
            try require(source.contains("runtimePublicationFence.invalidate(invalidation.generation)"), "cleanup must invalidate state publication synchronously")
            try require(!source.contains("withLatestGeneration"), "published state must not be sent while holding the slot lock")
        }

        let sharedTerminalCatches = sharedService
            .components(separatedBy: "} catch {")
            .dropFirst()
            .map { String($0.prefix(600)) }
            .filter { $0.contains("ownership.cancel()") }
        try require(
            sharedTerminalCatches.count >= 3,
            "shared initialization, transcription, and diarization errors must retire their runtime generation"
        )

        let macTerminalCatches = macService
            .components(separatedBy: "} catch {")
            .dropFirst()
            .map { String($0.prefix(600)) }
            .filter { $0.contains("ownership.cancel()") }
        try require(
            macTerminalCatches.count >= 3,
            "macOS initialization, transcription, and diarization errors must retire their runtime generation"
        )
    }
}
