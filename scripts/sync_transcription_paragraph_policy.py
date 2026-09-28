#!/usr/bin/env python3
"""Keep the dictation paragraph instruction identical on every platform."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
POLICY = (ROOT / "scripts/transcription_paragraph_policy.txt").read_text().strip()
FILES = {
    "Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift":
        f"    private static let paragraphPolicy = {json.dumps(POLICY, ensure_ascii=False)}",
    "AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/data/remote/TranscriptionCleanupPrompt.kt":
        f"    private const val paragraphPolicy = {json.dumps(POLICY, ensure_ascii=False)}",
    "AIDictation.Windows/AIDictation/Services/TranscriptionCleanupPrompt.cs":
        f"    private const string ParagraphPolicy = {json.dumps(POLICY, ensure_ascii=False)};",
}
START = "// BEGIN GENERATED PARAGRAPH POLICY"
END = "// END GENERATED PARAGRAPH POLICY"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    stale = []
    for name, generated in FILES.items():
        path = ROOT / name
        source = path.read_text()
        before, marker, rest = source.partition(START)
        if not marker:
            raise SystemExit(f"Missing paragraph policy markers in {name}")
        _, marker, after = rest.partition(END)
        if not marker:
            raise SystemExit(f"Missing paragraph policy markers in {name}")
        updated = before + START + "\n" + generated + "\n    " + END + after
        if updated != source:
            stale.append(name)
            if not args.check:
                path.write_text(updated)
    if args.check and stale:
        raise SystemExit("Outdated paragraph policy: " + ", ".join(stale))
    print("Paragraph policy is synchronized")


if __name__ == "__main__":
    main()
