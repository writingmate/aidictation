#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOTNET_BIN="${DOTNET_BIN:-dotnet}"
OFFLINE_SOURCE="${TMPDIR:-/tmp}/aidictation-empty-nuget"
mkdir -p "$OFFLINE_SOURCE"

"$DOTNET_BIN" restore \
  "$WINDOWS_DIR/RecoveryContract/RecoveryContract.csproj" \
  --source "$OFFLINE_SOURCE"

"$DOTNET_BIN" run \
  --project "$WINDOWS_DIR/RecoveryContract/RecoveryContract.csproj" \
  --configuration Release \
  --no-restore

SETTINGS_VIEW_MODEL="$WINDOWS_DIR/AIDictation/ViewModels/SettingsViewModel.cs"
grep -Fq 'if (value == null || !_audioDeviceSelectionReady) return;' "$SETTINGS_VIEW_MODEL"
grep -Fq '_audioDeviceSelectionReady = true;' "$SETTINGS_VIEW_MODEL"

RECORDER_SOURCE="$WINDOWS_DIR/AIDictation/Services/AudioRecorderService.cs"
grep -Fq 'format is WaveFormatExtensible extensible' "$RECORDER_SOURCE"
grep -Fq 'extensible.ToStandardWaveFormat()' "$RECORDER_SOURCE"

HISTORY_SOURCE="$WINDOWS_DIR/AIDictation/Services/HistoryService.cs"
grep -Fq '_tombstoneFence.CanPublish(recording.Id)' "$HISTORY_SOURCE"
grep -Fq '_tombstoneFence.Commit(id)' "$HISTORY_SOURCE"
