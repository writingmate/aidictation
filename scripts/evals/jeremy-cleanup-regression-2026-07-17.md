# Cloud cleanup regression eval (2026-07-17)

Keep this customer-provided audio in the private eval store; do not add it to
the public repository.

## Recording identity

- Original filename: `recording_1784308821.162277 (1).m4a`
- SHA-256: `664c0e0d793bcdc01a68851c2da54c8627bfd9b3d987cff84b70adbe3179d3e0`
- Size: 574,812 bytes
- Duration: 66.362630 seconds
- Audio: AAC, mono, 44.1 kHz

## Reported result

The returned text ended after "sell it" with `Volac` repeated five times. The
recording contains about 24 more seconds of speech concerning reuse of a sales
page or pitch sequencing, standalone use, and integration into an existing
program.

The request also supplied the same raw custom-vocabulary list to recognition
and cleanup.

## Reproduction evidence

On 2026-07-17, the recording was replayed twice against production with the
same recognition hint and temperature:

- Recognition only (`656f928c-d39c-4cd4-b603-f056026b0231`) returned the full
  858-byte transcript, including the speech after "sell it", with no loop.
- Cleanup enabled (`4416f9c3-65e4-4302-ac32-5476f1472392`) returned 718 bytes,
  deleted that tail, invented names, and repeated a vocabulary term seven times.

This isolates the failure to cleanup prompting for this eval run.

## Eval setup

Run the complete recording through cloud mode with cleanup enabled and a
non-empty custom vocabulary. Use the production model and temperature. Inspect
the final text and both prompt payloads.

## Pass criteria

1. The final text retains the speech after "sell it".
2. The final text has no invented repeated-token or repeated-phrase suffix.
3. The final text does not echo a vocabulary or phrase list.
4. Raw vocabulary and phrase lists appear only in the recognition prompt.
5. Cleanup receives only generic cleanup instructions and explicit user-defined
   replacements or expansions.
6. Production prompts contain no customer-specific terms or failure tokens.
7. The recognition hint contains only dynamic user-provided terms, with no
   hardcoded vocabulary or phrase label.

This is a prompt-routing and prompt-quality eval. Do not satisfy it by deleting,
truncating, replacing, or otherwise filtering model output after generation.

## Prompt A/B evidence

Using recognition only, the labeled vocabulary prompt truncated the tail in one
of three fresh trials (492 bytes). A bare dynamic term list returned the same
complete 861-byte transcript in all three trials. With that bare term list and
no raw vocabulary in cleanup, both the current production cleanup prompt and the
generic preview prompt retained the full tail without a repeated suffix.

The final prompt-only implementation was then replayed three times against the
preview deployment with the corrected client payload (bare recognition hints,
no raw vocabulary in cleanup):

- `5402b2d2-033e-478e-b7ce-6d9d73d63cd9`: full tail present; no loop or hint echo.
- `e15f523c-cbb2-4f90-9559-5168426415eb`: full tail present; no loop or hint echo.
- `771b1a48-f728-41f3-b908-871d8030da67`: full tail present; no loop or hint echo.

No output filtering, retry heuristic, or customer-specific prompt term was used.

After backend merge commit `90c346200a813ad3630ee81df93075dbaab8800c`
reached production, the same corrected payload passed three more replays against
`writingmate.ai`:

- `7278557c-f4ed-463b-a8da-9a333edd41d3`: full tail present; no loop or hint echo.
- `2d8b7fc3-6052-46b5-99eb-93d2010ec4d8`: full tail present; no loop or hint echo.
- `615394e7-744c-4122-8585-df9719c73f64`: full tail present; no loop or hint echo.
