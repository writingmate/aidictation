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
}
