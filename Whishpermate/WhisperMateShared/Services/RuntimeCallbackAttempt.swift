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
    private let bridgeSlot: RuntimeBridgeSlot?
    private let attemptID: NSString
    private var didCancel = false

    public init(
        bridge: NSObject,
        attemptID: String,
        bridgeSlot: RuntimeBridgeSlot? = nil
    ) {
        self.bridge = bridge
        self.attemptID = attemptID as NSString
        self.bridgeSlot = bridgeSlot
    }

    public func cancel() {
        lock.lock()
        guard !didCancel else {
            lock.unlock()
            return
        }
        didCancel = true
        lock.unlock()

        let selector = NSSelectorFromString("cancelAttempt:")
        if bridge.responds(to: selector),
           let method = bridge.method(for: selector) {
            typealias Function = @convention(c) (AnyObject, Selector, NSString) -> Void
            unsafeBitCast(method, to: Function.self)(bridge, selector, attemptID)
        }

        guard bridgeSlot?.retire(bridge) == true else { return }
        let cleanupSelector = NSSelectorFromString("cleanupRuntime")
        guard bridge.responds(to: cleanupSelector),
              let cleanupMethod = bridge.method(for: cleanupSelector)
        else {
            return
        }
        typealias CleanupFunction = @convention(c) (AnyObject, Selector) -> Void
        unsafeBitCast(cleanupMethod, to: CleanupFunction.self)(bridge, cleanupSelector)
    }
}

/// Atomic owner of the currently usable runtime generation. Cancellation can
/// retire a generation synchronously from a cancellation handler, before the
/// UI exposes Retry, while ignored native work remains isolated on the old
/// bridge object.
public final class RuntimeBridgeSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var bridge: NSObject?

    public init() {}

    public func current() -> NSObject? {
        lock.lock()
        let value = bridge
        lock.unlock()
        return value
    }

    public func installIfEmpty(_ candidate: NSObject) -> NSObject {
        lock.lock()
        if let bridge {
            lock.unlock()
            return bridge
        }
        bridge = candidate
        lock.unlock()
        return candidate
    }

    @discardableResult
    public func retire(_ expected: NSObject) -> Bool {
        lock.lock()
        guard bridge === expected else {
            lock.unlock()
            return false
        }
        bridge = nil
        lock.unlock()
        return true
    }

    public func take() -> NSObject? {
        lock.lock()
        let value = bridge
        bridge = nil
        lock.unlock()
        return value
    }
}
