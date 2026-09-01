#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/aidictation-apple-recovery.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
module_cache="$work_dir/module-cache"
mkdir -p "$module_cache"
cd "$repo_root"

python3 scripts/validate_transcription_prompt_routing.py

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift \
  scripts/validate_transcription_cleanup_prompt.swift \
  -o "$work_dir/validate-transcription-cleanup-prompt"
"$work_dir/validate-transcription-cleanup-prompt"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/Networking/AppleAudioHTTPRecovery.swift \
  scripts/validate_apple_http_audio_recovery.swift \
  -o "$work_dir/validate-apple-http"
"$work_dir/validate-apple-http"

swiftc -parse-as-library -module-cache-path "$module_cache" \
  Whishpermate/Whispermate/Services/MacAudioProcessingStore.swift \
  Whishpermate/Whispermate/Services/MacHistoryAudioDeletion.swift \
  scripts/validate_macos_audio_processing_store.swift \
  -framework AVFoundation -framework CryptoKit \
  -o "$work_dir/validate-macos-store"
"$work_dir/validate-macos-store"

swiftc -parse-as-library -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/Services/RecordingPreparationAttempt.swift \
  Whishpermate/WhisperMateShared/Services/RecordingFinalizationAttempt.swift \
  scripts/validate_macos_recording_recovery.swift \
  -o "$work_dir/validate-macos-recorder"
"$work_dir/validate-macos-recorder"

swiftc -parse-as-library -module-cache-path "$module_cache" \
  scripts/validate_macos_preparation_format_retry.swift \
  -o "$work_dir/validate-macos-source-change"
"$work_dir/validate-macos-source-change"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/Whispermate/Services/MacAsyncDeadline.swift \
  Whishpermate/Whispermate/Services/MacTerminationGuards.swift \
  scripts/validate_macos_lifecycle_guards.swift \
  -o "$work_dir/validate-macos-lifecycle"
"$work_dir/validate-macos-lifecycle"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/Whispermate/Services/SileroVAD.swift \
  Whishpermate/Whispermate/Services/VoiceActivityAnalyzer.swift \
  Whishpermate/Whispermate/Services/VoiceActivityDetector.swift \
  scripts/validate_macos_vad_recovery.swift \
  -framework AVFoundation -framework CoreML \
  -o "$work_dir/validate-macos-vad"
"$work_dir/validate-macos-vad"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/Whispermate/Services/MacTranscriptionAttemptSnapshot.swift \
  scripts/validate_macos_transcription_attempt_snapshot.swift \
  -o "$work_dir/validate-macos-snapshot"
"$work_dir/validate-macos-snapshot"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/Whispermate/Services/RealtimeTranscriptionFinishGate.swift \
  scripts/validate_macos_realtime_finalization.swift \
  -o "$work_dir/validate-macos-realtime-finalization"
"$work_dir/validate-macos-realtime-finalization"

swiftc -parse-as-library -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/WhisperMateShared.swift \
  Whishpermate/WhisperMateShared/Models/TranscriptionOutputMode.swift \
  Whishpermate/WhisperMateShared/Models/TranscriptionOptions.swift \
  Whishpermate/WhisperMateShared/Models/Recording.swift \
  Whishpermate/WhisperMateShared/Services/DebugLog.swift \
  Whishpermate/WhisperMateShared/Services/MobileAudioProcessingStore.swift \
  Whishpermate/WhisperMateShared/Services/IOSAudioProcessingDeadline.swift \
  Whishpermate/WhisperMateShared/Storage/HistoryManager.swift \
  scripts/validate_ios_audio_processing_recovery.swift \
  -framework AVFoundation \
  -o "$work_dir/validate-ios-store"
"$work_dir/validate-ios-store"

swiftc -parse-as-library -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/Services/DebugLog.swift \
  Whishpermate/WhisperMateShared/Services/KeyboardDictationHandoff.swift \
  scripts/validate_keyboard_audio_recovery.swift \
  -o "$work_dir/validate-keyboard"
"$work_dir/validate-keyboard"

swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$module_cache" \
  Whishpermate/WhisperMateShared/Services/RuntimeCallbackAttempt.swift \
  scripts/validate_parakeet_runtime_recovery.swift \
  -o "$work_dir/validate-parakeet-runtime"
"$work_dir/validate-parakeet-runtime"

echo "Apple audio recovery contract matrix passed"
