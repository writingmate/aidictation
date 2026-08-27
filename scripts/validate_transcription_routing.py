#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = (ROOT / "Whishpermate/Whispermate/Models/APIProvider.swift").read_text()
TRANSCRIPTION_PROVIDERS = PROVIDERS.split("enum CodexTranscriptionSupport", 1)[0]
APP_STATE = (ROOT / "Whishpermate/Whispermate/Services/AppState.swift").read_text()
REALTIME = (ROOT / "Whishpermate/Whispermate/Services/OpenAIRealtimeTranscriptionClient.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require('case parakeet' in TRANSCRIPTION_PROVIDERS, "offline transcription route is missing")
require('case aidictation = "custom"' in TRANSCRIPTION_PROVIDERS, "AI Dictation cloud route is missing")
require('case codex' in TRANSCRIPTION_PROVIDERS, "Codex route is missing")
require('case groq' not in TRANSCRIPTION_PROVIDERS, "stale Groq transcription provider remains")
require('case openai' not in TRANSCRIPTION_PROVIDERS, "stale OpenAI transcription provider remains")
require(
    'case .codex:\n            return .realtime' in TRANSCRIPTION_PROVIDERS,
    "Codex is not pinned to realtime transport",
)
require(
    'if provider == .codex, isRetranscription' in APP_STATE
    and 'transport = .batch' in APP_STATE,
    "ChatGPT retranscription is not pinned to batch transport",
)
require(
    'model = isRetranscription\n                ? "gpt-transcribe"' in APP_STATE,
    "AI Dictation retranscription is not mapped to gpt-transcribe",
)
require(
    'https://chatgpt.com/backend-api/transcribe' in PROVIDERS,
    "ChatGPT batch transcription endpoint is missing",
)
require(
    '"Realtime transcription did not complete. Your recording is saved."' in APP_STATE,
    "live stream failure does not preserve an actionable terminal error",
)
require(
    'wss://chatgpt.com/backend-api/dictation/stream' in PROVIDERS + REALTIME,
    "Codex WebSocket endpoint is missing",
)
for protocol in ("chatgpt-dictation", "openai-bearer.", "codex-desktop"):
    require(protocol in REALTIME, f"Codex WebSocket protocol is missing: {protocol}")

print("transcription routing contract: PASS")
