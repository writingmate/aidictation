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

/// Replays the recorder's watchdog-driven recovery loop against a simulated
/// input route that is unusable for `routeUnavailableFor` seconds after an
/// input device change. Attempts follow `AudioRecorder.attemptCaptureRecovery`:
/// the watchdog notices the stopped engine, each attempt waits its delay and
/// rebuilds, a failed rebuild schedules the next attempt, and a healthy buffer
/// restores the full budget.
private struct RouteChangeSimulation {
    static let watchdogDetectionDelay: TimeInterval = 1.0

    enum Outcome: Equatable {
        case recovered(at: TimeInterval, attempts: Int)
        case recordingEnded(at: TimeInterval, attempts: Int)
    }

    static func run(
        routeUnavailableFor: TimeInterval,
        delays: [TimeInterval],
        policy: inout MacCaptureRecoveryPolicy
    ) -> Outcome {
        var clock = watchdogDetectionDelay
        var attempts = 0
        while let attempt = policy.begin(maximumAttempts: delays.count) {
            attempts = attempt
            clock += delays[attempt - 1]
            let routeReady = clock >= routeUnavailableFor
            policy.finish()
            if routeReady {
                policy.noteHealthyBuffer()
                return .recovered(at: clock, attempts: attempts)
            }
        }
        return .recordingEnded(at: clock, attempts: attempts)
    }
}

@main
private struct CaptureRouteRecoveryValidator {
    /// The schedule that shipped before this contract. Kept to prove the
    /// regression scenario actually failed under it.
    static let previousDelays: [TimeInterval] = [0.15, 0.5]

    static func main() throws {
        try validateDelaySchedule()
        try validateFormatUsability()
        try validateRouteChangeScenarios()
        try validateSourceContract()
        print("macOS capture route-change recovery contract: PASS")
    }

    private static func validateDelaySchedule() throws {
        let delays = MacCaptureRecoveryPolicy.retryDelays
        try require(!delays.isEmpty, "recovery needs at least one attempt")
        try require(
            zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 },
            "recovery delays must back off, never shorten"
        )
        try require(
            delays.reduce(0, +) <= 10,
            "recovery must stay bounded so a dead microphone still ends the recording"
        )
        try require(
            MacCaptureRecoveryPolicy.maximumAttempts == delays.count,
            "every attempt must have a delay"
        )
        for (index, delay) in delays.enumerated() {
            try require(
                MacCaptureRecoveryPolicy.delay(forAttempt: index + 1) == delay,
                "attempt \(index + 1) must use its scheduled delay"
            )
        }
        try require(
            MacCaptureRecoveryPolicy.delay(forAttempt: 0) == delays[0]
                && MacCaptureRecoveryPolicy.delay(forAttempt: delays.count + 3) == delays[delays.count - 1],
            "out-of-range attempts must clamp instead of trapping"
        )
    }

    private static func validateFormatUsability() throws {
        try require(
            MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 48_000, channelCount: 1),
            "a live mono input is usable"
        )
        try require(
            MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 16_000, channelCount: 1),
            "a Bluetooth headset input is usable"
        )
        try require(
            !MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 48_000, channelCount: 0),
            "a route with no channels is still switching"
        )
        try require(
            !MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 0, channelCount: 1),
            "a route with no sample rate is still switching"
        )
    }

    private static func validateRouteChangeScenarios() throws {
        let delays = MacCaptureRecoveryPolicy.retryDelays

        // Unplugging a USB mic: the built-in mic is usable almost immediately.
        var unplug = MacCaptureRecoveryPolicy()
        guard case .recovered = RouteChangeSimulation.run(
            routeUnavailableFor: 1.1,
            delays: delays,
            policy: &unplug
        ) else {
            throw ValidationFailure.failed("a fast route change must recover")
        }

        // AirPods connecting mid-recording: the headset input takes a few
        // seconds to publish a usable format. This ended the recording before.
        let bluetoothNegotiation: TimeInterval = 4.0
        var previous = MacCaptureRecoveryPolicy()
        guard case .recordingEnded = RouteChangeSimulation.run(
            routeUnavailableFor: bluetoothNegotiation,
            delays: previousDelays,
            policy: &previous
        ) else {
            throw ValidationFailure.failed("the regression scenario must fail under the previous schedule")
        }
        var bluetooth = MacCaptureRecoveryPolicy()
        guard case .recovered = RouteChangeSimulation.run(
            routeUnavailableFor: bluetoothNegotiation,
            delays: delays,
            policy: &bluetooth
        ) else {
            throw ValidationFailure.failed("a Bluetooth input switch must not end the recording")
        }

        // A second device change in the same recording gets the full budget
        // again because the first recovery delivered healthy audio.
        var secondChange = bluetooth
        guard case .recovered = RouteChangeSimulation.run(
            routeUnavailableFor: bluetoothNegotiation,
            delays: delays,
            policy: &secondChange
        ) else {
            throw ValidationFailure.failed("a later device change must recover with a fresh budget")
        }

        // A microphone that never comes back still ends the recording, bounded.
        var dead = MacCaptureRecoveryPolicy()
        let deadOutcome = RouteChangeSimulation.run(
            routeUnavailableFor: .infinity,
            delays: delays,
            policy: &dead
        )
        guard case .recordingEnded(let endedAt, let attempts) = deadOutcome else {
            throw ValidationFailure.failed("a dead microphone must end the recording")
        }
        try require(attempts == delays.count, "a dead microphone must use every attempt")
        try require(endedAt <= 12, "a dead microphone must end the recording within a bounded time")
        try require(
            dead.isExhausted(maximumAttempts: delays.count),
            "the recorder must see the budget as exhausted"
        )
    }

    private static func validateSourceContract() throws {
        let workspaceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let recorderSource = try String(
            contentsOf: workspaceRoot
                .appendingPathComponent("Whishpermate/Whispermate/Services/AudioRecorder.swift"),
            encoding: .utf8
        )

        try require(
            !recorderSource.contains("captureRecoveryDelays"),
            "AudioRecorder must take its recovery schedule from MacCaptureRecoveryPolicy"
        )
        try require(
            recorderSource.contains("maximumAttempts: MacCaptureRecoveryPolicy.maximumAttempts"),
            "AudioRecorder must bound recovery by the policy's attempt count"
        )
        try require(
            recorderSource.contains("MacCaptureRecoveryPolicy.delay(forAttempt: recoveryAttempt)"),
            "AudioRecorder must wait the policy's delay before each rebuild"
        )
        try require(
            recorderSource.contains("self.startRecordingWatchdog()\n                self.lastAudioBufferAt = Date()"),
            "AudioRecorder must seed lastAudioBufferAt after restarting the watchdog so a silent rebuilt engine is detected"
        )
        try require(
            recorderSource.contains("MacCaptureRecoveryPolicy.isUsableInputFormat("),
            "AudioRecorder must reject a still-switching input format before rebuilding"
        )
    }
}
