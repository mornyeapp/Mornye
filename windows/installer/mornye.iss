; Inno Setup 6 script for the per-user Mornye installer.
;
; Built by scripts/package_windows.ps1, which passes:
;   /DAppVersion=5.3.0          display version (release tag without "v")
;   /DNumericVersion=5.3.0.0    file version (digits only)
;   /DBundleDir=<path>          the flutter build windows Release folder
;   /DArch=x64 or arm64
;   /DOutputDir=<path> /DOutputBaseName=<file name without .exe>
;
; Installs to %LOCALAPPDATA%\Programs\Mornye without elevation, adds a Start
; Menu shortcut (desktop shortcut optional), registers the mornye:// URL
; protocol under HKCU\Software\Classes and closes a running Mornye before
; replacing files. The in-app updater runs the installer with
;   /SILENT /SP- /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1
; and /RELAUNCH=1 starts Mornye again once a silent install finishes.

#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef NumericVersion
  #error NumericVersion is required
#endif
#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
#ifndef OutputBaseName
  #define OutputBaseName "Mornye-setup"
#endif

#define AppName "Mornye"
#define AppExe "mornye.exe"
#define AppUserModelId "com.zarz.mornye"
#define AppUrl "https://github.com/mornyeapp/Mornye"

#if Arch == "arm64"
  #define AllowedArchitectures "arm64"
#else
  #define AllowedArchitectures "x64compatible"
#endif

[Setup]
AppId={{0FFEA5B8-69C1-423B-B38E-1E521494A286}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=zarzet
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL=https://github.com/mornyeapp/Mornye-Desktop/releases
VersionInfoVersion={#NumericVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
PrivilegesRequired=lowest
DefaultDirName={userpf}\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
ChangesAssociations=yes
DefaultGroupName={#AppName}
UsePreviousAppDir=yes
ArchitecturesAllowed={#AllowedArchitectures}
ArchitecturesInstallIn64BitMode={#AllowedArchitectures}
MinVersion=10.0.17763
CloseApplications=force
RestartApplications=no
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Remove files of the previous version so stale plugins and assets do not
; linger next to the new ones.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelId}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelId}"; Tasks: desktopicon

[Registry]
; Register an optional player. Never change the user's default or UserChoice.
Root: HKCU; Subkey: "Software\Classes\Mornye.Audio"; ValueType: string; ValueName: ""; ValueData: "Mornye audio"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Mornye.Audio\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKCU; Subkey: "Software\Classes\Mornye.Audio\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
Root: HKCU; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "Mornye"; ValueData: "Software\Mornye\Capabilities"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Mornye\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#AppName}"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Mornye\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Play audio files with Mornye"
#sub RegisterAudioExtension
Root: HKCU; Subkey: "Software\Classes\.{#AudioExt}\OpenWithProgids"; ValueType: string; ValueName: "Mornye.Audio"; ValueData: ""; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Applications\{#AppExe}\SupportedTypes"; ValueType: string; ValueName: ".{#AudioExt}"; ValueData: ""
Root: HKCU; Subkey: "Software\Mornye\Capabilities\FileAssociations"; ValueType: string; ValueName: ".{#AudioExt}"; ValueData: "Mornye.Audio"
#endsub
#define AudioExt "mp3"
#call RegisterAudioExtension
#define AudioExt "flac"
#call RegisterAudioExtension
#define AudioExt "alac"
#call RegisterAudioExtension
#define AudioExt "wav"
#call RegisterAudioExtension
#define AudioExt "aiff"
#call RegisterAudioExtension
#define AudioExt "aif"
#call RegisterAudioExtension
#define AudioExt "opus"
#call RegisterAudioExtension
#define AudioExt "ogg"
#call RegisterAudioExtension
#define AudioExt "aac"
#call RegisterAudioExtension
#define AudioExt "m4a"
#call RegisterAudioExtension
Root: HKCU; Subkey: "Software\Classes\mornye"; ValueType: string; ValueName: ""; ValueData: "URL:{#AppName} Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\mornye"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\mornye\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKCU; Subkey: "Software\Classes\mornye\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\{#AppExe}"; Flags: nowait; Check: ShouldRelaunch

[Code]
function ShouldRelaunch: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;
