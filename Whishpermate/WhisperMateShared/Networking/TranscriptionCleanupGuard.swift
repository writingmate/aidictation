import Foundation

/// Deterministic acceptance check for the text the cleanup model returns.
///
/// Dictation must always insert the speaker's own words. The prompt asks the
/// model to behave as an editor, but a prompt is probabilistic: an imperative
/// transcript ("write an email to…") can still come back fulfilled, answered,
/// or refused ("I'm sorry, but I can't help with that"). This guard rejects
/// output that reads like an assistant turn or that no longer resembles the
/// dictation, so callers insert the raw transcript instead. It never edits
/// the model output; it only decides between the cleaned text and the raw
/// transcript, which `AGENTS.md` defines as the fallback for failed cleanup.
public enum TranscriptionCleanupGuard {
    /// How far the accepted output may drift from the raw transcript.
    public enum Expectation: Sendable, Equatable {
        /// Dictation cleanup whose only reference context is vocabulary,
        /// phrases, replacements, and shortcut expansions. Output must keep
        /// the dictated words.
        case faithfulCleanup
        /// Dictation cleanup with user-authored formatting or context-rule
        /// instructions that may legitimately reword or extend the text.
        /// Only assistant-turn checks apply.
        case instructedCleanup
        /// Notes or Meetings output transformations, which restructure the
        /// text by design. Only assistant-turn checks apply.
        case transformation
    }

    public enum Rejection: Sendable, Equatable {
        /// The model returned nothing usable.
        case emptyOutput
        /// The output opens like a refusal or apology the speaker never said.
        case refusal
        /// The output opens or closes like an assistant reply ("Sure, here's…",
        /// "Let me know if…") the speaker never said.
        case assistantReply
        /// The output contains far more never-dictated words than the
        /// dictation itself, as when a request was carried out.
        case generatedContent
        /// Most dictated words are gone and most output words are new.
        case replacedContent
    }

    public struct Verdict: Sendable, Equatable {
        /// The text to insert: the cleaned output when accepted, otherwise the
        /// raw transcript.
        public let text: String
        public let rejection: Rejection?

        public var usedRawTranscript: Bool { rejection != nil }
    }

    private enum Constants {
        /// Standalone fillers the prompt removes; they never count as dropped words.
        static let fillers: Set<String> = [
            "um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "ugh",
        ]
        /// Characters of normalized output inspected for an opening or closing
        /// assistant pattern.
        static let edgeWindow = 160
        /// Below this many dictated words there is too little signal for the
        /// overlap check; the length and pattern checks still apply.
        static let minimumWordsForOverlapCheck = 4
        /// Never-dictated words must exceed both this floor and the dictation
        /// length before output counts as generated content.
        static let generatedWordFloor = 8
        /// `replacedContent` needs both: fewer than this share of dictated
        /// words retained…
        static let minimumRetainedFraction = 0.5
        /// …and more than this share of output words never dictated.
        static let maximumNovelFraction = 0.5
        /// Exact matching only beyond this many tokens on either side.
        static let fuzzyMatchingTokenLimit = 2_000
    }

    /// Regular expressions applied to the normalized head of the output
    /// (lowercased, punctuation removed, whitespace collapsed).
    private static let refusalOpeners: [String] = [
        #"^(im|i am) (sorry|afraid|unable|not able)\b"#,
        #"^(sorry|apologies|unfortunately)\b"#,
        #"^i apologi[sz]e\b"#,
        #"^i (cant|cannot|can not|wont|will not|must|do not|dont) (help|assist|comply|do|write|provide|create|generate|fulfill|complete|draft|compose|answer|share|continue|proceed|decline|support|produce|perform|respond|engage)\b"#,
        #"^as an ai\b"#,
        #"^as a language model\b"#,
        #"^i dont have (the ability|access|enough)\b"#,
        #"^(this|that|your) request (cant|cannot|can not|violates|goes|is not|isnt)\b"#,
        #"^no i (cant|cannot|wont)\b"#,
        #"^i (cant|cannot|can not) (help|assist)\b"#,
    ]

    private static let replyOpeners: [String] = [
        #"^(sure|certainly|of course|absolutely|gladly|happy to help|got it|no problem)( thing)? (here|below|this|is|i|the|a|heres|please)\b"#,
        #"^(heres|here is|here are|below is|below are|the following is|as requested|here you go)\b"#,
        #"^(id|i would|i d) be happy to\b"#,
        #"^i can (help|certainly|definitely|do that)\b"#,
        #"^(ive|i have) (drafted|written|prepared|created|composed|put together)\b"#,
        #"^hope this helps\b"#,
    ]

    /// Applied to the normalized tail. Each match is extended by the words
    /// that follow it so the support check sees the whole sign-off, not just
    /// its opener.
    private static let replyClosers: [String] = [
        #"\blet me know if (you|youd|you would|theres|there is|that)\b"#,
        #"\bhope (this|that) helps\b"#,
        #"\bfeel free to (adjust|edit|modify|change|tweak)\b"#,
        #"\bwould you like me to\b"#,
        #"\bis there anything else\b"#,
    ]
    private static let closerExtensionWords = 8

    // MARK: - Public API

    /// Chooses the text to insert.
    ///
    /// - Parameters:
    ///   - rawTranscript: The complete recognized transcript.
    ///   - cleanedOutput: The cleanup model's response.
    ///   - expectation: How much the output may legitimately differ.
    ///   - referenceText: Reference context the model may introduce into the
    ///     output without it counting as invented: vocabulary, replacement
    ///     targets, shortcut expansions, and similar.
    public static func resolve(
        rawTranscript: String,
        cleanedOutput: String,
        expectation: Expectation,
        referenceText: [String] = []
    ) -> Verdict {
        let trimmedRaw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCleaned = cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rejection = rejection(
            rawTranscript: trimmedRaw,
            cleanedOutput: trimmedCleaned,
            expectation: expectation,
            referenceText: referenceText
        ) {
            return Verdict(text: trimmedRaw, rejection: rejection)
        }
        return Verdict(text: trimmedCleaned, rejection: nil)
    }

    /// Returns why the output must not be inserted, or nil when it may be.
    public static func rejection(
        rawTranscript: String,
        cleanedOutput: String,
        expectation: Expectation,
        referenceText: [String] = []
    ) -> Rejection? {
        let cleaned = cleanedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return .emptyOutput }

        let rawTokens = tokens(of: rawTranscript)
        let rawBag = Bag(rawTokens)

        // A phrase the speaker also said ("I'm sorry, but I can't make it")
        // is their own text, so a pattern only counts when the raw
        // transcript does not contain the matched words.
        let normalizedCleaned = normalizedText(cleaned)
        let unsupported: (String) -> Bool = { !rawBag.supports(tokens(of: $0)) }
        if matches(of: refusalOpeners, in: head(of: normalizedCleaned)).contains(where: unsupported) {
            return .refusal
        }
        if matches(of: replyOpeners, in: head(of: normalizedCleaned)).contains(where: unsupported) {
            return .assistantReply
        }
        if matches(of: replyClosers, in: tail(of: normalizedCleaned), extendingBy: closerExtensionWords)
            .contains(where: unsupported)
        {
            return .assistantReply
        }

        guard expectation == .faithfulCleanup else { return nil }

        let dictated = rawTokens.filter { !Constants.fillers.contains($0) }
        let output = tokens(of: cleaned).filter { !Constants.fillers.contains($0) }
        guard !dictated.isEmpty, !output.isEmpty else { return nil }

        let reference = Set(referenceText.flatMap(tokens(of:)))
        let alignment = align(dictated: dictated, output: output)
        let novel = alignment.unmatchedOutput.filter { !reference.contains($0) }.count

        if novel > max(dictated.count, Constants.generatedWordFloor) {
            return .generatedContent
        }

        if dictated.count >= Constants.minimumWordsForOverlapCheck {
            let retainedFraction = Double(alignment.matched) / Double(dictated.count)
            let novelFraction = Double(novel) / Double(output.count)
            if retainedFraction < Constants.minimumRetainedFraction,
               novelFraction > Constants.maximumNovelFraction
            {
                return .replacedContent
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Lowercased words made of letters and digits. Apostrophes are dropped
    /// inside words so "can't" and "cant" compare equal. Scripts written
    /// without word spaces are split per character, so added punctuation in
    /// a Chinese or Japanese sentence does not read as replaced words.
    static func tokens(of text: String) -> [String] {
        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        for scalar in text.lowercased().unicodeScalars {
            if isUnspacedScript(scalar) {
                flush()
                words.append(String(scalar))
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                continue
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0x0E00...0x0E7F, // Thai
             0x20000...0x2FA1F: // CJK Extensions B and later
            return true
        default:
            return false
        }
    }

    private static func normalizedText(_ text: String) -> String {
        tokens(of: text).joined(separator: " ")
    }

    private static func head(of text: String) -> String {
        String(text.prefix(Constants.edgeWindow))
    }

    private static func tail(of text: String) -> String {
        String(text.suffix(Constants.edgeWindow))
    }

    /// Every match of every pattern, each extended by up to `extendingBy`
    /// following words of the text.
    private static func matches(
        of patterns: [String],
        in text: String,
        extendingBy extensionWords: Int = 0
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: range) {
                guard let matched = Range(match.range, in: text) else { continue }
                let phraseWordCount = text[matched].split(separator: " ").count
                let extended = text[matched.lowerBound...]
                    .split(separator: " ")
                    .prefix(phraseWordCount + extensionWords)
                    .joined(separator: " ")
                found.append(extended)
            }
        }
        return found
    }

    // MARK: - Alignment

    private struct Alignment {
        let matched: Int
        let unmatchedOutput: [String]
    }

    /// Greedy bag alignment: exact matches first, then near matches for
    /// spelling and recognition fixes, so "there" still pairs with "they're".
    private static func align(dictated: [String], output: [String]) -> Alignment {
        var remaining = Bag(dictated)
        var unmatched: [String] = []
        for word in output {
            if remaining.remove(word) {
                continue
            }
            unmatched.append(word)
        }

        let allowFuzzy = dictated.count <= Constants.fuzzyMatchingTokenLimit
            && output.count <= Constants.fuzzyMatchingTokenLimit
        guard allowFuzzy, !unmatched.isEmpty, !remaining.isEmpty else {
            return Alignment(matched: output.count - unmatched.count, unmatchedOutput: unmatched)
        }

        var stillUnmatched: [String] = []
        for word in unmatched {
            if let candidate = remaining.first(where: { isNearMatch($0, word) }) {
                _ = remaining.remove(candidate)
            } else {
                stillUnmatched.append(word)
            }
        }
        return Alignment(matched: output.count - stillUnmatched.count, unmatchedOutput: stillUnmatched)
    }

    static func isNearMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)
        guard shorter >= 4 else { return false }
        if longer - shorter > 2 {
            // A longer inflection of the same stem ("assess" / "assessment").
            return shorter >= 5 && (lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs))
        }
        let allowed = shorter >= 7 ? 2 : 1
        return editDistance(lhs, rhs, limit: allowed) <= allowed
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs.unicodeScalars)
        let b = Array(rhs.unicodeScalars)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private struct Bag {
        private var counts: [String: Int] = [:]

        init(_ words: [String]) {
            for word in words { counts[word, default: 0] += 1 }
        }

        var isEmpty: Bool { counts.isEmpty }

        mutating func remove(_ word: String) -> Bool {
            guard let count = counts[word], count > 0 else { return false }
            if count == 1 {
                counts.removeValue(forKey: word)
            } else {
                counts[word] = count - 1
            }
            return true
        }

        func first(where predicate: (String) -> Bool) -> String? {
            counts.keys.sorted().first(where: predicate)
        }

        /// True when every word appears in the bag, so the phrase could be
        /// the speaker's own.
        func supports(_ words: [String]) -> Bool {
            words.allSatisfy { counts[$0, default: 0] > 0 }
        }
    }
}
