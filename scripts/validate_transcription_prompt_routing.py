#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
args = parser.parse_args()

ROOT = args.root.resolve()
SHARED_SERVICE = ROOT / "Whishpermate/WhisperMateShared/Services/SharedTranscriptionService.swift"
APP_STATE = ROOT / "Whishpermate/Whispermate/Services/AppState.swift"
MAC_CLIENT = ROOT / "Whishpermate/Whispermate/Services/OpenAIClient.swift"
SHARED_CLIENT = ROOT / "Whishpermate/WhisperMateShared/Networking/OpenAIClient.swift"
WINDOWS_SERVICE = ROOT / "AIDictation.Windows/AIDictation/Services/TranscriptionService.cs"


def function_body(source: str, signature: str, next_signature: str) -> str:
    try:
        start = source.index(signature)
        end = source.index(next_signature, start)
    except ValueError as error:
        raise SystemExit(f"validator could not locate {signature!r} before {next_signature!r}") from error
    return source[start:end]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


shared_source = SHARED_SERVICE.read_text()
app_state_source = APP_STATE.read_text()
mac_client_source = MAC_CLIENT.read_text()
shared_client_source = SHARED_CLIENT.read_text()
windows_service_source = WINDOWS_SERVICE.read_text()

require(
    "expandShortcuts" not in shared_source and "shortcutExpansions" not in shared_source,
    "shared cleanup still mutates successful or raw-fallback text after the LLM decision",
)
require(
    "ApplyLiteralReplacements" not in windows_service_source,
    "Windows cleanup still mutates successful or raw-fallback text after the LLM decision",
)

shared_prompts = function_body(
    shared_source,
    "private static func buildPrompts(",
    "private static func serverPostProcessingPrompt(",
)
require(
    'postProcessingPromptComponents.append("Vocabulary:' in shared_prompts,
    "shared cleanup lost personal vocabulary",
)
require(
    'postProcessingPromptComponents.append("Phrases:' in shared_prompts,
    "shared cleanup lost personal phrases",
)
require(
    "sttPromptComponents.append(dictionaryHints)" in shared_prompts,
    "shared recognition lost vocabulary hints",
)
require(
    "sttPromptComponents.append(shortcutHints)" in shared_prompts,
    "shared recognition lost phrase hints",
)
require(
    'sttPromptComponents.append("Vocabulary:' not in shared_prompts
    and 'sttPromptComponents.append("Phrases:' not in shared_prompts,
    "shared recognition prompt contains cleanup-only labels",
)

shared_server_prompt = function_body(
    shared_source,
    "private static func serverPostProcessingPrompt(",
    "private static func applyLLMPassIfAvailable(",
)
require(
    "TranscriptionCleanupPrompt.systemPrompt(" in shared_server_prompt,
    "shared one-request cleanup is not using the generic prompt contract",
)
require(
    "transformationInstruction: transformationInstruction" in shared_server_prompt,
    "shared one-request cleanup lost Notes/Meetings output-mode routing",
)

shared_cleanup = function_body(
    shared_source,
    "private static func applyLLMPassIfAvailable(",
    "private static func transcribeWithoutDiarization(",
)
for method in ("applyFormattingRules", "applyNotesFormatting", "applyMeetingFormatting"):
    require(
        f"client.{method}(transcription: transcript, rules: rules)" in shared_cleanup,
        f"shared two-stage cleanup lost {method} context routing",
    )

shared_cloud = function_body(
    shared_source,
    "private static func transcribeWithCloud(",
    "private static func captureCleanupConfiguration(",
)
require(
    "postProcessingPrompt: cloud.isOneStage ? request.serverPostProcessingPrompt : nil" in shared_cloud,
    "shared one-request transcription lost cleanup context",
)
require(
    "cleanupMergedTranscript:" in shared_cloud and "applyLLMPassIfAvailable(" in shared_cloud,
    "shared chunked/two-stage transcription lost merged cleanup",
)

cleanup_builder = function_body(
    app_state_source,
    "private func buildTranscriptionPromptComponents()",
    "private func buildSTTHintPromptComponents()",
)
require(
    "dictionaryManager.transcriptionHints" in cleanup_builder
    and 'promptComponents.append("Vocabulary:' in cleanup_builder,
    "macOS cleanup lost personal vocabulary",
)
require(
    "shortcutManager.transcriptionHints" in cleanup_builder
    and 'promptComponents.append("Phrases:' in cleanup_builder,
    "macOS cleanup lost personal phrases",
)

stt_builder = function_body(
    app_state_source,
    "private func buildSTTHintPromptComponents()",
    "private func buildRealtimePrompt()",
)
require(
    "dictionaryManager.transcriptionHints" in stt_builder
    and "shortcutManager.transcriptionHints" in stt_builder,
    "macOS recognition lost vocabulary or phrase hints",
)
require(
    "dictionaryManager.formattingInstructions" in stt_builder
    and "shortcutManager.formattingInstructions" in stt_builder,
    "macOS recognition lost replacements or phrase expansions",
)
require(
    '"Vocabulary:' not in stt_builder and '"Phrases:' not in stt_builder,
    "macOS recognition prompt contains cleanup-only labels",
)

realtime_builder = function_body(
    app_state_source,
    "private func buildRealtimePrompt()",
    "private func singleAPILanguageCode()",
)
require(
    "buildSTTHintPromptComponents()" in realtime_builder,
    "realtime recognition is not using recognition-only hints",
)
require(
    "dictionaryManager.transcriptionKeywords" in app_state_source
    and "shortcutManager.transcriptionKeywords" in app_state_source,
    "modern transcription requests lost literal keyword hints",
)
require(
    "languageManager.apiLanguageCodes" in app_state_source,
    "modern transcription requests lost multiple language hints",
)
for field in ('transcription["keywords"]', 'transcription["languages"]'):
    require(
        field in (ROOT / "Whishpermate/Whispermate/Services/OpenAIRealtimeTranscriptionClient.swift").read_text(),
        f"realtime request mapping lost {field}",
    )
for field in ('name: "keywords"', 'name: "languages"'):
    require(field in mac_client_source, f"batch request mapping lost {field}")

command_context = function_body(
    app_state_source,
    "// Build context rules (same as transcription)",
    "// Execute the command (with or without target text)",
)
require(
    "dictionaryManager.transcriptionHints" in command_context
    and 'contextRules.append("Vocabulary:' in command_context,
    "command cleanup lost personal vocabulary",
)
require(
    "shortcutManager.transcriptionHints" in command_context
    and 'contextRules.append("Phrases:' in command_context,
    "command cleanup lost personal phrases",
)

mac_pipeline = function_body(
    app_state_source,
    "private func performTranscription(",
    "private func providerPostProcessingPrompt(",
)
require(
    "postProcessingPrompt: customCleanupPrompt" in mac_pipeline,
    "macOS one-request transcription lost cleanup context",
)
require(
    "cleanupMergedTranscript: mergedCleanup" in mac_pipeline,
    "macOS chunked transcription lost merged cleanup",
)
for method in ("applyFormattingRules", "applyNotesFormatting", "applyMeetingFormatting"):
    require(
        re.search(
            rf"client\.{method}\(\s*transcription: mergedRaw,\s*rules: promptComponents,",
            mac_pipeline,
        )
        is not None,
        f"macOS merged cleanup lost {method} mode routing",
    )

mac_server_prompt = function_body(
    app_state_source,
    "private func providerPostProcessingPrompt(",
    "private func applyLLMPassWithFallback(",
)
require(
    "TranscriptionCleanupPrompt.systemPrompt(" in mac_server_prompt,
    "macOS one-request cleanup is not using the generic prompt contract",
)
for context in (
    "formattingContext:",
    "languageContext: languageContext",
    "appContext: appContext",
    "transformationInstruction: transformationInstruction",
):
    require(context in mac_server_prompt, f"macOS one-request cleanup lost {context}")

for platform, source in (("macOS", mac_client_source), ("shared/iOS", shared_client_source)):
    methods = (
        ("func applyFormattingRules(", "func applyNotesFormatting(", None),
        (
            "func applyNotesFormatting(",
            "func applyMeetingFormatting(",
            "TranscriptionOutputMode.notesPostProcessingInstruction",
        ),
    )
    for signature, next_signature, transformation in methods:
        body = function_body(source, signature, next_signature)
        require(
            "TranscriptionCleanupPrompt.systemPrompt(" in body,
            f"{platform} {signature} is not using the generic prompt contract",
        )
        require(
            "formattingContext: rules" in body,
            f"{platform} {signature} lost personal/reference context",
        )
        require(
            "TranscriptionCleanupPrompt.userMessage(" in body,
            f"{platform} {signature} is not delimiting source text",
        )
        if transformation:
            require(transformation in body, f"{platform} Notes cleanup lost its output-mode instruction")

    meeting_body = source[source.index("func applyMeetingFormatting(") :]
    require(
        "TranscriptionCleanupPrompt.systemPrompt(" in meeting_body
        and "formattingContext: rules" in meeting_body
        and "TranscriptionCleanupPrompt.userMessage(" in meeting_body
        and "meetingsPostProcessingInstruction" in meeting_body,
        f"{platform} Meetings cleanup lost the generic prompt contract or context",
    )

print("transcription and cleanup context validation passed")
