import Foundation

nonisolated enum MacCaptureWriterDrain {
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

        condition.lock()
        closeWriter(tail)
        condition.unlock()
    }
}
