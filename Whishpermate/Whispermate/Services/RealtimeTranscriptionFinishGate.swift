import Foundation

/// Resolves one realtime finalization attempt on its owning serial queue.
///
/// The generation check prevents a cancelled timeout from resolving a later
/// attempt, while `resolve` guarantees that completion, timeout, failure, and
/// close can race without resuming a continuation more than once.
final class RealtimeTranscriptionFinishGate: @unchecked Sendable {
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func begin(
        timeout: TimeInterval,
        continuation: CheckedContinuation<String?, Never>,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        requireOwningQueue()
        guard self.continuation == nil else {
            continuation.resume(returning: nil)
            return
        }

        generation &+= 1
        let activeGeneration = generation
        self.continuation = continuation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.requireOwningQueue()
            guard self.generation == activeGeneration,
                  self.continuation != nil
            else {
                return
            }
            onTimeout()
            self.resolve(with: nil)
        }
        timeoutWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + max(0, timeout),
            execute: workItem
        )
    }

    @discardableResult
    func resolve(with transcript: String?) -> Bool {
        requireOwningQueue()
        guard let continuation else { return false }

        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        continuation.resume(returning: transcript)
        return true
    }

    private func requireOwningQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
