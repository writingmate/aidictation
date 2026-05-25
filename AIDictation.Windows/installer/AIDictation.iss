#define MyAppName "AIDictation"
#define MyAppPublisher "WritingMate"
#define MyAppExeName "AIDictation.exe"
#define MyAppVersion GetEnv("AIDICTATION_VERSION")
#if MyAppVersion == ""
  #define MyAppVersion "0.0.1"
#endif
#define PublishDir GetEnv("AIDICTATION_PUBLISH_DIR")
#if PublishDir == ""
  #define PublishDir "..\artifacts\win-x64"
#endif
#define OutputDir GetEnv("AIDICTATION_INSTALLER_DIR")
#if OutputDir == ""
  #define OutputDir "..\artifacts\installer"
#endif

[Setup]
AppId={{8FCE81BC-30C8-41B5-BF1E-A1B47D3D5747}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=AIDictation-Windows-Setup-v{#MyAppVersion}
SetupIconFile=..\Assets\app.ico
WizardImageFile=..\Assets\Installer\wizard-image.bmp
WizardSmallImageFile=..\Assets\Installer\wizard-small-image.bmp
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription=AI-powered voice dictation for Windows
VersionInfoProductName={#MyAppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
