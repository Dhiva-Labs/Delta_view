; Inno Setup script for the DeltaView installer.
;
;   ISCC /DArch=x64 packaging\windows\DeltaView.iss
;   ISCC /DArch=arm64 /DAppVersion=0.1.0 packaging\windows\DeltaView.iss
;
; Arch picks the Flutter build to package (build\windows\<Arch>\runner\Release)
; and the architecture the installer accepts. The output is
; dist\DeltaView-<version>-windows-<Arch>-setup.exe.

#ifndef Arch
  #error Pass /DArch=x64 or /DArch=arm64
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif

#define AppName "DeltaView"
#define AppExe "delta_view.exe"
#define SourceDir "..\..\build\windows\" + Arch + "\runner\Release"

[Setup]
AppId={{8819B9F8-896A-46A0-AFA6-9211A5C0273C}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Dhiva Labs
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=DeltaView-{#AppVersion}-windows-{#Arch}-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
