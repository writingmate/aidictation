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

/// Separates safe UI settlement from permission to terminate. Once every
/// native writer is confirmed closed, recording controls must become usable
/// again even when the terminal journal update failed. The current Quit is
/// still refused so the storage warning remains visible and the recoverable
/// source stays available.
nonisolated struct MacTerminationSettlement: Equatable, Sendable {
    static let storageWarning =
        "Your recording was kept, but its status could not be saved. Please try again."

    let shouldSettleToIdle: Bool
    let shouldAllowTermination: Bool
    let warning: String?

    static func evaluate(
        nativeOwnershipReleased: Bool,
        terminalStatePersisted: Bool
    ) -> MacTerminationSettlement {
        guard nativeOwnershipReleased else {
            return MacTerminationSettlement(
                shouldSettleToIdle: false,
                shouldAllowTermination: false,
                warning: nil
            )
        }
        guard terminalStatePersisted else {
            return MacTerminationSettlement(
                shouldSettleToIdle: true,
                shouldAllowTermination: false,
                warning: storageWarning
            )
        }
        return MacTerminationSettlement(
            shouldSettleToIdle: true,
            shouldAllowTermination: true,
            warning: nil
        )
    }
}

/// In-memory generation fence for callbacks that were already admitted before
/// Quit began. Abandoning one attempt never blocks a fresh UUID, and the fence
/// intentionally lives until process exit because native and transport work
/// may ignore cancellation indefinitely.
@MainActor
final class MacProcessingAttemptFence {
    private var abandonedAttemptIDs: Set<UUID> = []

    func abandon(_ attemptIDs: Set<UUID>) {
        abandonedAttemptIDs.formUnion(attemptIDs)
    }

    func allows(_ attemptID: UUID) -> Bool {
        !abandonedAttemptIDs.contains(attemptID)
    }
}
