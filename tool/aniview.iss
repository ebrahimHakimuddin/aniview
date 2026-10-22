; Windows installer, built in CI: iscc /DAppVersion=<version> [/DBeta] tool\aniview.iss
; The beta (/DBeta) installs beside AniView: its own name, so its own uninstall entry, folder and shortcuts.
#ifdef Beta
  #define Name "AniView Beta"
  #define Output "AniView-Beta-windows-x64-setup"
#else
  #define Name "AniView"
  #define Output "AniView-windows-x64-setup"
#endif
[Setup]
AppName={#Name}
AppVersion={#AppVersion}
AppPublisher=kidfury
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
; Installs for the current user, so it needs no admin prompt.
PrivilegesRequired=lowest
OutputDir=..\build
OutputBaseFilename={#Output}
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\aniview.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#Name}"; Filename: "{app}\aniview.exe"
Name: "{autodesktop}\{#Name}"; Filename: "{app}\aniview.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked

; The app registers aniview:// itself before each sign-in, so a beta beside it takes the link only while signing in.
[Registry]
Root: HKCU; Subkey: "Software\Classes\aniview"; ValueType: string; ValueName: ""; ValueData: "URL:AniView sign-in"
Root: HKCU; Subkey: "Software\Classes\aniview"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\aniview\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\aniview.exe"" ""%1"""

[Run]
; Also after a silent install: that's the in-app update, which closed AniView to run it.
Filename: "{app}\aniview.exe"; Description: "Start {#Name}"; Flags: nowait postinstall
