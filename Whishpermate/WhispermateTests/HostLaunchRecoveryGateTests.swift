import XCTest

/// Covers the launch recovery gate that decides whether saved recordings have
/// been checked. The regressions guarded here both showed up as an app stuck on
/// "Saved recordings are still being checked." until it was force-quit.
@MainActor
final class HostLaunchRecoveryGateTests: XCTestCase {
    func testReadyAfterSuccessfulPass() async {
        let gate = HostLaunchRecoveryGate()
        let ready = await gate.ensureReady {}

        XCTAssertTrue(ready)
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(gate.passCount, 1)
    }

    func testSuccessfulPassIsNotRepeated() async {
        let gate = HostLaunchRecoveryGate()
        await gate.ensureReady {}
        let ready = await gate.ensureReady {
            XCTFail("recovery ran again after it had already succeeded")
        }

        XCTAssertTrue(ready)
        XCTAssertEqual(gate.passCount, 1)
    }

    /// A caller arriving mid-pass used to read the not-yet-set flag as "not
    /// ready" and show the alert while recovery was still succeeding.
    func testConcurrentCallersJoinTheSamePassAndSeeItsResult() async {
        let gate = HostLaunchRecoveryGate()
        let release = Gate()

        async let first = gate.ensureReady {
            await release.wait()
        }
        // Give the first caller a turn so its pass is registered as in flight.
        await Task.yield()
        async let second = gate.ensureReady {
            XCTFail("a second recovery pass started while one was in flight")
        }
        await Task.yield()
        await release.open()

        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(gate.passCount, 1)
        XCTAssertTrue(gate.isReady)
    }

    /// A thrown pass used to latch permanently, so every later tap failed even
    /// though a retry would have worked.
    func testFailedPassIsRetriedByTheNextCaller() async {
        let gate = HostLaunchRecoveryGate()

        let failed = await gate.ensureReady { throw RecoveryError.boom }
        XCTAssertFalse(failed)
        XCTAssertFalse(gate.isReady)

        let recovered = await gate.ensureReady {}
        XCTAssertTrue(recovered)
        XCTAssertTrue(gate.isReady)
        XCTAssertEqual(gate.passCount, 2)
    }

    func testRepeatedFailuresKeepRetrying() async {
        let gate = HostLaunchRecoveryGate()

        for _ in 0 ..< 3 {
            let ready = await gate.ensureReady { throw RecoveryError.boom }
            XCTAssertFalse(ready)
        }

        XCTAssertEqual(gate.passCount, 3)
        XCTAssertFalse(gate.isReady)
    }

    // MARK: - Helpers

    private enum RecoveryError: Error {
        case boom
    }

    /// Lets a test hold a recovery pass open until it is explicitly released.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }
}
