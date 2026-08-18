import XCTest

/// Covers the bridge that fences native callbacks which may ignore cancellation.
/// The failure modes here are a hung recording (continuation never resumed) or a
/// crash (continuation resumed twice), so every race gets an explicit test.
final class MacAsyncDeadlineTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000

    func testReturnsTheNativeResult() async throws {
        let op = MacBoundedNativeOperation<Int>(cancelNative: {})

        let value = try await op.run(timeoutNanoseconds: second) { done in
            done(.success(42))
        }

        XCTAssertEqual(value, 42)
    }

    func testPropagatesTheNativeFailure() async {
        struct Boom: Error, Equatable {}
        let op = MacBoundedNativeOperation<Int>(cancelNative: {})

        do {
            _ = try await op.run(timeoutNanoseconds: second) { done in
                done(.failure(Boom()))
            }
            XCTFail("expected the native failure to propagate")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }

    func testTimesOutWhenTheNativeCallbackNeverFires() async {
        let cancelled = expectation(description: "cancelNative called on timeout")
        let op = MacBoundedNativeOperation<Int>(cancelNative: { cancelled.fulfill() })

        do {
            _ = try await op.run(timeoutNanoseconds: 10_000_000) { _ in
                // Native work that never calls back.
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? MacNativeOperationDeadlineError, .timedOut)
        }

        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testACallbackArrivingAfterTheTimeoutIsIgnored() async {
        let op = MacBoundedNativeOperation<Int>(cancelNative: {})
        let lateCallback = expectation(description: "late callback ran")

        do {
            _ = try await op.run(timeoutNanoseconds: 10_000_000) { done in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    // Resolving a second time must not crash on a resumed continuation.
                    done(.success(1))
                    lateCallback.fulfill()
                }
            }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? MacNativeOperationDeadlineError, .timedOut)
        }

        await fulfillment(of: [lateCallback], timeout: 2)
    }

    func testRepeatedCallbacksResolveOnlyOnce() async throws {
        let op = MacBoundedNativeOperation<Int>(cancelNative: {})

        let value = try await op.run(timeoutNanoseconds: second) { done in
            done(.success(1))
            // A native library that fires its completion more than once must not
            // resume the continuation again.
            done(.success(2))
            done(.failure(CancellationError()))
        }

        XCTAssertEqual(value, 1)
    }

    func testCancellingTheCallingTaskCancelsTheNativeWork() async {
        let cancelled = expectation(description: "cancelNative called on cancellation")
        let started = expectation(description: "operation started")
        let op = MacBoundedNativeOperation<Int>(cancelNative: { cancelled.fulfill() })

        let task = Task {
            try await op.run(timeoutNanoseconds: 5 * second) { _ in
                started.fulfill()
            }
        }

        await fulfillment(of: [started], timeout: 2)
        task.cancel()

        let result = await task.result
        await fulfillment(of: [cancelled], timeout: 2)

        switch result {
        case .success:
            XCTFail("expected cancellation to surface")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testResultDeliveredBeforeInstallIsNotLost() async throws {
        // The native side can call back synchronously, before the continuation is
        // installed; the pending result must still be delivered rather than hang.
        let op = MacBoundedNativeOperation<String>(cancelNative: {})

        let value = try await op.run(timeoutNanoseconds: second) { done in
            done(.success("immediate"))
        }

        XCTAssertEqual(value, "immediate")
    }
}
