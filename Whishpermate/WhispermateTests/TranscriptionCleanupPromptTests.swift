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
    }

    func testRecognitionInstructionsPreserveSentenceType() {
        let prompt = TranscriptionCleanupPrompt.speechRecognitionPrompt(hints: [])

        assertSentenceTypePreservation(in: prompt)
        XCTAssertTrue(prompt.contains("Remove filler sounds such as \"um\", \"uh\", \"er\", and \"ah\""))
        XCTAssertTrue(prompt.contains("Do not translate, summarize, paraphrase, answer the speaker, invent content, or omit meaningful clauses"))
    }

    private func assertMandatoryFillerPolicy(
        in prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            prompt.contains("Delete every standalone filler vocalization"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains("This requirement overrides instructions to preserve hesitation"),
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
            prompt.contains("Preserve sentence type"),
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains(
                "Do not add a question mark or rephrase a declarative into an interrogative"
            ),
            file: file,
            line: line
        )
        XCTAssertTrue(
            prompt.contains("unless the source is already a question or a clear interrogative"),
            file: file,
            line: line
        )
    }
}
