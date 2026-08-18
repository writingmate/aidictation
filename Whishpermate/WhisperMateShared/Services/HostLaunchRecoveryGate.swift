import Foundation

/// Coalesces a one-time launch recovery pass and lets a failed pass be retried.
///
/// The gate exists because callers ask "is recovery done?" from several places
/// (view appearance, scene changes, keyboard hand-off, a record tap). A plain
/// `attempted` flag latched before the work runs answers "no" for every caller
/// that arrives while the first pass is still running, and answers "no" forever
/// once a pass throws — which strands the app behind "still being checked" until
/// it is relaunched. This type instead hands concurrent callers the same
/// in-flight pass, and drops the failed pass so the next caller starts a new one.
@MainActor
public final class HostLaunchRecoveryGate {
    // MARK: - Public API

    /// True once a recovery pass has completed without throwing.
    public private(set) var isReady = false

    /// Number of passes actually started. Exposed for tests and diagnostics.
    public private(set) var passCount = 0

    public init() {}

    /// Runs `work` unless recovery already succeeded, and reports readiness.
    ///
    /// Concurrent callers join the pass already running instead of starting a
    /// second one or observing a not-yet-finished result as a failure.
    @discardableResult
    public func ensureReady(_ work: @escaping @Sendable @MainActor () async throws -> Void) async -> Bool {
        if isReady { return true }

        let task: Task<Bool, Never>
        let passID: Int
        if let existing = inFlight {
            task = existing
            passID = inFlightID
        } else {
            passCount += 1
            inFlightID += 1
            passID = inFlightID
            task = Task { @MainActor in
                do {
                    try await work()
                    return true
                } catch {
                    return false
                }
            }
            inFlight = task
        }

        let succeeded = await task.value
        if inFlightID == passID {
            inFlight = nil
        }
        if succeeded {
            isReady = true
        }
        return succeeded
    }

    // MARK: - Private Properties

    private var inFlight: Task<Bool, Never>?
    private var inFlightID = 0
}
