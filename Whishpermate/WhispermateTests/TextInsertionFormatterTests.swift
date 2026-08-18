import XCTest

/// Covers the spacing rules applied to transcribed text before it is inserted.
/// Ported from `scripts/validate_text_insertion_formatter.swift`.
final class TextInsertionFormatterTests: XCTestCase {
    func testPlainInsertionAppendsSeparator() {
        XCTAssertEqual(payload(for: "hello"), "hello ")
    }

    func testExistingSeparatorIsNotDuplicated() {
        XCTAssertEqual(payload(for: "hello "), "hello ")
    }

    func testMiddleOfAdjacentWordsAddsBothBoundaries() {
        XCTAssertEqual(
            payload(for: "hello", existingText: "leftRight", selectedRange: NSRange(location: 4, length: 0)),
            " hello "
        )
    }

    func testBoundarySpacesCanBeDisabled() {
        XCTAssertEqual(payload(for: "hello", addBoundarySpaces: false), "hello")
    }

    func testSelectionReplacementStaysExact() {
        XCTAssertEqual(
            payload(
                for: "hello",
                existingText: "replace me",
                selectedRange: NSRange(location: 0, length: 7),
                addBoundarySpaces: false
            ),
            "hello"
        )
    }

    private func payload(
        for text: String,
        existingText: String? = nil,
        selectedRange: NSRange? = nil,
        addBoundarySpaces: Bool = true
    ) -> String {
        TextInsertionFormatter.payload(
            for: text,
            existingText: existingText,
            selectedRange: selectedRange,
            addBoundarySpaces: addBoundarySpaces
        )
    }
}
