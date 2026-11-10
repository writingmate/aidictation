import Foundation

/// Deterministic attempt policy for rebuilding a failed capture graph without
/// ending the user's recording. Its owner supplies serialization.
nonisolated struct MacCaptureRecoveryPolicy {
    /// Waits before each rebuild of the capture graph. An input device change
    /// (AirPods connecting, a USB mic unplugged) can leave the new default
    /// input without a usable format for a few seconds while Bluetooth or the
    /// HAL renegotiates, so later attempts back off further. The sum stays
    /// bounded so a microphone that never returns still ends the recording.
    static let retryDelays: [TimeInterval] = [0.15, 0.5, 1.0, 2.0, 3.0]

    static var maximumAttempts: Int { retryDelays.count }

    /// Delay before the 1-based `attempt`.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        retryDelays[min(max(attempt, 1), retryDelays.count) - 1]
    }

    /// A route that is still switching reports zero channels or a zero sample
    /// rate; installing a tap on that format captures nothing or throws.
    static func isUsableInputFormat(sampleRate: Double, channelCount: UInt32) -> Bool {
        sampleRate > 0 && channelCount > 0
    }

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
