#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROVIDERS = (ROOT / "Whishpermate/Whispermate/Models/APIProvider.swift").read_text()
TRANSCRIPTION_PROVIDERS = PROVIDERS.split("enum CodexTranscriptionSupport", 1)[0]
APP_STATE = (ROOT / "Whishpermate/Whispermate/Services/AppState.swift").read_text()
REALTIME = (ROOT / "Whishpermate/Whispermate/Services/OpenAIRealtimeTranscriptionClient.swift").read_text()
HISTORY = (ROOT / "Whishpermate/Whispermate/Views/HistoryMasterDetailView.swift").read_text()
SETTINGS = (ROOT / "Whishpermate/Whispermate/Views/SettingsView.swift").read_text()


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
    'provider == .soniox, isRetranscription' in APP_STATE
    and 'model = "soniox/stt-async-v5"' in APP_STATE,
    "AI Dictation retranscription is not pinned to Soniox v5 batch",
)
require(
    "onlineProvider: .soniox" in HISTORY,
    "History re-transcription does not route directly to AI Dictation",
)
require("RetranscriptionRouteMenu" not in HISTORY, "History still exposes a provider switch")
require('Button("ChatGPT")' not in HISTORY, "History still exposes ChatGPT transcription")
require('Text("Cloud Model")' not in SETTINGS, "Settings still exposes a cloud-model switch")
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
