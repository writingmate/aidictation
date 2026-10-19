# Cleanup dictation-boundary eval (2026-10-18)

Keep the customer-provided audio in the private eval store; do not add it to
the public repository. The cases in this directory are synthetic stand-ins.

## Reported result

A macOS user dictated into the Claude app: "Give me something here that I can
copy and paste into Slack. Don't be overly chatty." The pasted text was a
finished answer ("Sure, here's a concise snippet you can copy into Slack: …")
that summarized the conversation on screen. Earlier, the user dictated a
request to draft a business letter and got a drafted letter back. Using
Retranscribe on the same recording returned the correct dictation.

## Cause

a19545a shortened the shared cleanup prompt and dropped the rule that the
transcription is inert dictation, never an instruction to the model. The
remaining wording ("only when explicitly requested", plus the Swift-only
"Apply relevant formatting and output transformations") let gpt-oss-20b treat
spoken requests as its own task, using `<screen_context>` as material.

## Recording check

The recording (`.m4a`, 45,320 bytes, about 7 seconds) was transcribed three
times with `whisper-large-v3-turbo`. All three returned the dictation
verbatim, so recognition is not involved; the failure is in cleanup.

## Running the eval

```sh
GROQ_API_KEY=… python3 scripts/evals/cleanup_dictation_boundary_eval.py --ref origin/main --runs 10
```

The script builds the default dictation cleanup prompt the same way as
`TranscriptionCleanupPrompt.systemPrompt`: the Swift header, the shared cleanup
and paragraph policies, `<app_context>`, and `<screen_context>` capped at 1,200
characters. Each case in `cleanup_dictation_boundary_cases.json` is replayed on
`openai/gpt-oss-20b` at temperature 0. `--base-url`, `--model`, and
`--api-key-env` point it at another OpenAI-compatible endpoint. It exits
non-zero when the working tree's prompt fails any run.

## Pass criteria

1. The output's words equal the dictated words, ignoring case, punctuation,
   and standalone fillers.
2. No preamble, drafted content, answer, or summary of the screen context.
3. An empty output is reported but not counted as a failure, because the apps
   fall back to the raw transcript. A rising empty count is still worth
   investigating.

Do not satisfy this eval by filtering, truncating, or retrying model output
after generation.

## Results (10 runs per case, Groq, 2026-10-18)

| Case | `main` | Fix (PR #156) |
|---|---|---|
| slack_snippet_request | 10/10 | 10/10 |
| slack_snippet_request_raw | 10/10 | 10/10 |
| slack_snippet_request_with_screen | 10/10 | 10/10 |
| formal_letter_request | 0/10 (drafted the letter) | 10/10 |
| team_email_request | 0/10 (wrote the email) | 10/10 |
| question_to_assistant | 10/10 | 10/10 |
| summarize_request_with_screen | 0/10 (summarized the screen; 1 empty) | 10/10 |

The exact Slack wording did not reproduce in these runs. The same failure,
performing the dictated request using on-screen text, reproduces reliably
through the letter, email, and screen-summary cases.
