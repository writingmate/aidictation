# End-to-end audio test: plays synthesized speech into a virtual audio cable while
# holding the global dictation hotkey (F8), then asserts the app captured non-silent
# audio, transcribed it, and pasted the text into a focused Notepad window.
# Requires: a loopback capture device (VB-CABLE) as the default mic, ffmpeg on PATH.
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Speech
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class E2ENative {
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$appData = Join-Path $env:APPDATA "AIDictation"
$phrase = "Hello world, this is a dictation test."
$script:appProc = $null
$script:notepadProc = $null

function Take-Screenshot([string]$Name) {
    try {
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $OutDir "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        Write-Host "Captured $Name.png"
    } catch { Write-Host "Screenshot $Name failed: $_" }
}

function Collect-Diagnostics {
    foreach ($f in @("history.json", "settings.json", "error.log")) {
        $p = Join-Path $appData $f
        if (Test-Path $p) { Copy-Item $p (Join-Path $OutDir $f) -Force }
    }
    $wavs = Get-ChildItem $appData -Recurse -Filter "*.wav" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2
    foreach ($w in $wavs) { Copy-Item $w.FullName (Join-Path $OutDir $w.Name) -Force }
    $errLog = Join-Path $appData "error.log"
    if (Test-Path $errLog) {
        Write-Host "::warning::error.log present:"
        Get-Content $errLog | Select-Object -First 40 | Write-Host
    }
}

function Stop-Procs {
    foreach ($p in @($script:appProc, $script:notepadProc)) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

try {
    # --- 1. Verify a capture device exists (VB-CABLE loopback) ---
    $dshow = & ffmpeg -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    Write-Host "DirectShow devices:`n$dshow"
    if ($dshow -notmatch "(?i)cable output|virtual") {
        Write-Host "::warning::No VB-CABLE capture device visible via DirectShow; continuing (WASAPI endpoint may still exist)"
    }

    # --- 2. Synthesize the spoken phrase ---
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $speechWav = Join-Path $tempRoot "speech.wav"
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $synth.Rate = -1
    $synth.SetOutputToWaveFile($speechWav)
    $synth.Speak($phrase)
    $synth.Dispose()
    Write-Host "Synthesized speech: $speechWav ($((Get-Item $speechWav).Length) bytes)"

    # --- 3. Seed settings: skip onboarding, keep default F8 push-to-talk hotkey ---
    New-Item -ItemType Directory -Force -Path $appData | Out-Null
    @"
{
  "onboardingCompleted": true,
  "currentOnboardingStep": 7,
  "pushToTalk": true,
  "muteAudioWhenRecording": false,
  "enableLLMPostProcessing": false,
  "transcriptionProvider": "aidictation",
  "selectedLanguages": ["en"],
  "hideIdleOverlay": false,
  "overlayPosition": "Bottom",
  "overlayColorTheme": "Orange",
  "launchAtStartup": false
}
"@ | Set-Content -Path (Join-Path $appData "settings.json") -Encoding UTF8

    # --- 4. Launch the app ---
    Write-Host "Launching $ExePath"
    $script:appProc = Start-Process -FilePath $ExePath -PassThru
    Start-Sleep -Seconds 10
    if ($script:appProc.HasExited) { throw "App exited immediately with code $($script:appProc.ExitCode)" }
    Take-Screenshot "01-app-started"

    # --- 5. Open Notepad as the paste target and focus it ---
    $script:notepadProc = Start-Process notepad -PassThru
    Start-Sleep -Seconds 3
    $script:notepadProc.Refresh()
    [E2ENative]::SetForegroundWindow($script:notepadProc.MainWindowHandle) | Out-Null
    (New-Object -ComObject WScript.Shell).AppActivate($script:notepadProc.Id) | Out-Null
    Start-Sleep -Milliseconds 800
    Take-Screenshot "02-notepad-focused"

    # --- 6. Hold F8 (push-to-talk), play the phrase into the default output ---
    #        VB-CABLE loops default output back into the default capture device.
    $VK_F8 = 0x77
    $KEYEVENTF_KEYUP = 0x2
    [E2ENative]::keybd_event($VK_F8, 0, 0, [UIntPtr]::Zero)
    Write-Host "F8 down (recording should start)"
    Start-Sleep -Milliseconds 900

    $playSw = [System.Diagnostics.Stopwatch]::StartNew()
    $player = New-Object System.Media.SoundPlayer $speechWav
    $player.PlaySync()
    $playSw.Stop()
    Write-Host "Finished playing phrase in $([int]$playSw.ElapsedMilliseconds) ms"
    if ($playSw.ElapsedMilliseconds -lt 1500) {
        Write-Host "::warning::Playback returned suspiciously fast - likely no working render device, captured audio will be silent"
    }
    Start-Sleep -Milliseconds 600
    Take-Screenshot "03-recording"

    [E2ENative]::keybd_event($VK_F8, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    Write-Host "F8 up (recording stopped, transcription begins)"

    # --- 7. Wait for the transcription to land in history.json ---
    $historyPath = Join-Path $appData "history.json"
    $deadline = (Get-Date).AddSeconds(90)
    $historyHit = $false
    while ((Get-Date) -lt $deadline) {
        $raw = Get-Content $historyPath -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw -match "(?i)hello") { $historyHit = $true; break }
        if ($raw -and $raw -match '"(errorMessage|ErrorMessage)"\s*:\s*"[^"]+"') {
            Write-Host "History contains an error entry:"
            Write-Host $raw
            break
        }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 2
    Take-Screenshot "04-after-transcription"

    # --- 8. Read the Notepad buffer via UI Automation ---
    function Read-NotepadText {
        $text = ""
        try {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle($script:notepadProc.MainWindowHandle)
            foreach ($ct in @([System.Windows.Automation.ControlType]::Document, [System.Windows.Automation.ControlType]::Edit)) {
                $cond = New-Object System.Windows.Automation.PropertyCondition(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ct)
                $el = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
                if ($el) {
                    try {
                        $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
                        $text = $tp.DocumentRange.GetText(100000)
                    } catch {
                        try {
                            $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                            $text = $vp.Current.Value
                        } catch { }
                    }
                    if ($text) { break }
                }
            }
        } catch { Write-Host "Notepad UIA read failed: $_" }
        return $text
    }
    $notepadText = Read-NotepadText
    Write-Host "Notepad content: '$notepadText'"

    # --- 8b. Diagnostics: where did the pipeline stop? ---
    $clipText = ""
    try { $clipText = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
    Write-Host "Clipboard after transcription: '$clipText'"

    if ($notepadText -notmatch "(?i)hello" -and "$clipText" -match "(?i)hello") {
        Write-Host "App paste missing but clipboard holds transcript - probing manual Ctrl+V via keybd_event"
        [E2ENative]::SetForegroundWindow($script:notepadProc.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 600
        $VK_CONTROL = 0x11; $VK_V = 0x56
        [E2ENative]::keybd_event($VK_CONTROL, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 50
        [E2ENative]::keybd_event($VK_V, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 50
        [E2ENative]::keybd_event($VK_V, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        [E2ENative]::keybd_event($VK_CONTROL, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        Start-Sleep -Seconds 1
        $manualPaste = Read-NotepadText
        Write-Host "Notepad after manual Ctrl+V: '$manualPaste'"
    }

    # --- 9. Find the captured WAV and verify it is non-silent ---
    $wav = Get-ChildItem $appData -Recurse -Filter "*.wav" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $wav) { throw "FAIL: app produced no recorded WAV under $appData (capture never started or file was deleted)" }
    Write-Host "Recorded WAV: $($wav.FullName) ($($wav.Length) bytes)"
    if ($wav.Length -lt 50KB) { throw "FAIL: recorded WAV is suspiciously small ($($wav.Length) bytes) - likely silent/empty capture" }

    $volOut = & ffmpeg -hide_banner -i $wav.FullName -af volumedetect -f null NUL 2>&1 | Out-String
    Write-Host $volOut
    if ($volOut -match "mean_volume:\s*(-?[\d.]+)\s*dB") {
        $meanVol = [double]$Matches[1]
        if ($meanVol -lt -50) { throw "FAIL: recorded audio is effectively silent (mean_volume=$meanVol dB) - the mic loopback did not capture the played phrase" }
        Write-Host "PASS: captured audio is non-silent (mean_volume=$meanVol dB)"
    } else {
        Write-Host "::warning::Could not parse volumedetect output; relying on file size only"
    }

    # --- 10. Transcription + paste assertions (need backend key baked into build) ---
    if (-not $env:TRANSCRIPTION_API_KEY) {
        Write-Host "::warning::TRANSCRIPTION_API_KEY not set - capture verified, skipping transcription/paste assertions"
    } else {
        if (-not $historyHit) {
            $raw = Get-Content $historyPath -Raw -ErrorAction SilentlyContinue
            throw "FAIL: transcript containing 'hello' never appeared in history.json. Contents: $raw"
        }
        Write-Host "PASS: history.json contains the transcribed phrase"

        if ($notepadText -notmatch "(?i)hello") {
            throw "FAIL: transcribed text was not pasted into the focused Notepad window. Buffer: '$notepadText'"
        }
        Write-Host "PASS: transcribed text was pasted into Notepad"
    }

    if ($script:appProc.HasExited) { throw "FAIL: app crashed during the flow (exit code $($script:appProc.ExitCode))" }
    Write-Host "Audio E2E completed successfully"
}
finally {
    Collect-Diagnostics
    Take-Screenshot "99-final"
    Stop-Procs
}
