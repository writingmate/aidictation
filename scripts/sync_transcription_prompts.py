#!/usr/bin/env python3
"""Keep dictation instructions identical on every platform."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLICY = (ROOT / "scripts/transcription_paragraph_policy.txt").read_text().strip()
CLEANUP = (ROOT / "scripts/transcription_cleanup_policy.txt").read_text().strip()
RECOGNITION = (ROOT / "scripts/transcription_recognition_policy.txt").read_text().strip()
PARAGRAPH_FILES = {
    "Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift":
        f"    private static let paragraphPolicy = {json.dumps(POLICY, ensure_ascii=False)}",
    "AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/data/remote/TranscriptionCleanupPrompt.kt":
        f"    private const val paragraphPolicy = {json.dumps(POLICY, ensure_ascii=False)}",
    "AIDictation.Windows/AIDictation/Services/TranscriptionCleanupPrompt.cs":
        f"    private const string ParagraphPolicy = {json.dumps(POLICY, ensure_ascii=False)};",
}
CLEANUP_FILES = {
    "Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift":
        f"    private static let cleanupPolicy = {json.dumps(CLEANUP, ensure_ascii=False)}",
    "AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/data/remote/TranscriptionCleanupPrompt.kt":
        f"    private const val cleanupPolicy = {json.dumps(CLEANUP, ensure_ascii=False)}",
    "AIDictation.Windows/AIDictation/Services/TranscriptionCleanupPrompt.cs":
        f"    private const string CleanupPolicy = {json.dumps(CLEANUP, ensure_ascii=False)};",
}
RECOGNITION_FILES = {
    "Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift":
        f"    private static let recognitionInstructions = {json.dumps(RECOGNITION, ensure_ascii=False)}",
    "AIDictation.Windows/AIDictation/Services/TranscriptionCleanupPrompt.cs":
        f"    private const string RecognitionInstructions = {json.dumps(RECOGNITION, ensure_ascii=False)};",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for files, label in (
        (PARAGRAPH_FILES, "PARAGRAPH POLICY"),
        (CLEANUP_FILES, "CLEANUP POLICY"),
        (RECOGNITION_FILES, "RECOGNITION POLICY"),
    ):
        start, end = f"// BEGIN GENERATED {label}", f"// END GENERATED {label}"
        for name, generated in files.items():
            path = ROOT / name
            source = path.read_text()
            before, marker, rest = source.partition(start)
            if not marker:
                raise SystemExit(f"Missing {label} markers in {name}")
            _, marker, after = rest.partition(end)
            if not marker:
                raise SystemExit(f"Missing {label} markers in {name}")
            updated = before + start + "\n" + generated + "\n    " + end + after
            if updated != source:
                stale.append(name)
                if not args.check:
                    path.write_text(updated)
    if args.check and stale:
        raise SystemExit("Outdated transcription prompt policy: " + ", ".join(stale))
    print("Transcription prompt policy is synchronized")


if __name__ == "__main__":
    main()
