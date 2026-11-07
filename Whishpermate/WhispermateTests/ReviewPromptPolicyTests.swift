import XCTest

final class ReviewPromptPolicyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let day: TimeInterval = 24 * 60 * 60

    func testAsksOnlyAfterRepeatedSuccessAcrossDaysWhileTheAppIsIdle() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var record = ReviewPromptRecord.empty
        record = note(record, "first", start)
        record = note(record, "second", start.addingTimeInterval(60))
        record = note(record, "third", start.addingTimeInterval(day))
        record = note(record, "fourth", start.addingTimeInterval(day + 60))
        record = note(record, "fifth", start.addingTimeInterval(3 * day))

        let readyAt = start.addingTimeInterval(ReviewPromptPolicy.minimumAgeSinceFirstSuccess)
        XCTAssertTrue(ReviewPromptPolicy.shouldRequestReview(record: record, at: readyAt, hostIsAtRest: true))
        XCTAssertFalse(ReviewPromptPolicy.shouldRequestReview(record: record, at: readyAt, hostIsAtRest: false))
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record: record,
                at: readyAt.addingTimeInterval(-1),
                hostIsAtRest: true
            )
        )
    }

    func testBlankOrFailedDictationDoesNotCountAsAHappyMoment() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let ready = qualified(start)
        let blank = ReviewPromptPolicy.notingDictation(
            ready,
            text: "   ",
            at: start.addingTimeInterval(4 * day),
            calendar: calendar,
            deferPrompt: false
        )
        XCTAssertFalse(blank.lastOutcomeSucceeded)
        XCTAssertEqual(blank.successfulDictations, ready.successfulDictations)
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record: blank,
                at: start.addingTimeInterval(4 * day),
                hostIsAtRest: true
            )
        )

        let failed = ReviewPromptPolicy.notingFailure(ready)
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record: failed,
                at: start.addingTimeInterval(4 * day),
                hostIsAtRest: true
            )
        )
    }

    func testRecentKeyboardDictationAndPriorPromptsHoldTheAsk() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let deferred = ReviewPromptPolicy.notingDictation(
            qualified(start),
            text: "from the keyboard",
            at: start.addingTimeInterval(4 * day),
            calendar: calendar,
            deferPrompt: true
        )
        let duringReturn = start.addingTimeInterval(4 * day + 1)
        XCTAssertFalse(ReviewPromptPolicy.shouldRequestReview(record: deferred, at: duringReturn, hostIsAtRest: true))
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequestReview(
                record: deferred,
                at: duringReturn.addingTimeInterval(ReviewPromptPolicy.returnSuppression),
                hostIsAtRest: true
            )
        )

        let prompted = ReviewPromptPolicy.notingPromptAttempt(deferred, at: duringReturn)
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record: prompted,
                at: duringReturn.addingTimeInterval(ReviewPromptPolicy.cooldown - 1),
                hostIsAtRest: true
            )
        )
        XCTAssertTrue(
            ReviewPromptPolicy.shouldRequestReview(
                record: prompted,
                at: duringReturn.addingTimeInterval(ReviewPromptPolicy.cooldown),
                hostIsAtRest: true
            )
        )

        var exhausted = prompted
        exhausted.promptAttempts = ReviewPromptPolicy.maximumPromptAttempts
        XCTAssertFalse(
            ReviewPromptPolicy.shouldRequestReview(
                record: exhausted,
                at: duringReturn.addingTimeInterval(ReviewPromptPolicy.cooldown),
                hostIsAtRest: true
            )
        )
    }

    private func qualified(_ start: Date) -> ReviewPromptRecord {
        var record = ReviewPromptRecord.empty
        record = note(record, "one", start)
        record = note(record, "two", start.addingTimeInterval(day))
        record = note(record, "three", start.addingTimeInterval(2 * day))
        record = note(record, "four", start.addingTimeInterval(2 * day + 1))
        record = note(record, "five", start.addingTimeInterval(3 * day))
        return record
    }

    private func note(_ record: ReviewPromptRecord, _ text: String, _ date: Date) -> ReviewPromptRecord {
        ReviewPromptPolicy.notingDictation(
            record,
            text: text,
            at: date,
            calendar: calendar,
            deferPrompt: false
        )
    }
}
