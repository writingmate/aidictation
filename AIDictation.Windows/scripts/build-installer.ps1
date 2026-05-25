param(
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$Version = "",
    [string]$ProjectPath = "",
    [string]$PublishDir = "",
    [string]$InstallerDir = ""
)

$ErrorActionPreference = "Stop"

$WindowsDir = Split-Path -Parent $PSScriptRoot
if (-not $ProjectPath) {
    $ProjectPath = Join-Path $WindowsDir "AIDictation/AIDictation.csproj"
}
if (-not $PublishDir) {
    $PublishDir = Join-Path $WindowsDir "artifacts/$Runtime"
}
if (-not $InstallerDir) {
    $InstallerDir = Join-Path $WindowsDir "artifacts/installer"
}
if (-not $Version) {
    [xml]$project = Get-Content $ProjectPath
    $Version = $project.Project.PropertyGroup.Version
    if (-not $Version) {
        $Version = "0.0.1"
    }
}

dotnet publish $ProjectPath `
    --configuration $Configuration `
    --runtime $Runtime `
    --self-contained true `
    --output $PublishDir `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true

$iscc = Get-Command iscc.exe -ErrorAction SilentlyContinue
$isccPath = if ($iscc) { $iscc.Source } else { "" }
if (-not $iscc) {
    $candidate = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    if (Test-Path $candidate) {
        $isccPath = $candidate
    }
}
if (-not $isccPath) {
    throw "Inno Setup Compiler (ISCC.exe) was not found. Install Inno Setup 6 first."
}

New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null
$env:AIDICTATION_VERSION = $Version
$env:AIDICTATION_PUBLISH_DIR = $PublishDir
$env:AIDICTATION_INSTALLER_DIR = $InstallerDir

& $isccPath (Join-Path $WindowsDir "installer/AIDictation.iss")

$installer = Join-Path $InstallerDir "AIDictation-Windows-Setup-v$Version.exe"
if (-not (Test-Path $installer)) {
    throw "Installer was not produced: $installer"
}

Write-Host "Installer artifact: $installer"
