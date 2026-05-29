import Foundation

public enum TranscriptionTextSanitizer {
    private static let meaningfulCharacters = CharacterSet.letters.union(.decimalDigits)

    public static func cleanedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return containsLetterOrNumber(trimmed) ? trimmed : ""
    }

    public static func containsLetterOrNumber(_ text: String) -> Bool {
        text.unicodeScalars.contains { meaningfulCharacters.contains($0) }
    }
}
