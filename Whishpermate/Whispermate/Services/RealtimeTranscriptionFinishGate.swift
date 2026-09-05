import Foundation

/// Deterministic attempt policy for rebuilding a failed capture graph without
/// ending the user's recording. Its owner supplies serialization.
nonisolated struct MacCaptureRecoveryPolicy {
    private(set) var attemptCount = 0
    private(set) var isRecovering = false

    mutating func begin(maximumAttempts: Int) -> Int? {
        guard !isRecovering, attemptCount < maximumAttempts else { return nil }
        isRecovering = true
        attemptCount += 1
        return attemptCount
    }

    mutating func finish() {
        isRecovering = false
    }

    mutating func noteHealthyBuffer() {
        attemptCount = 0
        isRecovering = false
    }

    func isExhausted(maximumAttempts: Int) -> Bool {
        !isRecovering && attemptCount >= maximumAttempts
    }
}
