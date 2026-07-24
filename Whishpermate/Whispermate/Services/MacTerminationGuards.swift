import Foundation

/// Stable proof that one exact native capture writer has released its file.
/// The object survives preparation → active → finalization handoffs, closing
/// the gap where no public AudioRecorder slot otherwise owns the writer.
nonisolated final class MacNativeRecorderCloseProof: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isConfirmedClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func confirmClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func waitUntilConfirmed(deadline: Date) async -> Bool {
        while !isConfirmedClosed {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }
}

/// Ensures AppKit receives exactly one reply for each terminate-later request.
/// Repeated Quit events while one request is pending reuse the in-flight request
/// instead of consuming native-close ownership or replying twice.
@MainActor
final class MacTerminationReplyGuard {
    struct Token: Equatable {
        fileprivate let rawValue: UUID
    }

    private var pendingToken: Token?

    var isPending: Bool { pendingToken != nil }

    func begin() -> Token? {
        guard pendingToken == nil else { return nil }
        let token = Token(rawValue: UUID())
        pendingToken = token
        return token
    }

    func resolve(_ token: Token) -> Bool {
        guard pendingToken == token else { return false }
        pendingToken = nil
        return true
    }
}
