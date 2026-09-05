import Foundation
import XCTest

final class MacCaptureWriterDrainTests: XCTestCase {
    func testPauseKeepsWritesClosedUntilResumeCompletes() {
        var phase = MacCapturePhase.active
        let pause = UUID(), resume = UUID()
        XCTAssertTrue(phase.acceptsWrites)
        XCTAssertTrue(phase.beginPauseChange(paused: true, id: pause))
        XCTAssertFalse(phase.acceptsWrites)
        XCTAssertFalse(phase.beginPauseChange(paused: false, id: resume))
        XCTAssertTrue(phase.completePauseChange(paused: true, id: pause))
        XCTAssertFalse(phase.acceptsWrites)
        XCTAssertTrue(phase.beginPauseChange(paused: false, id: resume))
        XCTAssertFalse(phase.acceptsWrites)
        XCTAssertTrue(phase.completePauseChange(paused: false, id: resume))
        XCTAssertTrue(phase.acceptsWrites)
    }

    func testStopWinsOverBothNativePauseAndResumeCompletions() {
        for paused in [true, false] {
            var phase = paused ? MacCapturePhase.active : .paused
            let id = UUID()
            XCTAssertTrue(phase.beginPauseChange(paused: paused, id: id))
            phase = .retired
            XCTAssertFalse(phase.completePauseChange(paused: paused, id: id))
            XCTAssertFalse(phase.acceptsWrites)
        }
    }

    func testLateTimeoutCannotRetireACompletedOrNewerChange() {
        var phase = MacCapturePhase.active
        let first = UUID(), second = UUID()
        XCTAssertTrue(phase.beginPauseChange(paused: true, id: first))
        XCTAssertTrue(phase.completePauseChange(paused: true, id: first))
        phase.cancelPauseChange(id: first)
        XCTAssertEqual(phase, .paused)
        XCTAssertTrue(phase.beginPauseChange(paused: false, id: second))
        phase.cancelPauseChange(id: first)
        XCTAssertEqual(phase, .resuming(second))
        XCTAssertFalse(phase.completePauseChange(paused: false, id: first))
        phase.cancelPauseChange(id: second)
        XCTAssertEqual(phase, .retired)
    }

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
