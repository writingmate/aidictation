#!/usr/bin/env python3
import argparse
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()

ROOT = args.root.resolve()
SHARED_SERVICE = ROOT / "Whishpermate/WhisperMateShared/Services/SharedTranscriptionService.swift"
APP_STATE = ROOT / "Whishpermate/Whispermate/Services/AppState.swift"


def function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


shared_source = SHARED_SERVICE.read_text()
app_state_source = APP_STATE.read_text()

shared_prompts = function_body(
    shared_source,
    "private static func buildPrompts(",
    "private static func applyLLMPassIfAvailable(",
)
if 'postProcessingPromptComponents.append("Vocabulary:' in shared_prompts:
    raise SystemExit("raw vocabulary is still routed to shared cleanup")
if 'postProcessingPromptComponents.append("Phrases:' in shared_prompts:
    raise SystemExit("raw phrases are still routed to shared cleanup")
if "sttPromptComponents.append(dictionaryHints)" not in shared_prompts:
    raise SystemExit("shared recognition lost vocabulary hints")
if "sttPromptComponents.append(shortcutHints)" not in shared_prompts:
    raise SystemExit("shared recognition lost phrase hints")
if '"Vocabulary:' in shared_prompts or '"Phrases:' in shared_prompts:
    raise SystemExit("shared recognition prompt still contains hardcoded hint labels")

cleanup_builder = function_body(
    app_state_source,
    "private func buildTranscriptionPromptComponents()",
    "private func buildSTTHintPromptComponents()",
)
if "transcriptionHints" in cleanup_builder:
    raise SystemExit("raw recognition hints are still routed to macOS cleanup")

stt_builder = function_body(
    app_state_source,
    "private func buildSTTHintPromptComponents()",
    "private func buildRealtimePrompt()",
)
if stt_builder.count("transcriptionHints") < 2:
    raise SystemExit("macOS recognition lost vocabulary or phrase hints")
if '"Vocabulary:' in stt_builder or '"Phrases:' in stt_builder:
    raise SystemExit("macOS recognition prompt still contains hardcoded hint labels")

realtime_builder = function_body(
    app_state_source,
    "private func buildRealtimePrompt()",
    "private func singleAPILanguageCode()",
)
if "buildSTTHintPromptComponents()" not in realtime_builder:
    raise SystemExit("realtime recognition is not using recognition-only hints")

command_context = function_body(
    app_state_source,
    "// Build context rules (same as transcription)",
    "// Execute the command (with or without target text)",
)
if "transcriptionHints" in command_context:
    raise SystemExit("raw recognition hints are still routed to command cleanup")

print("transcription prompt routing validation passed")
