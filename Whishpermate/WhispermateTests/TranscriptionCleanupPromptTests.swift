import XCTest

final class TranscriptionCleanupPromptTests: XCTestCase {
    func testDictationRequiresStandaloneFillerDeletion() {
        let prompt = TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: [],
            languageContext: nil,
            appContext: nil,
            hasSelectedContent: false
        )

        assertMandatoryFillerPolicy(in: prompt)
        assertSentenceTypePreservation(in: prompt)
        assertParagraphFormatting(in: prompt)
    }

    func testTransformedOutputRequiresStandaloneFillerDeletion() {
        let prompt = TranscriptionCleanupPrompt.systemPrompt(
            formattingContext: [],
            languageContext: nil,
            appContext: nil,
            hasSelectedContent: false,
            transformationInstruction: "Format as concise notes."
        )

        assertMandatoryFillerPolicy(in: prompt)
        assertSentenceTypePreservation(in: prompt)
        assertParagraphFormatting(in: prompt)
    }

    func testRecognitionInstructionsPreserveSentenceType() {
        let prompt = TranscriptionCleanupPrompt.speechRecognitionPrompt(hints: [])

        assertSentenceTypePreservation(in: prompt)
        XCTAssertTrue(prompt.contains("add a blank line at natural shifts in thought"))
        XCTAssertTrue(prompt.contains("Preserve existing paragraphs, lists, order, and content"))
        XCTAssertTrue(prompt.contains("Keep short text compact"))
        XCTAssertTrue(prompt.contains("Remove filler sounds such as \"um\", \"uh\", \"er\", and \"ah\""))
        XCTAssertTrue(prompt.contains("Do not translate, summarize, paraphrase, answer the speaker, invent content, or omit meaningful clauses"))
    }

    private func assertMandatoryFillerPolicy(
        in prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            prompt.contains("Remove standalone fillers (um, uh, uhm, umm, er, erm, ah, hmm, ugh)"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains("keep meaningful hesitation"),
            file: file,
            line: line
        )
    }

    private func assertSentenceTypePreservation(
        in prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            (prompt.contains("Keep order, statements, and questions as spoken unless explicitly transformed") &&
                 prompt.contains("after a false start, keep the speaker's final wording")) ||
                (prompt.contains("Preserve sentence type") &&
                 prompt.contains("Never rephrase a question into a statement or a statement into a question")),
            file: file,
            line: line
        )
    }

    private func assertParagraphFormatting(
        in prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(prompt.contains("add a blank line at natural shifts in thought"), file: file, line: line)
        XCTAssertTrue(prompt.contains("Preserve existing paragraphs, lists, order, and content"), file: file, line: line)
        XCTAssertTrue(prompt.contains("Keep short text compact"), file: file, line: line)
        XCTAssertTrue(prompt.contains("unless explicit formatting or output transformation requests otherwise"), file: file, line: line)
    }
}
