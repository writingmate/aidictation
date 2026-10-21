import XCTest

/// Dictation must insert the speaker's own words. These cases pin the guard
/// that discards cleanup output which performs, answers, or refuses a dictated
/// request, and prove ordinary cleanup still passes through untouched.
final class TranscriptionCleanupGuardTests: XCTestCase {
    private let emailRequest =
        "write an email to my client about the delayed shipment and apologize for the inconvenience"

    private func rejection(
        raw: String,
        cleaned: String,
        expectation: TranscriptionCleanupGuard.Expectation = .faithfulCleanup,
        referenceText: [String] = []
    ) -> TranscriptionCleanupGuard.Rejection? {
        TranscriptionCleanupGuard.rejection(
            rawTranscript: raw,
            cleanedOutput: cleaned,
            expectation: expectation,
            referenceText: referenceText
        )
    }

    // MARK: - Rejected output falls back to the raw transcript

    func testRefusalAfterImperativeRequestFallsBackToRawTranscript() {
        let verdict = TranscriptionCleanupGuard.resolve(
            rawTranscript: emailRequest,
            cleanedOutput: "I'm sorry, but I can't help with that.",
            expectation: .faithfulCleanup
        )

        XCTAssertEqual(verdict.rejection, .refusal)
        XCTAssertTrue(verdict.usedRawTranscript)
        XCTAssertEqual(verdict.text, emailRequest)
    }

    func testRefusalVariantsAreRejected() {
        for output in [
            "I am unable to write that email for you.",
            "Sorry, I can't help with writing emails.",
            "I cannot assist with this request.",
            "As an AI, I don't have access to your client's details.",
            "Unfortunately, I can't do that.",
            "> **Sorry**, I can't write that email.",
        ] {
            XCTAssertEqual(rejection(raw: emailRequest, cleaned: output), .refusal, output)
        }
    }

    func testRefusalIsRejectedInEveryExpectation() {
        for expectation in [
            TranscriptionCleanupGuard.Expectation.faithfulCleanup,
            .instructedCleanup,
            .transformation,
        ] {
            XCTAssertEqual(
                rejection(
                    raw: emailRequest,
                    cleaned: "I'm sorry, I can't create that.",
                    expectation: expectation
                ),
                .refusal
            )
        }
    }

    func testFulfilledEmailRequestIsRejectedAsGeneratedContent() {
        let drafted = """
        Subject: Update on your shipment

        Dear valued customer,

        I wanted to reach out personally regarding the delay with your recent order. \
        We sincerely apologize for the inconvenience this has caused. Our logistics partner \
        experienced an unexpected backlog, and your package is now scheduled to arrive within \
        three business days. Thank you for your understanding.

        Best regards
        """

        XCTAssertEqual(rejection(raw: emailRequest, cleaned: drafted), .generatedContent)
    }

    func testAssistantPreambleIsRejected() {
        let raw = "give me something here that I can copy and paste into slack don't be overly chatty"
        let reply = "Sure, here's a concise snippet you can copy into Slack:\n\nBooking import is done; the pricing webhook is still flaky."

        XCTAssertEqual(rejection(raw: raw, cleaned: reply), .assistantReply)
    }

    func testAssistantSignOffAppendedToDictationIsRejected() {
        let raw = "hi sam the report is attached and I'll see you thursday"
        let output = "Hi Sam, the report is attached and I'll see you Thursday.\n\nLet me know if you'd like any changes!"

        XCTAssertEqual(rejection(raw: raw, cleaned: output), .assistantReply)
    }

    func testAnsweredQuestionIsRejectedAsGeneratedContent() {
        let raw = "what's the difference between a roth ira and a traditional ira and which one makes more sense for me"
        let answer = """
        A Roth IRA is funded with after-tax dollars, so qualified withdrawals in retirement are tax-free, \
        while a traditional IRA is funded with pre-tax dollars and taxed on withdrawal. If you expect to be \
        in a higher tax bracket later, a Roth usually makes more sense; if you want the deduction today, \
        a traditional IRA may be better. Consider your current income and expected retirement income.
        """

        XCTAssertEqual(rejection(raw: raw, cleaned: answer), .generatedContent)
    }

    func testUnrelatedSentenceIsRejectedAsReplacedContent() {
        let raw = "please move the design review to wednesday afternoon and invite the platform team as well"
        let other = "The quarterly budget figures have been finalized and shared with finance for approval."

        XCTAssertEqual(rejection(raw: raw, cleaned: other), .replacedContent)
    }

    func testEmptyOutputIsRejected() {
        XCTAssertEqual(rejection(raw: "send the deck before noon", cleaned: " \n"), .emptyOutput)
    }

    // MARK: - Ordinary cleanup is accepted unchanged

    func testImperativeRequestsAreKeptAsDictation() {
        for (raw, cleaned) in [
            (emailRequest, "Write an email to my client about the delayed shipment and apologize for the inconvenience."),
            (
                "um draft a slack message to the team saying the launch moved to friday uh keep it friendly",
                "Draft a Slack message to the team saying the launch moved to Friday. Keep it friendly."
            ),
            (
                "answer this question for me what time zone is the client in",
                "Answer this question for me: what time zone is the client in?"
            ),
        ] {
            let verdict = TranscriptionCleanupGuard.resolve(
                rawTranscript: raw,
                cleanedOutput: cleaned,
                expectation: .faithfulCleanup
            )
            XCTAssertNil(verdict.rejection, cleaned)
            XCTAssertEqual(verdict.text, cleaned)
        }
    }

    func testSpeakersOwnApologyAndSignOffAreKept() {
        XCTAssertNil(rejection(
            raw: "I'm sorry but I can't make it tomorrow can we move it to thursday",
            cleaned: "I'm sorry, but I can't make it tomorrow. Can we move it to Thursday?"
        ))
        XCTAssertNil(rejection(
            raw: "sure here is the plan for next week we start monday with the kickoff",
            cleaned: "Sure, here is the plan for next week. We start Monday with the kickoff."
        ))
        XCTAssertNil(rejection(
            raw: "let me know if you need anything else before the call",
            cleaned: "Let me know if you need anything else before the call."
        ))
    }

    func testFillerSpellingAndSelfCorrectionFixesAreKept() {
        XCTAssertNil(rejection(
            raw: "um so can you send me the uh report by friday",
            cleaned: "So, can you send me the report by Friday?"
        ))
        XCTAssertNil(rejection(
            raw: "there going too the store later so lets meet their at six",
            cleaned: "They're going to the store later, so let's meet there at six."
        ))
        XCTAssertNil(rejection(
            raw: "send it on tuesday no wait wednesday afternoon",
            cleaned: "Send it on Wednesday afternoon."
        ))
        XCTAssertNil(rejection(
            raw: "the meeting is at two thirty pm on march fifth in room four",
            cleaned: "The meeting is at 2:30 PM on March 5th in room 4."
        ))
    }

    func testReferenceContextMayIntroduceWords() {
        XCTAssertNil(rejection(
            raw: "see you at the q b r tomorrow morning",
            cleaned: "See you at the quarterly business review tomorrow morning.",
            referenceText: ["Expand the exact spoken shortcut \"q b r\" to \"quarterly business review\"."]
        ))
        XCTAssertNil(rejection(
            raw: "send the nova flow summary to kestrel works today",
            cleaned: "Send the NovaFlow summary to KestrelWorks today.",
            referenceText: ["Vocabulary: NovaFlow, KestrelWorks"]
        ))
    }

    func testShortAndUnspacedScriptsAreNotFalselyRejected() {
        XCTAssertNil(rejection(raw: "ok", cleaned: "Okay."))
        XCTAssertNil(rejection(
            raw: "今天天气很好我们下午去公园吧然后晚上一起吃饭",
            cleaned: "今天天气很好，我们下午去公园吧。然后晚上一起吃饭。"
        ))
    }

    func testInstructedAndTransformedCleanupMayDivergeButNotRefuse() {
        XCTAssertNil(rejection(
            raw: "tell the client the shipment is late and we are sorry",
            cleaned: "Dear client,\n\nYour shipment is running late. We are sorry for the delay.\n\nKind regards",
            expectation: .instructedCleanup
        ))
        XCTAssertNil(rejection(
            raw: "we agreed to ship the beta on the tenth and marketing needs screenshots by the eighth",
            cleaned: "- Ship the beta on the 10th\n- Marketing needs screenshots by the 8th",
            expectation: .transformation
        ))
    }
}
