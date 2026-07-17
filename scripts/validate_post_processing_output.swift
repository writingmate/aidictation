import Foundation

struct ValidationCase {
    let name: String
    let candidate: String
    let source: String
    let expected: TranscriptionTextSanitizer.PostProcessingRejectionReason?
}

@main
enum Main {
    static func main() {
        let source = "Okay, Claude, I'm back at this. The monthly revenue report is fine."
        let cases = [
            ValidationCase(
                name: "rejects repeated appended token",
                candidate: source + " Volac Volac Volac Volac Volac.",
                source: source,
                expected: .repeatedSequence
            ),
            ValidationCase(
                name: "rejects repeated multi-word loop",
                candidate: source + " Sermont Strieg Sermont Strieg Sermont Strieg.",
                source: source,
                expected: .repeatedSequence
            ),
            ValidationCase(
                name: "preserves repetition present in speech",
                candidate: "No, no, no, no. That is not what I meant.",
                source: "no no no no that is not what i meant",
                expected: nil
            ),
            ValidationCase(
                name: "allows ordinary corrections to introduce words",
                candidate: "Ashley uses ThriveCart for the monthly revenue report.",
                source: "ashley uses thrive cart for the monthly revenue report",
                expected: nil
            ),
            ValidationCase(
                name: "rejects vocabulary instruction echo",
                candidate: "Vocabulary: Turo, Ashley, ThriveCart",
                source: source,
                expected: .promptEcho
            ),
            ValidationCase(
                name: "allows dictated vocabulary label",
                candidate: "Vocabulary: Turo, Ashley, and ThriveCart.",
                source: "Vocabulary: Turo Ashley and ThriveCart",
                expected: nil
            ),
            ValidationCase(
                name: "rejects empty cleanup output",
                candidate: " \n ",
                source: source,
                expected: .emptyOutput
            ),
        ]

        for testCase in cases {
            let actual = TranscriptionTextSanitizer.postProcessingRejectionReason(
                candidate: testCase.candidate,
                source: testCase.source
            )
            if actual != testCase.expected {
                fputs(
                    "post-processing validation failed: \(testCase.name): expected \(String(describing: testCase.expected)), got \(String(describing: actual))\n",
                    stderr
                )
                exit(1)
            }
        }

        let rawDegeneration = "Okay, Claude, I'm back at this. I think what we want to do for the 3% math, I think that's fine that we can also deduct processor fees—Stripe, PayPal, whatever—exactly as ThriveCart reports them. I think that's fine to add that as a deduction. For the monthly revenue report, we can do that. We're happy to pull that for her. For the IP clause, I agree with your split-ownership proposal, where basically if Ashley and Gemma build something together, it's okay for either of them to sell it. Volac Volac Volac Volac Volac."
        guard rawDegeneration.count == 522 else {
            fputs("transcription validation failed: production fixture is not the expected 522 characters\n", stderr)
            exit(1)
        }
        guard TranscriptionTextSanitizer.containsDegenerateRepeatedSequence(rawDegeneration) else {
            fputs("transcription validation failed: raw repeated-token degeneration was not detected\n", stderr)
            exit(1)
        }

        guard !TranscriptionTextSanitizer.containsDegenerateRepeatedSequence(
            "No, no, no. That is not what I meant."
        ) else {
            fputs("transcription validation failed: ordinary emphasis was rejected\n", stderr)
            exit(1)
        }

        guard !TranscriptionTextSanitizer.containsDegenerateRepeatedSequence(
            "No, no, no, no, that is not what I meant."
        ) else {
            fputs("transcription validation failed: non-suffix repetition was rejected\n", stderr)
            exit(1)
        }

        print("transcription output validation ok: \(cases.count + 3) cases")
    }
}
