import Foundation
import XCTest

final class MacCaptureWriterDrainTests: XCTestCase {
    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        var pending = true
        var failure: String?
        var closed = false
    }

    func testLastProducerCallbackCanReportFailureBeforeWriterCloses() {
        let state = State()
        state.pending = false
        let reported = DispatchSemaphore(value: 0)
        MacCaptureWriterDrain.finish(condition: state.condition, writesPending: { state.pending }) {
            DispatchQueue.global().async {
                state.condition.lock()
                state.failure = "Producer stopped"
                state.condition.unlock()
                reported.signal()
            }
            XCTAssertEqual(reported.wait(timeout: .now() + 1), .success,
                           "Finalization held the writer lock while the producer reported failure")
            return [1, 2, 3]
        } closeWriter: { tail in
            XCTAssertEqual(state.failure, "Producer stopped")
            XCTAssertEqual(tail, [1, 2, 3])
            state.closed = true
        }
        XCTAssertTrue(state.closed)
    }

    func testActiveWriteFinishesBeforeDrainAndClose() {
        let state = State()
        let finished = expectation(description: "Writer closed")
        DispatchQueue.global().async {
            MacCaptureWriterDrain.finish(condition: state.condition, writesPending: { state.pending }) {
                XCTAssertFalse(state.pending)
                return "tail"
            } closeWriter: { tail in
                XCTAssertEqual(tail, "tail")
                state.closed = true
            }
            finished.fulfill()
        }
        state.condition.lock()
        XCTAssertFalse(state.closed)
        state.pending = false
        state.condition.broadcast()
        state.condition.unlock()
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(state.closed)
    }
}
