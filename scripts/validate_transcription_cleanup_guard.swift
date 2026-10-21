import Foundation

/// Replays `scripts/evals/cleanup_output_guard_cases.json` through
/// `TranscriptionCleanupGuard` and fails when any case resolves differently
/// from its expected verdict. Run from the repository root.
@main
private struct ValidateTranscriptionCleanupGuard {
    private struct Suite: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let id: String
        let raw: String
        let cleaned: String
        let expectation: String
        let referenceText: [String]?
        let expect: String
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    private static func expectation(_ name: String, id: String) -> TranscriptionCleanupGuard.Expectation {
        switch name {
        case "faithfulCleanup": return .faithfulCleanup
        case "instructedCleanup": return .instructedCleanup
        case "transformation": return .transformation
        default: fail("\(id): unknown expectation \(name)")
        }
    }

    private static func rejection(_ name: String, id: String) -> TranscriptionCleanupGuard.Rejection? {
        switch name {
        case "accepted": return nil
        case "emptyOutput": return .emptyOutput
        case "refusal": return .refusal
        case "assistantReply": return .assistantReply
        case "generatedContent": return .generatedContent
        case "replacedContent": return .replacedContent
        default: fail("\(id): unknown expected verdict \(name)")
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let data = try Data(contentsOf: root.appendingPathComponent("scripts/evals/cleanup_output_guard_cases.json"))
        let suite = try JSONDecoder().decode(Suite.self, from: data)
        guard !suite.cases.isEmpty else { fail("guard fixture has no cases") }

        var failures: [String] = []
        var rejected = 0
        var accepted = 0
        for testCase in suite.cases {
            let expectation = expectation(testCase.expectation, id: testCase.id)
            let expected = rejection(testCase.expect, id: testCase.id)
            let verdict = TranscriptionCleanupGuard.resolve(
                rawTranscript: testCase.raw,
                cleanedOutput: testCase.cleaned,
                expectation: expectation,
                referenceText: testCase.referenceText ?? []
            )
            if verdict.rejection != expected {
                failures.append(
                    "\(testCase.id): expected \(expected.map { "\($0)" } ?? "accepted"), got \(verdict.rejection.map { "\($0)" } ?? "accepted")"
                )
                continue
            }
            let trimmedRaw = testCase.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedCleaned = testCase.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if expected == nil {
                accepted += 1
                if verdict.text != trimmedCleaned || verdict.usedRawTranscript {
                    failures.append("\(testCase.id): accepted output was not returned unchanged")
                }
            } else {
                rejected += 1
                if verdict.text != trimmedRaw || !verdict.usedRawTranscript {
                    failures.append("\(testCase.id): rejected output did not fall back to the raw transcript")
                }
            }
        }

        // The suite must keep exercising both outcomes and the reported shapes.
        for required in [
            "refusal_apology_after_email_request",
            "fulfilled_email_request",
            "fulfilled_slack_snippet_with_preamble",
            "answered_question",
            "imperative_email_request_kept",
            "draft_slack_request_kept",
            "answer_this_question_request_kept",
            "speakers_own_apology_kept",
        ] where !suite.cases.contains(where: { $0.id == required }) {
            failures.append("guard fixture lost required case \(required)")
        }
        if accepted == 0 || rejected == 0 {
            failures.append("guard fixture must contain accepted and rejected cases")
        }

        // The guard decides; it never edits. A rejected verdict is the raw
        // transcript verbatim and an accepted one is the model text verbatim.
        let passthrough = TranscriptionCleanupGuard.resolve(
            rawTranscript: "  keep this exact raw text  ",
            cleanedOutput: "I'm sorry, but I can't help with that.",
            expectation: .faithfulCleanup
        )
        if passthrough.text != "keep this exact raw text" || passthrough.rejection != .refusal {
            failures.append("rejected verdict did not return the trimmed raw transcript")
        }

        guard failures.isEmpty else {
            fail(failures.joined(separator: "\n"))
        }
        print("transcription cleanup guard contract: PASS (\(accepted) accepted, \(rejected) rejected)")
    }
}
