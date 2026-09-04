import Foundation

public nonisolated protocol RealtimeTranscriptionFinalizing: AnyObject, Sendable {
    func requestFinish(timeout: TimeInterval)
    func awaitFinish() async -> String?
    func close()
}

public nonisolated protocol RealtimeTranscriptionStreaming: RealtimeTranscriptionFinalizing {
    func start()
    func sendAudio(_ audioData: Data)
}

/// Attempt-scoped owner for one realtime stream finalization. It keeps the
/// transport alive after the recorder drops its weak audio handler and gives
/// every cancellation path one idempotent close operation.
public nonisolated final class RealtimeTranscriptionFinishRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let client: any RealtimeTranscriptionFinalizing
    private let resultTask: Task<String?, Never>
    private var isClosed = false
    private var didRequestFinish = false
    private var drainDeadlineTask: Task<Void, Never>?
    private var drainDeadlineGeneration: UInt64 = 0

    public init(client: any RealtimeTranscriptionFinalizing) {
        self.client = client
        resultTask = Task {
            await client.awaitFinish()
        }
    }

    /// Bounds the gap between key-up and the delivery queue's drain callback.
    /// A stuck conversion closes the stream so the durable source can use batch
    /// fallback instead of waiting forever.
    public func armDrainDeadline(timeout: TimeInterval) {
        lock.lock()
        guard !isClosed, !didRequestFinish else {
            lock.unlock()
            return
        }
        drainDeadlineGeneration &+= 1
        let generation = drainDeadlineGeneration
        let previousDeadline = drainDeadlineTask
        let deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000)
                )
            } catch {
                return
            }
            self?.expireDrainDeadline(generation: generation)
        }
        drainDeadlineTask = deadlineTask
        lock.unlock()
        previousDeadline?.cancel()
    }

    public func requestFinish(timeout: TimeInterval) {
        lock.lock()
        guard !isClosed, !didRequestFinish else {
            lock.unlock()
            return
        }
        didRequestFinish = true
        drainDeadlineGeneration &+= 1
        let drainDeadlineTask = self.drainDeadlineTask
        self.drainDeadlineTask = nil
        lock.unlock()
        drainDeadlineTask?.cancel()
        client.requestFinish(timeout: timeout)
    }

    public func finish() async -> String? {
        await withTaskCancellationHandler {
            return await resultTask.value
        } onCancel: { [weak self] in
            self?.close()
        }
    }

    public func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        drainDeadlineGeneration &+= 1
        let drainDeadlineTask = self.drainDeadlineTask
        self.drainDeadlineTask = nil
        lock.unlock()
        drainDeadlineTask?.cancel()
        client.close()
    }

    deinit {
        close()
    }

    private func expireDrainDeadline(generation: UInt64) {
        lock.lock()
        guard generation == drainDeadlineGeneration,
              !didRequestFinish,
              !isClosed
        else {
            lock.unlock()
            return
        }
        isClosed = true
        drainDeadlineGeneration &+= 1
        drainDeadlineTask = nil
        lock.unlock()
        client.close()
    }
}

/// Serializes converted realtime audio delivery and provides an atomic
/// detach-and-drain boundary.
///
/// Enqueueing a chunk and enqueueing the drain marker both happen while the
/// same lock is held. A capture callback that acquired the old handler must
/// therefore place its chunk before the marker; a callback that arrives after
/// detachment cannot place a chunk at all.
public nonisolated final class RealtimeAudioDeliveryQueue: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Void

    fileprivate enum DeliveryOutcome: Sendable {
        case delivered(Data)
        case discarded
        case coverageFailed
    }

    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var completion: (@Sendable (DeliveryOutcome) -> Void)?

        fileprivate init(
            completion: @escaping @Sendable (DeliveryOutcome) -> Void
        ) {
            self.completion = completion
        }

        public func deliver(_ chunk: Data) {
            finish(with: .delivered(chunk))
        }

        public func discard() {
            finish(with: .discarded)
        }

        /// The corresponding native buffer was written successfully, but its
        /// realtime representation could not be produced. This poisons the
        /// generation so its transcript can never be accepted as complete.
        public func failCoverage() {
            finish(with: .coverageFailed)
        }

        private func finish(with outcome: DeliveryOutcome) {
            lock.lock()
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            completion?(outcome)
        }

        deinit {
            discard()
        }
    }

    private final class Generation: @unchecked Sendable {
        let handler: Handler
        var inFlight = 0
        var isSealed = false
        var coverageIsComplete = true

        init(handler: @escaping Handler) {
            self.handler = handler
        }
    }

    private struct DrainRequest {
        let generations: [Generation]
        let completion: @Sendable (Bool) -> Void
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var activeGeneration: Generation?
    private var sealedGenerations: [Generation] = []
    private var pendingDrainRequests: [DrainRequest] = []

    public init(label: String = "ai.writingmate.realtime-audio") {
        queue = DispatchQueue(label: label)
    }

    public var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeGeneration?.handler
        }
        set {
            lock.lock()
            sealActiveGenerationLocked()
            if let newValue {
                activeGeneration = Generation(handler: newValue)
            }
            lock.unlock()
        }
    }

    /// Reserves one delivery before the caller begins converting its capture
    /// buffer. Detachment seals the generation but waits for every reserved
    /// lease, so conversion that was already in flight cannot lose the tail.
    public func beginDelivery() -> Lease? {
        lock.lock()
        guard let generation = activeGeneration,
              !generation.isSealed
        else {
            lock.unlock()
            return nil
        }
        generation.inFlight += 1
        lock.unlock()

        return Lease { [weak self, generation] outcome in
            self?.finishDelivery(outcome, generation: generation)
        }
    }

    public func detachAndDrain(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        sealActiveGenerationLocked()
        let generations = sealedGenerations
        guard !generations.isEmpty else {
            queue.async {
                completion(true)
            }
            lock.unlock()
            return
        }
        pendingDrainRequests.append(
            DrainRequest(generations: generations, completion: completion)
        )
        enqueueReadyDrainsLocked()
        lock.unlock()
    }

    private func finishDelivery(
        _ outcome: DeliveryOutcome,
        generation: Generation
    ) {
        lock.lock()
        guard generation.inFlight > 0 else {
            lock.unlock()
            return
        }
        switch outcome {
        case .delivered(let chunk):
            if !chunk.isEmpty {
                let handler = generation.handler
                queue.async {
                    handler(chunk)
                }
            } else {
                generation.coverageIsComplete = false
            }
        case .coverageFailed:
            generation.coverageIsComplete = false
        case .discarded:
            break
        }
        generation.inFlight -= 1
        enqueueReadyDrainsLocked()
        lock.unlock()
    }

    private func sealActiveGenerationLocked() {
        guard let generation = activeGeneration else { return }
        generation.isSealed = true
        sealedGenerations.append(generation)
        activeGeneration = nil
    }

    private func enqueueReadyDrainsLocked() {
        var ready: [DrainRequest] = []
        pendingDrainRequests.removeAll { request in
            let isReady = request.generations.allSatisfy {
                $0.isSealed && $0.inFlight == 0
            }
            if isReady {
                ready.append(request)
            }
            return isReady
        }
        guard !ready.isEmpty else { return }

        let stillReferenced = Set(
            pendingDrainRequests.flatMap(\.generations).map(ObjectIdentifier.init)
        )
        let drained = Set(
            ready.flatMap(\.generations).map(ObjectIdentifier.init)
        )
        sealedGenerations.removeAll {
            let identity = ObjectIdentifier($0)
            return drained.contains(identity) && !stillReferenced.contains(identity)
        }
        for request in ready {
            let completion = request.completion
            let coverageIsComplete = request.generations.allSatisfy(
                \.coverageIsComplete
            )
            queue.async {
                completion(coverageIsComplete)
            }
        }
    }
}

/// Resolves one idempotent realtime finalization attempt on its owning serial
/// queue. Finalization may begin before its consumer starts waiting.
///
/// The generation check prevents a cancelled timeout from resolving a later
/// attempt. A stored terminal outcome lets the durable-audio pipeline await an
/// already-started stream without issuing a second commit.
public nonisolated final class RealtimeTranscriptionFinishGate: @unchecked Sendable {
    private enum Outcome {
        case resolved(String?)
    }

    private let queue: DispatchQueue
    private var continuations: [CheckedContinuation<String?, Never>] = []
    private var timeoutWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var didBegin = false
    private var outcome: Outcome?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Clears the previous attempt after resolving any abandoned waiter.
    public func reset() {
        requireOwningQueue()
        generation &+= 1
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let abandoned = continuations
        continuations.removeAll()
        didBegin = false
        outcome = nil
        abandoned.forEach { $0.resume(returning: nil) }
    }

    @discardableResult
    public func begin(
        timeout: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void
    ) -> Bool {
        requireOwningQueue()
        guard !didBegin, outcome == nil else { return false }

        didBegin = true
        generation &+= 1
        let activeGeneration = generation

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.requireOwningQueue()
            guard self.generation == activeGeneration,
                  self.outcome == nil
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
        return true
    }

    public func wait(_ continuation: CheckedContinuation<String?, Never>) {
        requireOwningQueue()
        if case .resolved(let transcript) = outcome {
            continuation.resume(returning: transcript)
            return
        }
        continuations.append(continuation)
    }

    @discardableResult
    public func resolve(with transcript: String?) -> Bool {
        requireOwningQueue()
        guard outcome == nil else { return false }

        outcome = .resolved(transcript)
        generation &+= 1
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let waiting = continuations
        continuations.removeAll()
        waiting.forEach { $0.resume(returning: transcript) }
        return true
    }

    private func requireOwningQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
