import Foundation

enum TextInsertionFormatter {
    static func payload(
        for text: String,
        existingText: String? = nil,
        selectedRange: NSRange? = nil,
        addBoundarySpaces: Bool
    ) -> String {
        guard addBoundarySpaces else {
            return text
        }

        var result = text

        if let existingText,
           let selectedRange
        {
            let nsText = existingText as NSString
            if nsText.length > 0 {
                let safeLocation = max(0, min(selectedRange.location, nsText.length))
                let safeLength = max(0, min(selectedRange.length, nsText.length - safeLocation))
                let insertionEnd = safeLocation + safeLength

                if shouldAddLeadingSpace(to: text, existingText: nsText, insertionLocation: safeLocation) {
                    result = " " + result
                }

                if shouldAddTrailingSpace(to: text, existingText: nsText, insertionEnd: insertionEnd) {
                    result += " "
                }
            }
        }

        if shouldAppendTrailingSpace(after: text), !endsWithWhitespace(result) {
            result += " "
        }

        return result
    }

    private static func shouldAppendTrailingSpace(after text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return !CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }

    private static func endsWithWhitespace(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func shouldAddLeadingSpace(
        to text: String,
        existingText: NSString,
        insertionLocation: Int
    ) -> Bool {
        guard insertionLocation > 0,
              let firstInsertedScalar = text.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(firstInsertedScalar)
        else {
            return false
        }

        let textBeforeCursor = existingText.substring(to: insertionLocation)
        guard let previousScalar = textBeforeCursor.unicodeScalars.last else {
            return false
        }

        return shouldAddBoundarySpace(between: previousScalar, and: firstInsertedScalar)
    }

    private static func shouldAddTrailingSpace(
        to text: String,
        existingText: NSString,
        insertionEnd: Int
    ) -> Bool {
        guard insertionEnd < existingText.length,
              let lastInsertedScalar = text.unicodeScalars.last,
              !CharacterSet.whitespacesAndNewlines.contains(lastInsertedScalar)
        else {
            return false
        }

        let textAfterCursor = existingText.substring(from: insertionEnd)
        guard let nextScalar = textAfterCursor.unicodeScalars.first else {
            return false
        }

        return shouldAddBoundarySpace(between: lastInsertedScalar, and: nextScalar)
    }

    private static func shouldAddBoundarySpace(between left: Unicode.Scalar, and right: Unicode.Scalar) -> Bool {
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard !whitespace.contains(left), !whitespace.contains(right) else {
            return false
        }

        if isOpeningBoundary(left) || isClosingBoundary(right) {
            return false
        }

        return true
    }

    private static func isOpeningBoundary(_ scalar: Unicode.Scalar) -> Bool {
        "([{<\"'`".unicodeScalars.contains(scalar)
    }

    private static func isClosingBoundary(_ scalar: Unicode.Scalar) -> Bool {
        ")]}>.,!?;:%\"'`".unicodeScalars.contains(scalar)
    }
}
