import Foundation

/// Owns the single terminal outcome of recording preparation. Native audio
/// callbacks, cancellation, route invalidation, and the external deadline all
/// race through this object; exactly one of them can win.
public final class RecordingPreparationAttempt: @unchecked Sendable {
    public struct Token: Hashable, Sendable {
        public let rawValue: UUID

        public init(rawValue: UUID = UUID()) {
            self.rawValue = rawValue
        }
    }

    public enum Terminal: Equatable, Sendable {
        case ready
        case failed(String)
        case timedOut
        case cancelled
        case invalidated
    }

    private enum State {
        case pending
        case terminal(Terminal)
    }

    public let token: Token

    private let lock = NSLock()
    private var state: State = .pending

    public init(token: Token = Token()) {
        self.token = token
    }

    /// Returns true only for the callback that became the terminal owner.
    @discardableResult
    public func resolve(_ terminal: Terminal) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .pending = state else { return false }
        state = .terminal(terminal)
        return true
    }

    /// Commits readiness only after the attempt-local capture session has
    /// activated. If activation failed, the same atomic decision owns a failure
    /// instead, so the attempt can never become `ready` without an active owner.
    public func resolveAfterActivation(
        succeeded: Bool,
        failureMessage: String
    ) -> Terminal? {
        lock.lock()
        defer { lock.unlock() }

        guard case .pending = state else { return nil }
        let terminal: Terminal = succeeded ? .ready : .failed(failureMessage)
        state = .terminal(terminal)
        return terminal
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

/// Prevents timeout, cancellation, and late native completion from tearing
/// down the same Core Audio resources concurrently.
public final class RecordingPreparationCleanupClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    @discardableResult
    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !claimed else { return false }
        claimed = true
        return true
    }
}
