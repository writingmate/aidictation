param(
    [Parameter(Mandatory = $true)]
    [string]$AppPath,
    [string]$ArtifactsDir = "smoke-artifacts",
    [int]$WindowTimeoutSeconds = 25,
    [string]$ExpectedFirstWindowTitle = "WhisperMate Setup"
)

$ErrorActionPreference = "Stop"

New-Item -ItemType Directory -Force -Path $ArtifactsDir | Out-Null

$resultPath = Join-Path $ArtifactsDir "result.json"
$screenshotPath = Join-Path $ArtifactsDir "desktop.png"
$appDataDir = Join-Path $env:APPDATA "AIDictation"

if (Test-Path $appDataDir) {
    Remove-Item -Recurse -Force $appDataDir
}

$process = $null
$windowTitle = ""
$foundWindow = $false

try {
    $process = Start-Process -FilePath $AppPath -PassThru

    $deadline = (Get-Date).AddSeconds($WindowTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        $process.Refresh()

        if ($process.HasExited) {
            break
        }

        if (-not [string]::IsNullOrWhiteSpace($process.MainWindowTitle)) {
            $windowTitle = $process.MainWindowTitle
            $foundWindow = $true
            break
        }
    }

    try {
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms

        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($screenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
    } catch {
        $_ | Out-String | Set-Content -Path (Join-Path $ArtifactsDir "screenshot-error.txt")
    }

    $result = [ordered]@{
        appPath = $AppPath
        expectedFirstWindowTitle = $ExpectedFirstWindowTitle
        processId = if ($process) { $process.Id } else { $null }
        hasExited = if ($process) { $process.HasExited } else { $true }
        exitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { $null }
        observedMainWindowTitle = $windowTitle
        foundWindow = $foundWindow
        appDataExists = Test-Path $appDataDir
        settingsExists = Test-Path (Join-Path $appDataDir "settings.json")
        timestampUtc = (Get-Date).ToUniversalTime().ToString("o")
    }

    $result | ConvertTo-Json -Depth 4 | Set-Content -Path $resultPath

    if (-not $process) {
        throw "Failed to start process."
    }

    if ($process.HasExited) {
        throw "App exited before a window was observed."
    }

    if (-not $foundWindow) {
        throw "App stayed alive but no main window title was observed within $WindowTimeoutSeconds seconds."
    }

    if ($windowTitle -ne $ExpectedFirstWindowTitle) {
        throw "Expected first window '$ExpectedFirstWindowTitle' but observed '$windowTitle'."
    }
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
