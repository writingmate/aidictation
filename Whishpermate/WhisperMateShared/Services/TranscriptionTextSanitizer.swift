import Foundation

public enum TranscriptionTextSanitizer {
    private static let meaningfulCharacters = CharacterSet.letters.union(.decimalDigits)

    public enum PostProcessingRejectionReason: String {
        case emptyOutput = "empty output"
        case promptEcho = "cleanup instruction echo"
        case repeatedSequence = "new repeated sequence"
    }

    public static func cleanedText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return containsLetterOrNumber(trimmed) ? trimmed : ""
    }

    public static func containsLetterOrNumber(_ text: String) -> Bool {
        text.unicodeScalars.contains { meaningfulCharacters.contains($0) }
    }

    /// Rejects known cleanup degeneration signatures while allowing ordinary
    /// spelling and grammar corrections to introduce individual words.
    public static func postProcessingRejectionReason(
        candidate: String,
        source: String
    ) -> PostProcessingRejectionReason? {
        let trimmedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard containsLetterOrNumber(trimmedCandidate) else {
            return .emptyOutput
        }

        if isPromptEcho(trimmedCandidate, source: source) {
            return .promptEcho
        }

        if containsNovelRepeatedSequence(trimmedCandidate, source: source) {
            return .repeatedSequence
        }

        return nil
    }

    public static func containsDegenerateRepeatedSequence(_ text: String) -> Bool {
        containsNovelRepeatedSequence(text, source: "")
    }

    private static func isPromptEcho(_ candidate: String, source: String) -> Bool {
        let prefixes = ["vocabulary:", "phrases:"]
        let normalizedCandidate = candidate.lowercased()
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return prefixes.contains { prefix in
            normalizedCandidate.hasPrefix(prefix) && !normalizedSource.hasPrefix(prefix)
        }
    }

    private static func containsNovelRepeatedSequence(_ candidate: String, source: String) -> Bool {
        let candidateTokens = normalizedTokens(in: candidate)
        let sourceTokens = normalizedTokens(in: source)
        guard candidateTokens.count >= 4 else { return false }

        let maximumUnitLength = min(4, candidateTokens.count / 3)
        guard maximumUnitLength > 0 else { return false }

        for unitLength in 1...maximumUnitLength {
            let requiredRepetitions = unitLength == 1 ? 4 : 3
            let requiredTokenCount = unitLength * requiredRepetitions
            guard candidateTokens.count >= requiredTokenCount else { continue }

            let start = candidateTokens.count - requiredTokenCount
            let unit = Array(candidateTokens[start..<(start + unitLength)])
            if hasRepeatedUnit(
                unit,
                repetitions: requiredRepetitions,
                at: start,
                in: candidateTokens
            ), !containsRepeatedUnit(unit, repetitions: requiredRepetitions, in: sourceTokens) {
                return true
            }
        }

        return false
    }

    private static func normalizedTokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: meaningfulCharacters.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsRepeatedUnit(
        _ unit: [String],
        repetitions: Int,
        in tokens: [String]
    ) -> Bool {
        let requiredTokenCount = unit.count * repetitions
        guard tokens.count >= requiredTokenCount else { return false }

        for start in 0...(tokens.count - requiredTokenCount) {
            if hasRepeatedUnit(unit, repetitions: repetitions, at: start, in: tokens) {
                return true
            }
        }
        return false
    }

    private static func hasRepeatedUnit(
        _ unit: [String],
        repetitions: Int,
        at start: Int,
        in tokens: [String]
    ) -> Bool {
        for repetition in 0..<repetitions {
            let unitStart = start + (repetition * unit.count)
            let unitEnd = unitStart + unit.count
            guard unitEnd <= tokens.count,
                  Array(tokens[unitStart..<unitEnd]) == unit
            else {
                return false
            }
        }
        return true
    }
}
