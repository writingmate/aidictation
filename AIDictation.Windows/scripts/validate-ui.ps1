param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$ShotDir,
    [string]$VideoDir = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
if (-not $VideoDir) {
    $VideoDir = Join-Path (Split-Path $ShotDir -Parent) "videos"
}
New-Item -ItemType Directory -Force -Path $VideoDir | Out-Null

function Get-FfmpegPath {
    $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ffmpeg) { return [string]$ffmpeg.Source }

    $choco = Get-Command choco -ErrorAction SilentlyContinue
    if ($choco) {
        & choco install ffmpeg -y --no-progress | Out-Host
        $ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if ($ffmpeg) { return [string]$ffmpeg.Source }

        $shim = Join-Path $env:ChocolateyInstall "bin/ffmpeg.exe"
        if (Test-Path $shim) { return [string]$shim }
    }

    throw "ffmpeg is required to capture the overlay video"
}

function Capture-OverlayVideo([string]$AppPath) {
    $videoPath = Join-Path $VideoDir "overlay-states.mp4"
    $logPath = Join-Path $VideoDir "ffmpeg-overlay.log"
    $ffmpeg = Get-FfmpegPath
    Remove-Item $videoPath, $logPath -Force -ErrorAction SilentlyContinue

    Write-Host "Capturing overlay state video to $videoPath"
    $args = @(
        "-y",
        "-loglevel", "warning",
        "-f", "gdigrab",
        "-framerate", "30",
        "-i", "desktop",
        "-t", "12",
        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
        "-pix_fmt", "yuv420p",
        "-vcodec", "libx264",
        "-preset", "veryfast",
        $videoPath
    )

    $recorder = Start-Process -FilePath $ffmpeg -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $logPath
    Start-Sleep -Milliseconds 1200
    $demo = Start-Process -FilePath $AppPath -ArgumentList "--validate-overlay" -PassThru

    try {
        Wait-Process -Id $demo.Id -Timeout 20
    }
    catch {
        Stop-Process -Id $demo.Id -Force -ErrorAction SilentlyContinue
        throw "Overlay validation run did not exit in time"
    }
    $demo.Refresh()
    if ($demo.ExitCode -ne 0) {
        throw "Overlay validation run failed with exit code $($demo.ExitCode)"
    }

    $recorderTimedOut = $false
    try {
        $recorder.Refresh()
        if (-not $recorder.HasExited) {
            Wait-Process -Id $recorder.Id -Timeout 35
        }
    }
    catch {
        $stillRunning = Get-Process -Id $recorder.Id -ErrorAction SilentlyContinue
        if ($stillRunning) {
            $recorderTimedOut = $true
            Write-Host "::warning::Overlay video recorder did not exit in time; stopping it after the video file was written"
            Stop-Process -Id $recorder.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }
    }

    try { $recorder.Refresh() } catch { }

    if (-not (Test-Path $videoPath) -or (Get-Item $videoPath).Length -lt 1000) {
        if (Test-Path $logPath) { Get-Content $logPath | Write-Host }
        throw "Overlay video was not created"
    }

    if (-not $recorderTimedOut -and $recorder.HasExited -and $recorder.ExitCode -ne 0) {
        if (Test-Path $logPath) { Get-Content $logPath | Write-Host }
        throw "Overlay video capture failed with exit code $($recorder.ExitCode)"
    }

    Write-Host "Captured overlay video $videoPath"
}

function Take-Screenshot([string]$Name) {
    Start-Sleep -Milliseconds 800
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
    $path = Join-Path $ShotDir "$Name.png"
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose(); $bmp.Dispose()
    Write-Host "Captured $path"
}

function Wait-Window([string]$TitleContains, [int]$TimeoutSec = 30, [int]$OwnerPid = 0) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($w in $windows) {
            if ($w.Current.Name -like "*$TitleContains*") {
                if ($OwnerPid -ne 0 -and $w.Current.ProcessId -ne $OwnerPid) { continue }
                return $w
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Window containing '$TitleContains' (pid $OwnerPid) not found within ${TimeoutSec}s"
}

function Find-ByText($Root, [string]$Text, $ControlType) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ControlType)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach ($el in $all) {
        if ($el.Current.Name -like "*$Text*") { return $el }
    }

    # Controls with panel content expose no name; find inner text and walk up.
    $textCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    $texts = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    foreach ($t in $texts) {
        if ($t.Current.Name -like "*$Text*") {
            $parent = $walker.GetParent($t)
            while ($parent -ne $null) {
                if ($parent.Current.ControlType -eq $ControlType) { return $parent }
                $parent = $walker.GetParent($parent)
            }
        }
    }
    return $null
}

function Invoke-ByText($Root, [string]$Text) {
    $el = Find-ByText $Root $Text ([System.Windows.Automation.ControlType]::Button)
    if (-not $el) { throw "Button '$Text' not found" }
    ($el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
    Start-Sleep -Milliseconds 600
}

function Toggle-ByText($Root, [string]$Text) {
    # WPF ToggleButtons (language chips) expose TogglePattern.
    $el = Find-ByText $Root $Text ([System.Windows.Automation.ControlType]::Button)
    if (-not $el) { Write-Host "Chip '$Text' not found (skipped)"; return }
    try {
        ($el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)).Toggle()
    }
    catch {
        try { ($el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke() } catch { }
    }
    Start-Sleep -Milliseconds 400
}

function Select-RadioByText($Root, [string]$Text) {
    $el = Find-ByText $Root $Text ([System.Windows.Automation.ControlType]::RadioButton)
    if (-not $el) { throw "Radio '$Text' not found" }
    ($el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)).Select()
    Start-Sleep -Milliseconds 600
}

function Dump-UiaTree($Root, [string]$Path) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $sb = New-Object System.Text.StringBuilder
    function Walk($el, $depth) {
        if ($null -eq $el -or $depth -gt 12) { return }
        $indent = "  " * $depth
        [void]$sb.AppendLine("$indent$($el.Current.ControlType.ProgrammaticName) '$($el.Current.Name)'")
        $child = $walker.GetFirstChild($el)
        while ($null -ne $child) {
            Walk $child ($depth + 1)
            $child = $walker.GetNextSibling($child)
        }
    }
    Walk $Root 0
    $sb.ToString() | Set-Content -Path $Path
    Write-Host "UIA tree dumped to $Path"
}

function Collect-AppState {
    $appData = Join-Path $env:APPDATA "AIDictation"
    Write-Host "App data dir contents:"
    Get-ChildItem $appData -ErrorAction SilentlyContinue | ForEach-Object { Write-Host " - $($_.Name) ($($_.Length) bytes)" }

    $errorLog = Join-Path $appData "error.log"
    if (Test-Path $errorLog) {
        Write-Host "::warning::error.log exists:"
        Get-Content $errorLog | Select-Object -First 60 | Write-Host
        Copy-Item $errorLog (Join-Path $ShotDir "error.log")
    }

    Get-ChildItem $appData -Filter "*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $ShotDir $_.Name)
    }
}

# --- 1. First launch: onboarding (7 steps + finale) ---
Capture-OverlayVideo $ExePath

Write-Host "Launching $ExePath"
$proc = Start-Process -FilePath $ExePath -PassThru
Start-Sleep -Seconds 8

if ($proc.HasExited) { throw "App exited immediately with code $($proc.ExitCode)" }

$onboarding = Wait-Window "Setup" 30
Take-Screenshot "01-onboarding-permissions"

# Grant the Windows microphone consent prompt when it appears (best effort)
try {
    $desktop = [System.Windows.Automation.AutomationElement]::RootElement
    $allow = Find-ByText $desktop "Allow" ([System.Windows.Automation.ControlType]::Button)
    if ($allow -and $allow.Current.Name -notlike "*Don*") {
        ($allow.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)).Invoke()
        Write-Host "Granted microphone permission prompt"
        Start-Sleep -Seconds 1
    }
} catch {
    Write-Host "No microphone prompt to dismiss: $_"
}
Stop-Process -Name "SystemSettings" -Force -ErrorAction SilentlyContinue

try {
    Invoke-ByText $onboarding "Next"
    Toggle-ByText $onboarding "English"
    Toggle-ByText $onboarding "Spanish"
    Take-Screenshot "02-onboarding-languages"

    Invoke-ByText $onboarding "Next"   # mode (Cloud preselected; avoid model download on CI)
    Take-Screenshot "03-onboarding-mode"

    Invoke-ByText $onboarding "Next"   # color
    Take-Screenshot "04-onboarding-color"

    Invoke-ByText $onboarding "Next"   # hotkey
    Take-Screenshot "05-onboarding-hotkey"

    Invoke-ByText $onboarding "Next"   # first recording
    Take-Screenshot "06-onboarding-test"

    Invoke-ByText $onboarding "Next"   # account
    Take-Screenshot "07-onboarding-account"

    Invoke-ByText $onboarding "Finish" # finale animation
    Start-Sleep -Seconds 1.8
    Take-Screenshot "08-onboarding-finale"

    Invoke-ByText $onboarding "Let's Go!"
    Start-Sleep -Seconds 3
    Take-Screenshot "09-after-onboarding-overlay"
}
catch {
    Dump-UiaTree $onboarding (Join-Path $ShotDir "onboarding-uia-tree.txt")
    throw
}

# --- 2. Second launch activates the running instance and opens Settings ---
try {
    Write-Host "Launching second instance to open Settings via single-instance pipe"
    Start-Process -FilePath $ExePath
    Start-Sleep -Seconds 6

    $settings = Wait-Window "Settings" 30 $proc.Id
    Take-Screenshot "10-settings-account"
    Dump-UiaTree $settings (Join-Path $ShotDir "settings-uia-tree.txt")

    Select-RadioByText $settings "Audio"
    Take-Screenshot "11-settings-audio"

    Select-RadioByText $settings "Language"
    Take-Screenshot "12-settings-language"

    Select-RadioByText $settings "Dictionary"
    Take-Screenshot "13-settings-dictionary"

    Select-RadioByText $settings "Shortcuts"
    Take-Screenshot "14-settings-shortcuts"

    Select-RadioByText $settings "Configuration"
    Take-Screenshot "15-settings-configuration"

    Select-RadioByText $settings "History"
    Take-Screenshot "16-settings-history"
}
finally {
    # --- 3. Always collect app state files and crash log ---
    Collect-AppState
}

if ($proc.HasExited) { throw "App is no longer running (exit code $($proc.ExitCode))" }
Write-Host "App still running (pid $($proc.Id)) - validation flow completed"

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
