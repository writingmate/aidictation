import Foundation

private enum ValidationFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ValidationFailure.failed(message) }
}

private final class FakeRecordingLifecycle {
    enum Phase: Equatable {
        case idle
        case starting(RecordingPreparationAttempt.Token)
        case recording(RecordingPreparationAttempt.Token)
    }

    private(set) var phase: Phase = .idle
    private(set) var recordingStartedCount = 0
    private(set) var cleanupCount = 0

    func begin(_ attempt: RecordingPreparationAttempt) {
        phase = .starting(attempt.token)
    }

    func deliver(_ terminal: RecordingPreparationAttempt.Terminal, for attempt: RecordingPreparationAttempt) {
        guard phase == .starting(attempt.token) else { return }

        switch terminal {
        case .ready:
            phase = .recording(attempt.token)
            recordingStartedCount += 1
        case .failed, .timedOut, .cancelled, .invalidated:
            phase = .idle
        }
    }

    func cleanup(using claim: RecordingPreparationCleanupClaim) {
        if claim.claim() {
            cleanupCount += 1
        }
    }

    func cancelPendingOrActive(_ token: RecordingPreparationAttempt.Token) {
        switch phase {
        case .starting(let activeToken) where activeToken == token:
            phase = .idle
            cleanupCount += 1
        case .recording(let activeToken) where activeToken == token:
            phase = .idle
            cleanupCount += 1
        case .idle, .starting, .recording:
            break
        }
    }
}

private func validateTimeoutRejectsLateNativeSuccess() throws {
    let attempt = RecordingPreparationAttempt()
    let cleanup = RecordingPreparationCleanupClaim()
    let lifecycle = FakeRecordingLifecycle()
    lifecycle.begin(attempt)

    try require(attempt.resolve(.timedOut), "deadline did not win a pending attempt")
    lifecycle.deliver(.timedOut, for: attempt)
    try require(!attempt.resolve(.ready), "late native success replaced timeout")
    lifecycle.deliver(.ready, for: attempt)
    lifecycle.cleanup(using: cleanup)
    lifecycle.cleanup(using: cleanup)

    try require(lifecycle.phase == .idle, "timeout did not return lifecycle to idle")
    try require(lifecycle.recordingStartedCount == 0, "late success emitted recordingStarted")
    try require(lifecycle.cleanupCount == 1, "late cleanup was not exactly once")
}

private func validateNativeSuccessBeatsLaterDeadline() throws {
    let attempt = RecordingPreparationAttempt()
    let lifecycle = FakeRecordingLifecycle()
    lifecycle.begin(attempt)

    try require(attempt.resolve(.ready), "native success did not win pending attempt")
    lifecycle.deliver(.ready, for: attempt)
    try require(!attempt.resolve(.timedOut), "deadline replaced completed native success")
    lifecycle.deliver(.timedOut, for: attempt)

    try require(lifecycle.phase == .recording(attempt.token), "accepted success did not remain recording")
    try require(lifecycle.recordingStartedCount == 1, "accepted success was not delivered exactly once")
}

private func validateActivationFailureCannotClaimReady() throws {
    let attempt = RecordingPreparationAttempt()
    let terminal = attempt.resolveAfterActivation(
        succeeded: false,
        failureMessage: "capture activation failed"
    )

    try require(
        terminal == .failed("capture activation failed"),
        "failed activation did not own a terminal failure"
    )
    try require(!attempt.resolve(.ready), "failed activation later became ready")
}

private func validateCancellationBeforeActivationWins() throws {
    let attempt = RecordingPreparationAttempt()
    try require(attempt.resolve(.cancelled), "cancellation did not win pending preparation")
    let terminal = attempt.resolveAfterActivation(
        succeeded: true,
        failureMessage: "capture activation failed"
    )

    try require(terminal == nil, "late activation replaced cancellation")
    try require(attempt.terminal == .cancelled, "late activation changed cancellation")
}

private func validateOldGenerationCannotAffectRetry() throws {
    let oldAttempt = RecordingPreparationAttempt()
    let newAttempt = RecordingPreparationAttempt()
    let lifecycle = FakeRecordingLifecycle()

    lifecycle.begin(oldAttempt)
    try require(oldAttempt.resolve(.timedOut), "old attempt timeout did not win")
    lifecycle.deliver(.timedOut, for: oldAttempt)

    lifecycle.begin(newAttempt)
    try require(newAttempt.resolve(.ready), "fresh attempt could not complete")
    lifecycle.deliver(.ready, for: newAttempt)

    try require(!oldAttempt.resolve(.ready), "old attempt accepted a late success")
    lifecycle.deliver(.ready, for: oldAttempt)

    try require(lifecycle.phase == .recording(newAttempt.token), "old callback changed the fresh attempt")
    try require(lifecycle.recordingStartedCount == 1, "old callback emitted an extra start")
}

private func validateScopedCancelAcrossPromotionBoundary() throws {
    do {
        let activeAttempt = RecordingPreparationAttempt()
        let unrelatedAttempt = RecordingPreparationAttempt()
        let lifecycle = FakeRecordingLifecycle()
        lifecycle.begin(activeAttempt)

        lifecycle.cancelPendingOrActive(unrelatedAttempt.token)
        try require(
            lifecycle.phase == .starting(activeAttempt.token),
            "an unrelated token cancelled a pending capture"
        )
        try require(lifecycle.cleanupCount == 0, "wrong-token pending cancellation cleaned audio")
    }

    do {
        let attempt = RecordingPreparationAttempt()
        let lifecycle = FakeRecordingLifecycle()
        lifecycle.begin(attempt)

        lifecycle.cancelPendingOrActive(attempt.token)
        try require(attempt.resolve(.cancelled), "pending cancellation did not own the attempt")
        try require(!attempt.resolve(.ready), "late promotion replaced pending cancellation")
        lifecycle.deliver(.ready, for: attempt)
        try require(lifecycle.phase == .idle, "late ready restarted a cancelled pending capture")
    }

    do {
        let attempt = RecordingPreparationAttempt()
        let unrelatedAttempt = RecordingPreparationAttempt()
        let lifecycle = FakeRecordingLifecycle()
        lifecycle.begin(attempt)

        try require(attempt.resolve(.ready), "promotion could not own the attempt")
        lifecycle.deliver(.ready, for: attempt)
        lifecycle.cancelPendingOrActive(unrelatedAttempt.token)
        try require(
            lifecycle.phase == .recording(attempt.token),
            "an unrelated token cancelled a promoted capture"
        )
        try require(lifecycle.cleanupCount == 0, "wrong-token promoted cancellation cleaned audio")
        lifecycle.cancelPendingOrActive(attempt.token)
        try require(lifecycle.phase == .idle, "scoped cancellation missed a just-promoted capture")
        try require(lifecycle.cleanupCount == 1, "promoted capture was not cleaned exactly once")
    }
}

private func validateFirstWriterUnderRace() throws {
    for _ in 0 ..< 500 {
        let attempt = RecordingPreparationAttempt()
        let queue = DispatchQueue(label: "recording-preparation-race", attributes: .concurrent)
        let group = DispatchGroup()
        let winnerLock = NSLock()
        var winners = 0

        for terminal in [RecordingPreparationAttempt.Terminal.ready, .timedOut, .cancelled, .invalidated] {
            group.enter()
            queue.async {
                if attempt.resolve(terminal) {
                    winnerLock.lock()
                    winners += 1
                    winnerLock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        try require(winners == 1, "concurrent terminal race produced \(winners) owners")
        try require(attempt.terminal != nil, "concurrent terminal race produced no terminal state")
    }
}

private func validateCleanupClaimUnderRace() throws {
    let cleanup = RecordingPreparationCleanupClaim()
    let queue = DispatchQueue(label: "recording-cleanup-race", attributes: .concurrent)
    let group = DispatchGroup()
    let winnerLock = NSLock()
    var winners = 0

    for _ in 0 ..< 100 {
        group.enter()
        queue.async {
            if cleanup.claim() {
                winnerLock.lock()
                winners += 1
                winnerLock.unlock()
            }
            group.leave()
        }
    }

    group.wait()
    try require(winners == 1, "cleanup race produced \(winners) owners")
}

private func validateFinalizationTimeoutRejectsLateSuccess() throws {
    let attempt = RecordingFinalizationAttempt()
    let url = URL(fileURLWithPath: "/tmp/recoverable-recording.m4a")

    try require(
        attempt.resolve(.timedOut(recoverableURL: url)),
        "finalization deadline did not win"
    )
    try require(
        !attempt.resolve(.finalized(url)),
        "late native finalization replaced timeout"
    )
    try require(
        attempt.terminal == .timedOut(recoverableURL: url),
        "timeout did not preserve recoverable source identity"
    )
}

private func validateFinalizationFirstWriterUnderRace() throws {
    for _ in 0 ..< 500 {
        let attempt = RecordingFinalizationAttempt()
        let queue = DispatchQueue(label: "recording-finalization-race", attributes: .concurrent)
        let group = DispatchGroup()
        let winnerLock = NSLock()
        let url = URL(fileURLWithPath: "/tmp/recoverable-recording.m4a")
        var winners = 0

        let terminals: [RecordingFinalizationAttempt.Terminal] = [
            .finalized(url),
            .failed(message: "failed", recoverableURL: url),
            .timedOut(recoverableURL: url),
            .discarded,
        ]
        for terminal in terminals {
            group.enter()
            queue.async {
                if attempt.resolve(terminal) {
                    winnerLock.lock()
                    winners += 1
                    winnerLock.unlock()
                }
                group.leave()
            }
        }

        group.wait()
        try require(winners == 1, "concurrent finalization race produced \(winners) owners")
    }
}

@main
private struct MacRecordingRecoveryValidator {
    static func main() throws {
        try validateTimeoutRejectsLateNativeSuccess()
        try validateNativeSuccessBeatsLaterDeadline()
        try validateActivationFailureCannotClaimReady()
        try validateCancellationBeforeActivationWins()
        try validateOldGenerationCannotAffectRetry()
        try validateScopedCancelAcrossPromotionBoundary()
        try validateFirstWriterUnderRace()
        try validateCleanupClaimUnderRace()
        try validateFinalizationTimeoutRejectsLateSuccess()
        try validateFinalizationFirstWriterUnderRace()
        print("macOS recording preparation recovery contract: PASS")
    }
}
