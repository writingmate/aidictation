#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def source(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def require(text: str, fragment: str, label: str) -> None:
    if fragment not in text:
        raise SystemExit(f"{label}: missing {fragment!r}")


def reject(text: str, fragment: str, label: str) -> None:
    if fragment in text:
        raise SystemExit(f"{label}: stale value {fragment!r}")


mac_provider = source("Whishpermate/Whispermate/Models/APIProvider.swift")
require(
    mac_provider,
    "@Published var selectedProvider: TranscriptionProvider = .soniox",
    "macOS selected provider",
)
require(
    mac_provider,
    "@Published private(set) var selectedOnlineProvider: TranscriptionProvider = .soniox",
    "macOS online provider",
)
require(
    mac_provider,
    "var providers: [TranscriptionProvider] = [.soniox]",
    "macOS provider menu",
)
require(mac_provider, 'case .soniox: return "AI Dictation"', "macOS product label")
require(mac_provider, "case .aidictation:\n            return .soniox", "macOS migration")
reject(mac_provider, 'return "Fast streaming"', "macOS implementation label")

mac_state = source("Whishpermate/Whispermate/Services/AppState.swift")
require(
    mac_state,
    'model: "groq/whisper-large-v3-turbo"',
    "macOS batch fallback",
)
require(mac_state, "snapshot.usingBatchFallback()", "macOS fallback activation")

shared_provider = source("Whishpermate/WhisperMateShared/Models/APIProvider.swift")
require(shared_provider, 'case .custom: return "AI Dictation"', "Apple shared label")
require(
    shared_provider,
    'case .custom: return "openai/gpt-transcribe"',
    "Apple shared batch model",
)
require(
    shared_provider,
    "@Published public var selectedProvider: TranscriptionProvider = .custom",
    "Apple shared default",
)

android = source(
    "AIDictationAndroid/app/src/main/java/com/whispermate/aidictation/"
    "data/preferences/ApiConfigManager.kt"
)
require(
    android,
    'ApiProvider.WRITINGMATE -> "openai/gpt-transcribe"',
    "Android batch model",
)
reject(android, "soniox/stt-async-v5", "Android async Soniox rollout")
android_workflow = source(".github/workflows/android-build.yml")
require(
    android_workflow,
    "github.event_name == 'pull_request' && 'pull-request' || 'release'",
    "Android pull-request environment",
)
reject(android_workflow, "soniox/stt-async-v5", "Android release async Soniox rollout")

windows = source("AIDictation.Windows/AIDictation/Helpers/BuildConfig.cs")
require(
    windows,
    'TranscriptionModel = "openai/gpt-transcribe"',
    "Windows batch model",
)
reject(windows, "soniox/stt-async-v5", "Windows async Soniox rollout")

print("Soniox realtime default and batch controls: PASS")
