param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$ShotDir
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

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

function Wait-Window([string]$TitleContains, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $windows = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($w in $windows) {
            if ($w.Current.Name -like "*$TitleContains*") { return $w }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Window containing '$TitleContains' not found within ${TimeoutSec}s"
}

function Find-ByText($Root, [string]$Text, $ControlType) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $ControlType)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
    foreach ($el in $all) {
        if ($el.Current.Name -like "*$Text*") { return $el }
    }
    return $null
}

function Invoke-ByText($Root, [string]$Text) {
    $el = Find-ByText $Root $Text ([System.Windows.Automation.ControlType]::Button)
    if (-not $el) { throw "Button '$Text' not found" }
    $pattern = $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
    Start-Sleep -Milliseconds 600
}

function Select-RadioByText($Root, [string]$Text) {
    $el = Find-ByText $Root $Text ([System.Windows.Automation.ControlType]::RadioButton)
    if (-not $el) { throw "Radio '$Text' not found" }
    $pattern = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $pattern.Select()
    Start-Sleep -Milliseconds 600
}

# --- 1. First launch: onboarding wizard ---
Write-Host "Launching $ExePath"
$proc = Start-Process -FilePath $ExePath -PassThru
Start-Sleep -Seconds 8

if ($proc.HasExited) { throw "App exited immediately with code $($proc.ExitCode)" }

$onboarding = Wait-Window "Setup" 30
Take-Screenshot "01-onboarding-microphone"

Invoke-ByText $onboarding "Next"
# Select an explicit language to demonstrate multi-select, then add a second one
Invoke-ByText $onboarding "English"
Invoke-ByText $onboarding "Spanish"
Take-Screenshot "02-onboarding-languages"

Invoke-ByText $onboarding "Next"
Take-Screenshot "03-onboarding-mode"

Invoke-ByText $onboarding "Next"
Take-Screenshot "04-onboarding-hotkey"

Invoke-ByText $onboarding "Next"
Take-Screenshot "05-onboarding-signin"

Invoke-ByText $onboarding "Next"
Take-Screenshot "06-onboarding-complete"

Invoke-ByText $onboarding "Get Started"
Start-Sleep -Seconds 3
Take-Screenshot "07-after-onboarding-tray-overlay"

# --- 2. Second launch activates the running instance and opens Settings ---
Write-Host "Launching second instance to open Settings via single-instance pipe"
Start-Process -FilePath $ExePath
Start-Sleep -Seconds 6

$settings = Wait-Window "Settings" 30
Take-Screenshot "08-settings-audio"

Select-RadioByText $settings "Text Rules"
Take-Screenshot "09-settings-text-rules"

Select-RadioByText $settings "Hotkeys"
Take-Screenshot "10-settings-hotkeys"

Select-RadioByText $settings "Overlay"
Take-Screenshot "11-settings-overlay"

Select-RadioByText $settings "Account"
Take-Screenshot "12-settings-account"

# --- 3. Sanity: app state files and no crash log ---
$appData = Join-Path $env:APPDATA "AIDictation"
Write-Host "App data dir contents:"
Get-ChildItem $appData -ErrorAction SilentlyContinue | ForEach-Object { Write-Host " - $($_.Name) ($($_.Length) bytes)" }

$errorLog = Join-Path $appData "error.log"
if (Test-Path $errorLog) {
    Write-Host "::warning::error.log exists:"
    Get-Content $errorLog | Select-Object -First 40 | Write-Host
    Copy-Item $errorLog (Join-Path $ShotDir "error.log")
}

$settingsJson = Get-ChildItem $appData -Filter "*.json" -ErrorAction SilentlyContinue
foreach ($f in $settingsJson) {
    Copy-Item $f.FullName (Join-Path $ShotDir $f.Name)
}

if ($proc.HasExited) { throw "App is no longer running (exit code $($proc.ExitCode))" }
Write-Host "App still running (pid $($proc.Id)) - validation flow completed"

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
