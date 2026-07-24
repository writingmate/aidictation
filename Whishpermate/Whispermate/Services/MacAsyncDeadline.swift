import Foundation

nonisolated enum MacNativeOperationDeadlineError: Error, Equatable {
    case timedOut
}

/// A one-shot bridge for native callback work that may ignore cancellation.
/// Timeout/cancellation resolve the Swift caller immediately and fence every
/// late callback; `cancelNative` is best effort and is never awaited.
nonisolated final class MacBoundedNativeOperation<Value: Sendable>: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Value, Error>) -> Void

    private let lock = NSLock()
    private let cancelNative: @Sendable () -> Void
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var resolved = false

    init(cancelNative: @escaping @Sendable () -> Void) {
        self.cancelNative = cancelNative
    }

    func run(
        timeoutNanoseconds: UInt64,
        start: @escaping @Sendable (@escaping Completion) -> Void
    ) async throws -> Value {
        let timeoutTask = Task.detached { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            self?.cancelNative()
            self?.resolve(.failure(MacNativeOperationDeadlineError.timedOut))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                start { [weak self] result in
                    self?.resolve(result)
                }
            }
        } onCancel: {
            self.cancelNative()
            self.resolve(.failure(CancellationError()))
        }
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return false
        }
        guard !resolved else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        guard let continuation else {
            pendingResult = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
