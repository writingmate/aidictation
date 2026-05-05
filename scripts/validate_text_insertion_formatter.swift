import Foundation

struct SpacingCase {
    let name: String
    let text: String
    let existingText: String?
    let range: NSRange?
    let addBoundarySpaces: Bool
    let expected: String
}

@main
enum Main {
    static func main() {
        let cases = [
            SpacingCase(
                name: "plain insertion appends separator",
                text: "hello",
                existingText: nil,
                range: nil,
                addBoundarySpaces: true,
                expected: "hello "
            ),
            SpacingCase(
                name: "existing separator is not duplicated",
                text: "hello ",
                existingText: nil,
                range: nil,
                addBoundarySpaces: true,
                expected: "hello "
            ),
            SpacingCase(
                name: "middle of adjacent words adds both boundaries",
                text: "hello",
                existingText: "leftRight",
                range: NSRange(location: 4, length: 0),
                addBoundarySpaces: true,
                expected: " hello "
            ),
            SpacingCase(
                name: "opening punctuation suppresses leading boundary",
                text: "hello",
                existingText: "(world",
                range: NSRange(location: 1, length: 0),
                addBoundarySpaces: true,
                expected: "hello "
            ),
            SpacingCase(
                name: "selection replacement stays exact",
                text: "hello",
                existingText: "replace me",
                range: NSRange(location: 0, length: 7),
                addBoundarySpaces: false,
                expected: "hello"
            ),
        ]

        for testCase in cases {
            let actual = TextInsertionFormatter.payload(
                for: testCase.text,
                existingText: testCase.existingText,
                selectedRange: testCase.range,
                addBoundarySpaces: testCase.addBoundarySpaces
            )

            if actual != testCase.expected {
                fputs(
                    "spacing validation failed: \(testCase.name): expected \(String(reflecting: testCase.expected)), got \(String(reflecting: actual))\n",
                    stderr
                )
                exit(1)
            }
        }

        print("text insertion spacing ok: \(cases.count) cases")
    }
}
