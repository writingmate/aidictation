# Repeated-suffix transcription eval (2026-07-17)

This customer-provided recording is a regression eval for cloud transcription and
cleanup. Keep the audio in the private eval store; do not add it to the public
repository.

## Recording identity

- Original filename: `recording_1784308821.162277 (1).m4a`
- SHA-256: `664c0e0d793bcdc01a68851c2da54c8627bfd9b3d987cff84b70adbe3179d3e0`
- Size: 574,812 bytes
- Duration: 66.362630 seconds
- Audio: AAC, mono, 44.1 kHz

## Production failure

The recognition request returned a coherent partial transcript followed by
`Volac` five times. Cleanup preserved the same 522-character result. About 24
seconds of speech after "sell it" were missing.

The request included this same raw text as the recognition hint and cleanup
rule:

```text
Vocabulary: Turo, Ashley, Thrivecart, Claude, Privanza, Liam, Nash, FleetSync, FleetGuardian, FleetSheet, FleetAutomations, Claude Cowork
```

## Reference content

The recording continues after "it's okay for either of them to sell it" with
the speaker explaining that Ashley does not want Gemma to reuse her sales-page
or pitch sequencing as a standalone product, but is fine with Gemma integrating
a Claude-related scale into an existing program that is not specifically about
that material.

## Pass criteria

1. The result must not contain `Volac` or another novel repeated-token suffix.
2. The result must retain the speech after "sell it"; deleting the bad suffix
   alone is a failure.
3. The result must not echo a `Vocabulary:` or `Phrases:` list.
4. Vocabulary may guide recognition, but the raw list must not be supplied as a
   cleanup instruction.
5. If the first recognition result degenerates, retry once without vocabulary
   hints. Record both attempts in diagnostics.

The deterministic output checks live in
`scripts/validate_post_processing_output.swift`. Run this audio eval against
each supported cloud recognition route before shipping transcription or prompt
changes.
