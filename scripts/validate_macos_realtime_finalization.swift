import Foundation

private nonisolated final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private nonisolated final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private nonisolated final class HangingFinalizer: @unchecked Sendable, RealtimeTranscriptionFinalizing {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var closed = false
    private var storedRequestCount = 0
    private var storedCloseCount = 0
    private var storedFinishStarted = false

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCount
    }

    var finishStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedFinishStarted
    }

    func requestFinish(timeout _: TimeInterval) {
        lock.lock()
        storedRequestCount += 1
        lock.unlock()
    }

    func awaitFinish() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            storedFinishStarted = true
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        storedCloseCount += 1
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}

private func beginFinish(
    gate: RealtimeTranscriptionFinishGate,
    queue: DispatchQueue,
    timeout: TimeInterval,
    timeoutCounter: LockedCounter,
    reset: Bool = true
) async -> Bool {
    await withCheckedContinuation { continuation in
        queue.async {
            if reset {
                gate.reset()
            }
            let began = gate.begin(timeout: timeout) {
                timeoutCounter.increment()
            }
            continuation.resume(returning: began)
        }
    }
}

private func resolveFinish(
    gate: RealtimeTranscriptionFinishGate,
    queue: DispatchQueue,
    transcript: String?
) async -> Bool {
    await withCheckedContinuation { continuation in
        queue.async {
            continuation.resume(returning: gate.resolve(with: transcript))
        }
    }
}

private func waitForFinish(
    gate: RealtimeTranscriptionFinishGate,
    queue: DispatchQueue
) async -> String? {
    await withCheckedContinuation { continuation in
        queue.async {
            gate.wait(continuation)
        }
    }
}

private func waitForSignal(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

@main
struct ValidateMacOSRealtimeFinalization {
    static func main() async throws {
        var recovery = MacCaptureRecoveryPolicy()
        precondition(recovery.begin(maximumAttempts: 2) == 1)
        precondition(recovery.begin(maximumAttempts: 2) == nil)
        recovery.finish()
        precondition(recovery.begin(maximumAttempts: 2) == 2)
        recovery.finish()
        precondition(recovery.isExhausted(maximumAttempts: 2))
        recovery.noteHealthyBuffer()
        precondition(recovery.begin(maximumAttempts: 2) == 1)
        recovery.finish()

        let queue = DispatchQueue(label: "realtime-finish-validator")
        let gate = RealtimeTranscriptionFinishGate(queue: queue)

        let completionTimeouts = LockedCounter()
        let didBeginCompletion = await beginFinish(
            gate: gate,
            queue: queue,
            timeout: 0.05,
            timeoutCounter: completionTimeouts
        )
        precondition(didBeginCompletion)
        let didBeginDuplicate = await beginFinish(
            gate: gate,
            queue: queue,
            timeout: 0.05,
            timeoutCounter: completionTimeouts,
            reset: false
        )
        precondition(!didBeginDuplicate)
        let didResolveCompletion = await resolveFinish(
            gate: gate,
            queue: queue,
            transcript: "complete"
        )
        precondition(didResolveCompletion)
        let didResolveLateCompletion = await resolveFinish(
            gate: gate,
            queue: queue,
            transcript: "late"
        )
        precondition(!didResolveLateCompletion)
        let completed = await waitForFinish(gate: gate, queue: queue)
        precondition(completed == "complete")
        try await Task.sleep(for: .milliseconds(60))
        precondition(completionTimeouts.value == 0)

        let pendingTimeouts = LockedCounter()
        let didBeginTimeout = await beginFinish(
            gate: gate,
            queue: queue,
            timeout: 0.01,
            timeoutCounter: pendingTimeouts
        )
        precondition(didBeginTimeout)
        try await Task.sleep(for: .milliseconds(30))
        let timedOut = await waitForFinish(gate: gate, queue: queue)
        precondition(timedOut == nil)
        precondition(pendingTimeouts.value == 1)
        let didResolveAfterTimeout = await resolveFinish(
            gate: gate,
            queue: queue,
            transcript: "incomplete"
        )
        precondition(!didResolveAfterTimeout)

        let closeTimeouts = LockedCounter()
        let didBeginClose = await beginFinish(
            gate: gate,
            queue: queue,
            timeout: 0.05,
            timeoutCounter: closeTimeouts
        )
        precondition(didBeginClose)
        let didResolveClose = await resolveFinish(gate: gate, queue: queue, transcript: nil)
        precondition(didResolveClose)
        let closed = await waitForFinish(gate: gate, queue: queue)
        precondition(closed == nil)
        try await Task.sleep(for: .milliseconds(60))
        precondition(closeTimeouts.value == 0)

        let delivery = RealtimeAudioDeliveryQueue(label: "realtime-tail-validator")
        let orderedEvents = LockedEvents()
        delivery.handler = { chunk in
            orderedEvents.append("audio-\(chunk.first ?? 0)")
        }
        let firstTail = delivery.beginDelivery()
        let secondTail = delivery.beginDelivery()
        precondition(firstTail != nil && secondTail != nil)
        let drained = DispatchSemaphore(value: 0)
        delivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            orderedEvents.append("finish")
            drained.signal()
        }
        precondition(delivery.beginDelivery() == nil)
        precondition(!waitForSignal(drained, timeout: 0.01))
        firstTail?.deliver(Data([1]))
        secondTail?.deliver(Data([2]))
        precondition(waitForSignal(drained, timeout: 1))
        precondition(orderedEvents.value == ["audio-1", "audio-2", "finish"])

        // Key-up captures the finish request but leaves delivery open until
        // native stop retires durable write admission. A callback beginning in
        // that gap is therefore still part of the shared cutoff and must drain.
        let gapDelivery = RealtimeAudioDeliveryQueue(label: "realtime-keyup-stop-gap-validator")
        let gapEvents = LockedEvents()
        gapDelivery.handler = { chunk in
            gapEvents.append("gap-audio-\(chunk.first ?? 0)")
        }
        // Key-up: request ownership changes, but the delivery generation stays open.
        let keyUpToStopTail = gapDelivery.beginDelivery()
        precondition(keyUpToStopTail != nil)
        let gapDrained = DispatchSemaphore(value: 0)
        // Native stop: durable admission is retired immediately before this seal.
        gapDelivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            gapEvents.append("finish")
            gapDrained.signal()
        }
        precondition(!waitForSignal(gapDrained, timeout: 0.01))
        keyUpToStopTail?.deliver(Data([9]))
        precondition(waitForSignal(gapDrained, timeout: 1))
        precondition(gapEvents.value == ["gap-audio-9", "finish"])

        let discardDelivery = RealtimeAudioDeliveryQueue(label: "realtime-discard-validator")
        discardDelivery.handler = { _ in }
        let discarded = discardDelivery.beginDelivery()
        let discardDrained = DispatchSemaphore(value: 0)
        discardDelivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            discardDrained.signal()
        }
        precondition(!waitForSignal(discardDrained, timeout: 0.01))
        discarded?.discard()
        precondition(waitForSignal(discardDrained, timeout: 1))

        let repeatedDelivery = RealtimeAudioDeliveryQueue(label: "realtime-repeat-validator")
        let repeatedEvents = LockedEvents()
        repeatedDelivery.handler = { chunk in
            repeatedEvents.append("audio-\(chunk.first ?? 0)")
        }
        let repeatedTail = repeatedDelivery.beginDelivery()
        let firstDrain = DispatchSemaphore(value: 0)
        let secondDrain = DispatchSemaphore(value: 0)
        repeatedDelivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            repeatedEvents.append("finish-1")
            firstDrain.signal()
        }
        repeatedDelivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            repeatedEvents.append("finish-2")
            secondDrain.signal()
        }
        precondition(!waitForSignal(firstDrain, timeout: 0.01))
        precondition(!waitForSignal(secondDrain, timeout: 0.01))
        repeatedTail?.deliver(Data([3]))
        precondition(waitForSignal(firstDrain, timeout: 1))
        precondition(waitForSignal(secondDrain, timeout: 1))
        precondition(repeatedEvents.value == ["audio-3", "finish-1", "finish-2"])

        let replacementDelivery = RealtimeAudioDeliveryQueue(label: "realtime-replace-validator")
        let replacementEvents = LockedEvents()
        replacementDelivery.handler = { _ in replacementEvents.append("old") }
        let oldLease = replacementDelivery.beginDelivery()
        replacementDelivery.handler = { _ in replacementEvents.append("new") }
        let newLease = replacementDelivery.beginDelivery()
        let replacementDrained = DispatchSemaphore(value: 0)
        replacementDelivery.detachAndDrain { coverageIsComplete in
            precondition(coverageIsComplete)
            replacementEvents.append("finish")
            replacementDrained.signal()
        }
        oldLease?.deliver(Data([1]))
        precondition(!waitForSignal(replacementDrained, timeout: 0.01))
        newLease?.deliver(Data([2]))
        precondition(waitForSignal(replacementDrained, timeout: 1))
        precondition(replacementEvents.value == ["old", "new", "finish"])

        // A native-success buffer whose realtime conversion fails poisons the
        // entire generation. Earlier valid chunks may have streamed, but the
        // drain result must force the caller onto complete-file batch fallback.
        let poisonedDelivery = RealtimeAudioDeliveryQueue(label: "realtime-poison-validator")
        let poisonedEvents = LockedEvents()
        poisonedDelivery.handler = { _ in poisonedEvents.append("audio") }
        let validLease = poisonedDelivery.beginDelivery()
        let failedConversionLease = poisonedDelivery.beginDelivery()
        validLease?.deliver(Data([1]))
        failedConversionLease?.failCoverage()
        let poisonedClient = HangingFinalizer()
        let poisonedRequest = RealtimeTranscriptionFinishRequest(client: poisonedClient)
        let poisonDrained = DispatchSemaphore(value: 0)
        poisonedDelivery.detachAndDrain { coverageIsComplete in
            poisonedEvents.append(coverageIsComplete ? "complete" : "incomplete")
            if coverageIsComplete {
                poisonedRequest.requestFinish(timeout: 1)
            } else {
                poisonedRequest.close()
            }
            poisonDrained.signal()
        }
        precondition(waitForSignal(poisonDrained, timeout: 1))
        precondition(poisonedEvents.value == ["audio", "incomplete"])
        let poisonedResult = await poisonedRequest.finish()
        precondition(poisonedResult == nil)
        precondition(poisonedClient.requestCount == 0)
        precondition(poisonedClient.closeCount == 1)

        let hangingClient = HangingFinalizer()
        let request = RealtimeTranscriptionFinishRequest(client: hangingClient)
        let waitingTask = Task {
            await request.finish()
        }
        while !hangingClient.finishStarted {
            await Task.yield()
        }
        waitingTask.cancel()
        let cancelledResult = await waitingTask.value
        precondition(cancelledResult == nil)
        precondition(hangingClient.closeCount == 1)

        let deadlineClient = HangingFinalizer()
        let deadlineRequest = RealtimeTranscriptionFinishRequest(client: deadlineClient)
        deadlineRequest.armDrainDeadline(timeout: 0.01)
        let deadlineResult = await deadlineRequest.finish()
        precondition(deadlineResult == nil)
        precondition(deadlineClient.closeCount == 1)
        precondition(deadlineClient.requestCount == 0)

        // If requestFinish wins the same instant a zero-delay drain deadline
        // wakes, the stale deadline must not close the newly started commit.
        for _ in 0 ..< 200 {
            let racingClient = HangingFinalizer()
            let racingRequest = RealtimeTranscriptionFinishRequest(client: racingClient)
            racingRequest.armDrainDeadline(timeout: 0)
            racingRequest.requestFinish(timeout: 1)
            await Task.yield()
            if racingClient.requestCount == 1 {
                precondition(racingClient.closeCount == 0)
            }
            racingRequest.close()
        }

        let lateClient = HangingFinalizer()
        let lateRequest = RealtimeTranscriptionFinishRequest(client: lateClient)
        let lateDelivery = RealtimeAudioDeliveryQueue(label: "realtime-late-validator")
        lateDelivery.handler = { _ in }
        let lateLease = lateDelivery.beginDelivery()
        let lateDrain = DispatchSemaphore(value: 0)
        lateDelivery.detachAndDrain { _ in
            lateRequest.requestFinish(timeout: 1)
            lateDrain.signal()
        }
        lateRequest.close()
        lateLease?.deliver(Data([4]))
        precondition(waitForSignal(lateDrain, timeout: 1))
        precondition(lateClient.closeCount == 1)
        precondition(lateClient.requestCount == 0)

        let clientSource = try String(
            contentsOfFile: "Whishpermate/Whispermate/Services/OpenAIRealtimeTranscriptionClient.swift",
            encoding: .utf8
        )
        precondition(clientSource.contains("func requestFinish(timeout: TimeInterval = 1.5)"))
        precondition(clientSource.contains("guard !didRequestFinish else { return }"))
        precondition(clientSource.contains("func awaitFinish() async -> String?"))
        precondition(clientSource.contains("self.finishGate.wait(continuation)"))
        precondition(!clientSource.contains("self.beginFinishOnQueue(timeout: timeout)\n                self.finishGate.wait"))
        precondition(clientSource.contains("guard !self.isClosed, !self.didRequestFinish else { return }"))
        precondition(clientSource.contains("authorizationTask?.cancel()"))
        precondition(clientSource.contains("Realtime finish timeout elapsed; discarding unproven stream"))
        precondition(clientSource.contains("trackedItemIDs.isSubset(of: completedItemIDs)"))
        precondition(clientSource.contains("failOnQueue(\"Realtime commit acknowledgement was missing its item ID\")"))
        precondition(clientSource.contains("self.fail(\"OpenAI Realtime send failed:"))
        precondition(!clientSource.contains("finalTranscript ?? currentTranscript"))

        let recorderSource = try String(
            contentsOfFile: "Whishpermate/Whispermate/Services/AudioRecorder.swift",
            encoding: .utf8
        )
        let leasePosition = recorderSource.range(
            of: "let realtimeDeliveryLease = realtimeAudioDelivery.beginDelivery()"
        )?.lowerBound
        let writePosition = recorderSource.range(
            of: "guard let writeResult = autoreleasepool"
        )?.lowerBound
        precondition(leasePosition != nil && writePosition != nil && leasePosition! < writePosition!)
        precondition(recorderSource.contains("defer { realtimeDeliveryLease?.discard() }"))
        precondition(!recorderSource.contains("guard session.isActive else { return }"))

        let appStateSource = try String(
            contentsOfFile: "Whishpermate/Whispermate/Services/AppState.swift",
            encoding: .utf8
        )
        precondition(appStateSource.contains("drainDeadline: shouldFinishRealtime ? realtimeFinishTimeout : nil"))
        precondition(appStateSource.contains("snapshot?.outputMode == .dictation"))
        precondition(appStateSource.contains("snapshot?.transcriptionOptions.diarization == false"))
        precondition(appStateSource.contains("let afterRealtimeAudioDrained: (@Sendable (Bool) -> Void)?"))
        precondition(appStateSource.contains("afterRealtimeAudioDrained: afterRealtimeAudioDrained"))
        precondition(appStateSource.contains("if coverageIsComplete {"))
        precondition(appStateSource.contains("realtimeFinishRequest?.close()"))
        let storeFinalizationPosition = appStateSource.range(
            of: "let finalizing = try await store.beginFinalization("
        )?.lowerBound
        let nativeStopPosition = appStateSource.range(
            of: "self.audioRecorder.stopRecording(\n                    disposition: disposition,"
        )?.lowerBound
        precondition(
            storeFinalizationPosition != nil
                && nativeStopPosition != nil
                && storeFinalizationPosition! < nativeStopPosition!
        )
        let takeStart = appStateSource.range(
            of: "private func takeRealtimeTranscription("
        )?.lowerBound
        let stopHelperStart = appStateSource.range(
            of: "private func stopRealtimeTranscription()"
        )?.lowerBound
        precondition(takeStart != nil && stopHelperStart != nil)
        let takeHelper = String(appStateSource[takeStart! ..< stopHelperStart!])
        precondition(!takeHelper.contains("detachRealtimeAudioChunkHandlerAndDrain"))
        let realtimeStartPosition = appStateSource.range(
            of: "startRealtimeTranscriptionIfAvailable(\n                recordingID: recordingID,"
        )?.lowerBound
        let recorderStartPosition = appStateSource.range(
            of: "audioRecorder.startRecording(\n                recordingID: attemptID,"
        )?.lowerBound
        precondition(
            realtimeStartPosition != nil
                && recorderStartPosition != nil
                && realtimeStartPosition! < recorderStartPosition!
        )
        precondition(
            appStateSource.components(
                separatedBy: "startRealtimeTranscriptionIfAvailable("
            ).count == 3
        )
        precondition(appStateSource.contains("snapshot.outputMode != .dictation || snapshot.transcriptionOptions.diarization"))
        precondition(appStateSource.contains(
            "case .failed(let message):\n            closeLiveRealtimeTranscription()"
        ))
        precondition(appStateSource.contains(
            "let lease = activeCaptureLease\n        closeLiveRealtimeTranscription()"
        ))
        precondition(appStateSource.contains(
            "recordingState = .finalizing\n        closeLiveRealtimeTranscription()"
        ))
        precondition(appStateSource.contains(
            "private func closeLiveRealtimeTranscription()"
        ))
        precondition(appStateSource.contains("closeActiveRealtimeFinishRequest()"))
        precondition(appStateSource.contains("defer { finishRealtimeRequest(realtimeFinishRequest) }"))

        let recorderStopStart = recorderSource.range(
            of: "func stopRecording(\n        disposition: StopDisposition"
        )?.lowerBound
        let recorderStopEnd = recorderSource.range(
            of: "private func finishFinalization("
        )?.lowerBound
        precondition(recorderStopStart != nil && recorderStopEnd != nil)
        let recorderStop = String(
            recorderSource[recorderStopStart! ..< recorderStopEnd!]
        )
        let retirePosition = recorderStop.range(of: "session.retire()")?.lowerBound
        let recorderDrainPosition = recorderStop.range(
            of: "realtimeAudioDelivery.detachAndDrain { coverageIsComplete in\n            afterRealtimeAudioDrained?(coverageIsComplete)"
        )?.lowerBound
        precondition(
            retirePosition != nil
                && recorderDrainPosition != nil
                && retirePosition! < recorderDrainPosition!
        )
        precondition(recorderSource.contains("realtimeDeliveryLease.failCoverage()"))
        precondition(recorderSource.contains("captureRecoveryDelays: [TimeInterval] = [0.15, 0.5]"))
        precondition(recorderSource.contains("session.replaceEngine(engine)"))
        precondition(recorderSource.contains("session.accepts(engine: engine, generation: replacement.generation)"))
        precondition(recorderSource.contains("self.attemptCaptureRecovery(session, reason: \"recovery start failed\")"))

        print("macOS realtime finalization covers the durable stream, starts once, and fails closed")
    }
}
