; Windows installer, built in CI: iscc /DAppVersion=<version> tool\aniview.iss
[Setup]
AppName=AniView
AppVersion={#AppVersion}
AppPublisher=kidfury
DefaultDirName={autopf}\AniView
DefaultGroupName=AniView
; Installs for the current user, so it needs no admin prompt.
PrivilegesRequired=lowest
OutputDir=..\build
OutputBaseFilename=AniView-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayIcon={app}\aniview.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\AniView"; Filename: "{app}\aniview.exe"
Name: "{autodesktop}\AniView"; Filename: "{app}\aniview.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

[Registry]
Root: HKCU; Subkey: "Software\Classes\aniview"; ValueType: string; ValueName: ""; ValueData: "URL:AniView sign-in"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\aniview"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\aniview\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\aniview.exe"" ""%1"""

[Run]
Filename: "{app}\aniview.exe"; Description: "Start AniView"; Flags: nowait postinstall skipifsilent
