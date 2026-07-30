import Foundation

private final class LockedCounter: @unchecked Sendable {
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

private func waitForFinish(
    gate: RealtimeTranscriptionFinishGate,
    queue: DispatchQueue,
    timeout: TimeInterval,
    timeoutCounter: LockedCounter
) async -> String? {
    await withCheckedContinuation { continuation in
        queue.async {
            gate.begin(
                timeout: timeout,
                continuation: continuation,
                onTimeout: {
                    timeoutCounter.increment()
                }
            )
        }
    }
}

@main
struct ValidateMacOSRealtimeFinalization {
    static func main() async throws {
        let queue = DispatchQueue(label: "realtime-finish-validator")
        let gate = RealtimeTranscriptionFinishGate(queue: queue)

        let completionTimeouts = LockedCounter()
        queue.asyncAfter(deadline: .now() + 0.01) {
            precondition(gate.resolve(with: "complete"))
            precondition(!gate.resolve(with: "late"))
        }
        let completed = await waitForFinish(
            gate: gate,
            queue: queue,
            timeout: 0.05,
            timeoutCounter: completionTimeouts
        )
        precondition(completed == "complete")
        try await Task.sleep(for: .milliseconds(60))
        precondition(completionTimeouts.value == 0)

        let closeTimeouts = LockedCounter()
        queue.asyncAfter(deadline: .now() + 0.01) {
            precondition(gate.resolve(with: nil))
            precondition(!gate.resolve(with: "partial"))
        }
        let closed = await waitForFinish(
            gate: gate,
            queue: queue,
            timeout: 0.05,
            timeoutCounter: closeTimeouts
        )
        precondition(closed == nil)
        try await Task.sleep(for: .milliseconds(60))
        precondition(closeTimeouts.value == 0)

        let pendingTimeouts = LockedCounter()
        let timedOut = await waitForFinish(
            gate: gate,
            queue: queue,
            timeout: 0.01,
            timeoutCounter: pendingTimeouts
        )
        precondition(timedOut == nil)
        precondition(pendingTimeouts.value == 1)

        let clientSource = try String(
            contentsOfFile: "Whishpermate/Whispermate/Services/OpenAIRealtimeTranscriptionClient.swift",
            encoding: .utf8
        )
        precondition(clientSource.contains(
            "func finish(timeout: TimeInterval = 1.5) async -> String? {\n"
                + "        return await withCheckedContinuation { continuation in\n"
                + "            sendQueue.async"
        ))
        precondition(clientSource.contains(
            "guard self.isTransportDrained, let finalTranscript = self.finalTranscript"
        ) || clientSource.contains(
            "if self.isTransportDrained, let finalTranscript = self.finalTranscript"
        ))
        precondition(clientSource.contains(
            "trackedItemIDs.isSubset(of: completedItemIDs)"
        ))
        precondition(clientSource.contains(
            "self.abandonTransportOnQueue()\n"
                + "            self.finishGate.resolve(with: nil)"
        ))
        precondition(clientSource.contains(
            "Realtime finish timeout elapsed; discarding unproven stream"
        ))
        precondition(clientSource.contains(
            "context: \"OpenAIRealtime\"\n"
                + "                    )\n"
                + "                    self.abandonTransportOnQueue()"
        ))
        precondition(clientSource.contains(
            "self.sendQueue.async { [weak self] in\n"
                + "                guard let self, !self.isClosed else { return }"
        ))
        precondition(clientSource.contains(
            "failOnQueue(\"Realtime commit acknowledgement was missing its item ID\")"
        ))
        precondition(clientSource.contains(
            "self.fail(\"OpenAI Realtime send failed:"
        ))
        precondition(clientSource.contains(
            "failedMessage = message\n"
                + "        DebugLog.warning"
        ))
        precondition(clientSource.contains(
            "abandonTransportOnQueue()\n"
                + "        finishGate.resolve(with: nil)"
        ))
        precondition(clientSource.contains(
            "guard !self.isClosed else { return }"
        ))
        precondition(!clientSource.contains("finalTranscript ?? currentTranscript"))
        precondition(!clientSource.contains("resumeFinishIfNeeded"))

        print("macOS realtime finalization is queue-confined and fails closed")
    }
}
