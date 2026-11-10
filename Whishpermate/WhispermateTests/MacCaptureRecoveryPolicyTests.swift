import XCTest

/// Covers the bounded capture rebuild budget that keeps a recording alive when
/// the input device changes mid-recording (AirPods connecting, a mic unplugged).
final class MacCaptureRecoveryPolicyTests: XCTestCase {
    private let watchdogDetectionDelay: TimeInterval = 1.0

    /// Seconds after the device change at which recovery restores healthy
    /// audio, or nil when the recording would end.
    private func recoveryTime(
        routeUnavailableFor: TimeInterval,
        delays: [TimeInterval],
        policy: inout MacCaptureRecoveryPolicy
    ) -> TimeInterval? {
        var clock = watchdogDetectionDelay
        while let attempt = policy.begin(maximumAttempts: delays.count) {
            clock += delays[attempt - 1]
            policy.finish()
            if clock >= routeUnavailableFor {
                policy.noteHealthyBuffer()
                return clock
            }
        }
        return nil
    }

    func testDelaysBackOffAndStayBounded() {
        let delays = MacCaptureRecoveryPolicy.retryDelays
        XCTAssertEqual(MacCaptureRecoveryPolicy.maximumAttempts, delays.count)
        XCTAssertEqual(delays.first, 0.15)
        XCTAssertTrue(zip(delays, delays.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertLessThanOrEqual(delays.reduce(0, +), 10)
    }

    func testDelayLookupClampsOutOfRangeAttempts() {
        let delays = MacCaptureRecoveryPolicy.retryDelays
        XCTAssertEqual(MacCaptureRecoveryPolicy.delay(forAttempt: 1), delays[0])
        XCTAssertEqual(MacCaptureRecoveryPolicy.delay(forAttempt: 0), delays[0])
        XCTAssertEqual(MacCaptureRecoveryPolicy.delay(forAttempt: delays.count + 5), delays[delays.count - 1])
    }

    func testRejectsAnInputFormatThatIsStillSwitching() {
        XCTAssertTrue(MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
        XCTAssertTrue(MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 16_000, channelCount: 1))
        XCTAssertFalse(MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        XCTAssertFalse(MacCaptureRecoveryPolicy.isUsableInputFormat(sampleRate: 0, channelCount: 1))
    }

    func testBluetoothInputSwitchNoLongerEndsTheRecording() {
        let bluetoothNegotiation: TimeInterval = 4.0

        var previous = MacCaptureRecoveryPolicy()
        XCTAssertNil(
            recoveryTime(routeUnavailableFor: bluetoothNegotiation, delays: [0.15, 0.5], policy: &previous),
            "the previous two-attempt budget gave up before the headset input was ready"
        )

        var policy = MacCaptureRecoveryPolicy()
        XCTAssertNotNil(
            recoveryTime(
                routeUnavailableFor: bluetoothNegotiation,
                delays: MacCaptureRecoveryPolicy.retryDelays,
                policy: &policy
            )
        )
    }

    func testEachDeviceChangeGetsAFreshBudgetAfterHealthyAudio() {
        var policy = MacCaptureRecoveryPolicy()
        for _ in 0 ..< 3 {
            XCTAssertNotNil(
                recoveryTime(
                    routeUnavailableFor: 4.0,
                    delays: MacCaptureRecoveryPolicy.retryDelays,
                    policy: &policy
                )
            )
        }
    }

    func testDeadMicrophoneStillEndsTheRecording() {
        var policy = MacCaptureRecoveryPolicy()
        XCTAssertNil(
            recoveryTime(
                routeUnavailableFor: .infinity,
                delays: MacCaptureRecoveryPolicy.retryDelays,
                policy: &policy
            )
        )
        XCTAssertTrue(policy.isExhausted(maximumAttempts: MacCaptureRecoveryPolicy.maximumAttempts))
        XCTAssertNil(policy.begin(maximumAttempts: MacCaptureRecoveryPolicy.maximumAttempts))
    }

    func testConcurrentRecoveryIsNotStartedTwice() {
        var policy = MacCaptureRecoveryPolicy()
        XCTAssertEqual(policy.begin(maximumAttempts: 2), 1)
        XCTAssertNil(policy.begin(maximumAttempts: 2))
        XCTAssertFalse(policy.isExhausted(maximumAttempts: 1))
    }
}
