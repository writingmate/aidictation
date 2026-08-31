import Foundation

/// Cleans up raw transcription output by removing hallucination artifacts and filler words
struct TranscriptionOutputFilter {
    private static let hallucinationPatterns = [
        #"\[.*?\]"#,
        #"\(.*?\)"#,
        #"\{.*?\}"#,
    ]

    static func filter(_ text: String) -> String {
        var result = text

        // Remove <TAG>...</TAG> blocks
        let tagPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove bracketed hallucinations
        for pattern in hallucinationPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
            }
        }

        // Clean up excess whitespace
        result = result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    static func removeStandaloneFillers(_ text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}\p{N}])(?:u+h+|u+m+|u+h+m+|e+r+m*|a+h+|h+m+|u+g+h+)(?![\p{L}\p{N}])(?:[,.!?…]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        var result = regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        result = result.replacingOccurrences(
            of: #"\s+([,.;:!?])"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\s{2,}"#,
            with: " ",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
