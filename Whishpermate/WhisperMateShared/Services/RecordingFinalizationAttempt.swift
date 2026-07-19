import Foundation

/// Owns the single terminal result of asynchronous recording finalization.
/// Native cleanup may finish after the deadline, but only the winning result is
/// allowed to advance UI or processing state.
public final class RecordingFinalizationAttempt: @unchecked Sendable {
    public enum Terminal: Equatable, Sendable {
        case finalized(URL)
        case failed(message: String, recoverableURL: URL)
        case timedOut(recoverableURL: URL)
        case discarded
        case unavailable(String)
    }

    private enum State {
        case pending
        case terminal(Terminal)
    }

    private let lock = NSLock()
    private var state: State = .pending

    public init() {}

    @discardableResult
    public func resolve(_ terminal: Terminal) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .pending = state else { return false }
        state = .terminal(terminal)
        return true
    }

    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .pending = state else { return false }
        return true
    }

    public var terminal: Terminal? {
        lock.lock()
        defer { lock.unlock() }

        guard case .terminal(let terminal) = state else { return nil }
        return terminal
    }
}
