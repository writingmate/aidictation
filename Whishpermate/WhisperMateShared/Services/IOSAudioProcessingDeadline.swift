import Foundation
import Combine

public enum IOSAudioProcessingDeadlineError: LocalizedError, Equatable, Sendable {
    case timedOut
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "This is taking too long. Your recording was kept."
        case .cancelled:
            return "Processing cancelled."
        }
    }
}

/// Returns at the deadline even if native or networking work ignores task cancellation.
/// The abandoned operation may finish later, so callers must additionally fence state changes
/// with their durable attempt lease.
public enum IOSAudioProcessingDeadline {
    public static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let deadlineNanoseconds = try deadlineNanoseconds(for: seconds)
        let resolver = IOSAudioDeadlineResolver<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolver.install(continuation)

                let operationTask = Task {
                    do {
                        resolver.resolve(.success(try await operation()))
                    } catch is CancellationError {
                        resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
                    } catch {
                        resolver.resolve(.failure(error))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanoseconds)
                        resolver.resolve(.failure(IOSAudioProcessingDeadlineError.timedOut))
                    } catch {
                        // The winning operation cancels this timer.
                    }
                }

                resolver.setTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
        }
    }

    /// Main-actor variant for UI-owned services that are intentionally not `Sendable`.
    @MainActor
    public static func runOnMainActor<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let deadlineNanoseconds = try deadlineNanoseconds(for: seconds)
        let resolver = IOSAudioDeadlineResolver<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolver.install(continuation)

                let operationTask = Task { @MainActor in
                    do {
                        resolver.resolve(.success(try await operation()))
                    } catch is CancellationError {
                        resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
                    } catch {
                        resolver.resolve(.failure(error))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: deadlineNanoseconds)
                        resolver.resolve(.failure(IOSAudioProcessingDeadlineError.timedOut))
                    } catch {
                        // The winning operation cancels this timer.
                    }
                }

                resolver.setTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            resolver.resolve(.failure(IOSAudioProcessingDeadlineError.cancelled))
        }
    }

    private static func deadlineNanoseconds(for seconds: TimeInterval) throws -> UInt64 {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        guard seconds.isFinite, seconds > 0, seconds <= maximumSeconds else {
            throw IOSAudioProcessingDeadlineError.timedOut
        }
        return UInt64(seconds * 1_000_000_000)
    }
}

/// Owns a replaceable generation of a native resource. If a native start/stop call wedges its
/// private queue, callers retire that exact generation and immediately use a fresh one; late work
/// remains confined to the abandoned instance.
@MainActor
public final class IOSRetirableResourceSlot<Resource: AnyObject>: ObservableObject {
    @Published public private(set) var current: Resource
    private let factory: @MainActor () -> Resource

    public init(factory: @escaping @MainActor () -> Resource) {
        self.factory = factory
        current = factory()
    }

    @discardableResult
    public func retire(ifCurrent expected: Resource) -> Resource {
        guard current === expected else { return current }
        current = factory()
        return current
    }
}

/// Serializes ownership of a process-wide native resource across otherwise independent object
/// generations. A retired generation can release its private resources, but it cannot tear down
/// a shared resource after a replacement has claimed ownership.
public final class IOSExclusiveResourceOwnership<Resource: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var currentOwner: Resource?

    public init() {}

    public func claim(
        _ owner: Resource,
        activate: () throws -> Void
    ) rethrows {
        lock.lock()
        defer { lock.unlock() }
        try activate()
        currentOwner = owner
    }

    @discardableResult
    public func relinquish(
        _ owner: Resource,
        deactivate: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard currentOwner === owner else { return false }
        try deactivate()
        currentOwner = nil
        return true
    }
}

private final class IOSAudioDeadlineResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingResult: Result<Value, Error>?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        if resolved {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        let continuation = continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
