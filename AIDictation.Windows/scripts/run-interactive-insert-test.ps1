<#
.SYNOPSIS
    Runs the insert test in an interactive desktop session on a GitHub Windows runner.
    
.DESCRIPTION
    GitHub Actions runs in session 0 (service session) which has no real desktop.
    This script launches the actual test in the console session (session 1) where
    the auto-logged-in user has a real desktop with input queue.
    
    Uses a Scheduled Task to run the test as the logged-on user in the interactive session.
#>
param(
    [Parameter(Mandatory = $true)][string]$OutDir,
    [Parameter(Mandatory = $true)][string]$ScriptPath
)

$ErrorActionPreference = "Stop"

Write-Host "=== Interactive Insert Test Launcher ==="
Write-Host ""

# Check current session
Write-Host "[1] Checking sessions..."
$sessions = query session 2>&1
Write-Host $sessions
Write-Host ""

# Get the console user
$consoleUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName
Write-Host "Console user: $consoleUser"

# Create output directory
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Create a wrapper script that will run in the interactive session
$wrapperScript = @"
`$ErrorActionPreference = "Stop"
Set-Location "$PWD"

# Run the actual test
try {
    & "$ScriptPath" -OutDir "$OutDir"
    `$exitCode = `$LASTEXITCODE
    if (`$null -eq `$exitCode) { `$exitCode = 0 }
} catch {
    `$_ | Out-File "$OutDir\error.txt"
    `$exitCode = 1
}

# Write exit code for the launcher to read
`$exitCode | Out-File "$OutDir\exitcode.txt"
"@

$wrapperPath = Join-Path $OutDir "interactive-wrapper.ps1"
$wrapperScript | Out-File -FilePath $wrapperPath -Encoding UTF8

Write-Host ""
Write-Host "[2] Creating scheduled task to run in interactive session..."

$taskName = "AIDictation_InsertTest_$(Get-Random)"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$wrapperPath`""

# Run in interactive session with highest privileges
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Or try running as the current user interactively
# First, try to detect if we're on a GitHub runner
$runnerUser = $env:USERNAME
if ($runnerUser) {
    Write-Host "Runner user: $runnerUser"
    # Use the runner user with interactive logon
    $principal = New-ScheduledTaskPrincipal -UserId $runnerUser -LogonType Interactive -RunLevel Highest
}

$settings = New-ScheduledTaskSettings -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Task registered: $taskName"
} catch {
    Write-Host "Failed to register task with Interactive logon, trying ServiceAccount..."
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Task registered with SYSTEM account: $taskName"
}

Write-Host ""
Write-Host "[3] Starting scheduled task..."
Start-ScheduledTask -TaskName $taskName

Write-Host "[4] Waiting for task to complete..."
$maxWait = 60
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 2
    $waited += 2
    
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task.State -eq "Ready") {
        Write-Host "Task completed after $waited seconds"
        break
    }
    Write-Host "  Waiting... ($waited s)"
}

# Cleanup task
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[5] Reading results..."

$exitCodeFile = Join-Path $OutDir "exitcode.txt"
$errorFile = Join-Path $OutDir "error.txt"

if (Test-Path $exitCodeFile) {
    $exitCode = [int](Get-Content $exitCodeFile -Raw).Trim()
    Write-Host "Test exit code: $exitCode"
} else {
    Write-Host "WARNING: No exit code file found"
    $exitCode = 1
}

if (Test-Path $errorFile) {
    Write-Host "Error output:"
    Get-Content $errorFile
}

# Show all artifacts
Write-Host ""
Write-Host "=== Artifacts ==="
Get-ChildItem $OutDir -Recurse | ForEach-Object { Write-Host $_.FullName }

exit $exitCode
