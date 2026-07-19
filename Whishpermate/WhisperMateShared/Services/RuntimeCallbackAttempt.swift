import Foundation

/// Exactly-once bridge between callback runtimes and Swift cancellation.
/// A cancellation may arrive before the callback is installed; the pending
/// result is delivered as soon as installation occurs. Late native callbacks
/// are ignored.
public final class RuntimeCallbackAttempt<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var resolved = false

    public init() {}

    /// Returns false when cancellation/result won before installation. The
    /// continuation is still resumed exactly once in that case.
    @discardableResult
    public func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let immediate: Result<Value, Error>?
        lock.lock()
        if resolved {
            immediate = pendingResult ?? .failure(CancellationError())
            pendingResult = nil
        } else {
            self.continuation = continuation
            immediate = nil
        }
        lock.unlock()

        if let immediate {
            continuation.resume(with: immediate)
            return false
        }
        return true
    }

    /// Returns true only for the result that won the attempt.
    @discardableResult
    public func resolve(_ result: Result<Value, Error>) -> Bool {
        let installed: CheckedContinuation<Value, Error>?
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        installed = continuation
        continuation = nil
        if installed == nil {
            pendingResult = result
        }
        lock.unlock()

        installed?.resume(with: result)
        return true
    }
}

/// Sendable cancellation token for an Objective-C runtime operation. The
/// runtime remembers cancellation that arrives before operation registration,
/// closing the cancel-before-start race.
public final class RuntimeAttemptCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let bridge: NSObject
    private let bridgeOwnership: RuntimeBridgeAttemptOwnership?
    private let attemptID: NSString
    private var didCancel = false

    public init(
        bridge: NSObject,
        attemptID: String,
        bridgeOwnership: RuntimeBridgeAttemptOwnership? = nil
    ) {
        self.bridge = bridge
        self.attemptID = attemptID as NSString
        self.bridgeOwnership = bridgeOwnership
    }

    public func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()

        // Retire ownership before invoking callback-capable native code. The
        // selector may synchronously resume the high-level scope and run its
        // defer/release path; by then retirement must already be irrevocable.
        let retiredBridge = bridgeOwnership?.beginCancellation()

        let selector = NSSelectorFromString("cancelAttempt:")
        if bridge.responds(to: selector),
           let method = bridge.method(for: selector) {
            typealias Function = @convention(c) (AnyObject, Selector, NSString) -> Void
            unsafeBitCast(method, to: Function.self)(bridge, selector, attemptID)
        }

        bridgeOwnership?.finishCancellation(retiredBridge)
    }
}

/// Atomic owner of the currently usable runtime generation. Cancellation can
/// retire a generation synchronously from a cancellation handler, before the
/// UI exposes Retry, while ignored native work remains isolated on the old
/// bridge object.
public final class RuntimeBridgeSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: NSObject?
    private var generation: UInt64
    private var ownerID: String?

    public init(initialGeneration: UInt64 = 0) {
        generation = initialGeneration
    }

    public func current() -> NSObject? {
        lock.lock()
        let value = bridge
        lock.unlock()
        return value
    }

    /// Returns nil instead of wrapping generation identity. Reusing an old
    /// generation would let a sufficiently late callback become current again.
    public func installIfEmpty(_ candidate: NSObject) -> NSObject? {
        lock.lock()
        if let bridge {
            lock.unlock()
            return bridge
        }
        guard generation < UInt64.max else {
            lock.unlock()
            return nil
        }
        generation += 1
        bridge = candidate
        ownerID = nil
        lock.unlock()
        return candidate
    }

    /// Exclusively reserves the exact bridge generation for one high-level
    /// initialize/transcribe attempt. A concurrent or late attempt must never
    /// share a bridge that another attempt can cancel.
    public func reserve(_ expected: NSObject, ownerID expectedOwnerID: String) -> UInt64? {
        lock.lock()
        guard bridge === expected, ownerID == nil else {
            lock.unlock()
            return nil
        }
        ownerID = expectedOwnerID
        let value = generation
        lock.unlock()
        return value
    }

    @discardableResult
    public func release(
        _ expected: NSObject,
        generation expectedGeneration: UInt64,
        ownerID expectedOwnerID: String
    ) -> Bool {
        lock.lock()
        guard bridge === expected,
              generation == expectedGeneration,
              ownerID == expectedOwnerID
        else {
            lock.unlock()
            return false
        }
        ownerID = nil
        lock.unlock()
        return true
    }

    @discardableResult
    public func retire(
        _ expected: NSObject,
        generation expectedGeneration: UInt64,
        ownerID expectedOwnerID: String
    ) -> Bool {
        lock.lock()
        guard bridge === expected,
              generation == expectedGeneration,
              ownerID == expectedOwnerID
        else {
            lock.unlock()
            return false
        }
        bridge = nil
        ownerID = nil
        lock.unlock()
        return true
    }

    /// Removes the current bridge and advances to a tombstone generation so
    /// callbacks from the removed generation cannot publish after Cleanup.
    public func invalidateAndTake() -> (bridge: NSObject?, generation: UInt64) {
        lock.lock()
        let value = bridge
        bridge = nil
        ownerID = nil
        if generation < UInt64.max {
            generation += 1
        }
        let invalidatedGeneration = generation
        lock.unlock()
        return (value, invalidatedGeneration)
    }

    public func generation(of expected: NSObject) -> UInt64? {
        lock.lock()
        let value = bridge === expected ? generation : nil
        lock.unlock()
        return value
    }

    public func latestGeneration() -> UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

}

/// Cancellation-safe ownership registration around a runtime bridge. The
/// outer task installs its cancellation handler before loading or reserving a
/// bridge. Cancellation is remembered when it wins first, so a late old task
/// cannot reserve and tear down the bridge installed by an immediate retry.
public final class RuntimeBridgeAttemptOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private let slot: RuntimeBridgeSlot
    private let ownerID = UUID().uuidString
    private var reservation: (bridge: NSObject, generation: UInt64)?
    private var isCancelled = false
    private var isReleased = false

    public init(slot: RuntimeBridgeSlot) {
        self.slot = slot
    }

    public var wasCancelled: Bool {
        lock.lock()
        let value = isCancelled
        lock.unlock()
        return value
    }

    /// Returns the reserved generation, or nil if cancellation/concurrent
    /// ownership won. Holding this lock makes pre-cancellation and reservation
    /// a single ordering decision.
    public func reserve(_ bridge: NSObject) -> UInt64? {
        lock.lock()
        guard !isCancelled, !isReleased, reservation == nil,
              let generation = slot.reserve(bridge, ownerID: ownerID)
        else {
            lock.unlock()
            return nil
        }
        reservation = (bridge, generation)
        lock.unlock()
        return generation
    }

    @discardableResult
    public func release() -> Bool {
        lock.lock()
        guard !isReleased, let reservation else {
            isReleased = true
            lock.unlock()
            return false
        }
        isReleased = true
        self.reservation = nil
        lock.unlock()

        return slot.release(
            reservation.bridge,
            generation: reservation.generation,
            ownerID: ownerID
        )
    }

    /// Atomically remembers cancellation and retires only this attempt's exact
    /// reservation. Cleanup is deliberately separate because native
    /// `cancelAttempt:` may synchronously resume and release the caller.
    public func beginCancellation() -> NSObject? {
        let owned: (bridge: NSObject, generation: UInt64)?
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return nil
        }
        isCancelled = true
        owned = reservation
        reservation = nil
        lock.unlock()

        guard let owned,
              slot.retire(
                  owned.bridge,
                  generation: owned.generation,
                  ownerID: ownerID
              )
        else {
            return nil
        }

        return owned.bridge
    }

    public func finishCancellation(_ retiredBridge: NSObject?) {
        guard let retiredBridge else { return }
        let selector = NSSelectorFromString("cleanupRuntime")
        guard retiredBridge.responds(to: selector),
              let method = retiredBridge.method(for: selector)
        else {
            return
        }
        typealias CleanupFunction = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(method, to: CleanupFunction.self)(retiredBridge, selector)
    }

    /// Idempotently retires and cleans the owned generation synchronously.
    public func cancel() {
        finishCancellation(beginCancellation())
    }
}

/// Main-actor state-publication fence. Register each newly reserved runtime
/// generation before its first visible state. Later writes are accepted only
/// for that exact generation, so a stale catch cannot overwrite Retry.
public struct RuntimeGenerationPublicationFence: Sendable {
    public private(set) var generation: UInt64?
    private var isInvalidated = false

    public init() {}

    @discardableResult
    public mutating func register(_ candidate: UInt64) -> Bool {
        if let generation, candidate < generation {
            return false
        }
        if generation == candidate, isInvalidated {
            return false
        }
        generation = candidate
        isInvalidated = false
        return true
    }

    @discardableResult
    public mutating func invalidate(_ candidate: UInt64) -> Bool {
        if let generation, candidate < generation {
            return false
        }
        generation = candidate
        isInvalidated = true
        return true
    }

    public func accepts(_ candidate: UInt64) -> Bool {
        generation == candidate && !isInvalidated
    }
}
