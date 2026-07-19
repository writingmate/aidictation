# Agent Instructions

## User-Facing Copy

- Write labels, alerts, buttons, and other user-visible text from the user's perspective.
- Do not expose implementation names or technical language in user-facing labels.
- Prefer plain product terms such as "offline mode" and "cloud mode" over engine, model, provider, or framework names.
- Keep mode-switch explanations focused on what will happen for the user.

## Transcription and Cleanup Architecture

- LLM cleanup is core transcription infrastructure. Do not remove it, bypass it, or stop sending it user context as a workaround for model-quality bugs unless the product owner explicitly approves an architecture change.
- Support both production pipeline shapes:
  - In a one-stage AI transcription-and-cleanup flow, provide the model with all applicable personal vocabulary, phrases, replacements, expansions, formatting instructions, and contextual rules.
  - In a two-stage flow, provide recognition with appropriate speech-recognition hints, then provide the cleanup LLM with the complete raw transcript plus all applicable personal vocabulary, phrases, replacements, expansions, formatting instructions, and contextual rules.
- Personal vocabulary must reach the cleanup LLM even when entries contain no explicit replacements. The cleanup LLM is responsible for using that reference context to correct spelling and recognition mistakes.
- Delimit transcript content from reference context and instruct the LLM to use reference terms only when supported by the transcript. Never fix hallucinations by removing vocabulary from cleanup, hardcoding customer examples, or programmatically deleting generated words.
- Preserve the complete transcript through its final token. Prompt changes must remain generic and must not include customer recordings, names, vocabulary terms, or reported failure tokens.
- Any change to transcription context or cleanup behavior must cover both pipeline shapes and all supported platforms, with regression checks for vocabulary-only entries, explicit replacements, phrase expansions, formatting rules, complete-tail preservation, and unsupported-term non-insertion.

## Audio Processing Recovery

- Follow `docs/audio-processing-failure-contract.md` on macOS, iOS and its keyboard extension, Android, and Windows.
- Persist managed source audio and a stable recording ID before recognition. Every attempt must have one owner, a deadline, cancellation, ordered checkpoints, and a terminal persisted state.
- A timeout must return the UI to idle even when native work ignores cancellation. Fence late callbacks so an abandoned attempt cannot overwrite, recreate, or delete newer state.
- Retry transient transport failures only under the shared bounded policy. Do not retry permanent `4xx` responses or fully received malformed responses. Split rejected `413` leaves sequentially without replaying completed chunks.
- Treat cleanup as optional after complete raw recognition. Cleanup failure or empty output keeps the raw transcript.
- Delete and Clear must either refuse active work or win durably over it. Never submit audio known to be truncated or unfinalized, and never delete the only recoverable source.
