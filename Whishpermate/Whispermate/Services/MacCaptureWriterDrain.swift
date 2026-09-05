import Foundation

nonisolated enum MacCaptureWriterDrain {
    // The caller closes write admission and serializes native writer operations.
    static func finish<T>(
        condition: NSCondition,
        writesPending: () -> Bool,
        drain: () -> T,
        closeWriter: (T) -> Void
    ) {
        condition.lock()
        while writesPending() { condition.wait() }
        condition.unlock()

        // A producer's last callback may need this condition to report failure.
        let tail = drain()

        // Native file I/O must not hold the lock used by Stop and timeout.
        closeWriter(tail)
    }
}
