$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Split-Path -Parent $scriptDir
$project = Join-Path $windowsDir "RecoveryContract\RecoveryContract.csproj"

dotnet run --project $project --configuration Release
if ($LASTEXITCODE -ne 0) {
    throw "Windows audio recovery contract failed."
}

$settingsViewModel = Get-Content -Raw (Join-Path $windowsDir "AIDictation\ViewModels\SettingsViewModel.cs")
if (-not $settingsViewModel.Contains('if (value == null || !_audioDeviceSelectionReady) return;') -or
    -not $settingsViewModel.Contains('_audioDeviceSelectionReady = true;')) {
    throw "Audio-device initialization must not erase the saved endpoint before enumeration completes."
}

$recorderSource = Get-Content -Raw (Join-Path $windowsDir "AIDictation\Services\AudioRecorderService.cs")
if (-not $recorderSource.Contains('format is WaveFormatExtensible extensible') -or
    -not $recorderSource.Contains('extensible.ToStandardWaveFormat()')) {
    throw "WASAPI extensible PCM/IEEE-float formats must be normalized before buffer conversion."
}

$historySource = Get-Content -Raw (Join-Path $windowsDir "AIDictation\Services\HistoryService.cs")
if (-not $historySource.Contains('_tombstoneFence.CanPublish(recording.Id)') -or
    -not $historySource.Contains('RemoveMetadataAfterTombstonesAsync(') -or
    -not $historySource.Contains('_tombstoneFence.Commit(tombstoned)')) {
    throw "History must fence late publications after durable Delete/Clear removal."
}
