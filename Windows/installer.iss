#ifndef AppVersion
  #error AppVersion must be supplied by build-windows.ps1
#endif
#if AppArch == "arm64"
  #define ArchExpression "arm64"
#else
  #define ArchExpression "x64compatible and not arm64"
#endif
[Setup]
AppId={{49C5ED81-526D-4B5A-9DB9-CC6BFE5CD4AA}
AppName=TunnelOne
AppVersion={#AppVersion}
AppPublisher=TunnelOne
AppPublisherURL=https://github.com/remixjc/TunnelOne
DefaultDirName={autopf}\TunnelOne
DefaultGroupName=TunnelOne
OutputDir={#OutputDir}
OutputBaseFilename=TunnelOne-{#AppVersion}-windows-{#AppArch}-setup
ArchitecturesAllowed={#ArchExpression}
ArchitecturesInstallIn64BitMode={#ArchExpression}
MinVersion=10.0.19041
PrivilegesRequired=admin
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\TunnelOne.exe
LicenseFile=..\LICENSE
[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
[Files]
Source: "{#SourceDir}\TunnelOne.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README-Windows.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\Dependencies\WireGuard-Windows-LICENSE"; DestDir: "{app}\Dependencies"; Flags: ignoreversion
Source: "{#SourceDir}\Dependencies\DotNet-*"; DestDir: "{app}\Dependencies"; Flags: ignoreversion
Source: "{#SourceDir}\Dependencies\wireguard.msi"; Flags: dontcopy
[Icons]
Name: "{group}\TunnelOne"; Filename: "{app}\TunnelOne.exe"
Name: "{autodesktop}\TunnelOne"; Filename: "{app}\TunnelOne.exe"; Tasks: desktopicon
[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked
[Run]
Filename: "{app}\TunnelOne.exe"; Description: "Open TunnelOne"; Flags: postinstall nowait skipifsilent
[UninstallRun]
Filename: "{app}\TunnelOne.exe"; Parameters: "--cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "CleanupOwnedTunnels"
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
begin
  Result := '';
  if not FileExists(ExpandConstant('{pf64}\WireGuard\wireguard.exe')) then
  begin
    ExtractTemporaryFile('wireguard.msi');
    if not Exec(ExpandConstant('{sys}\msiexec.exe'), '/i "' + ExpandConstant('{tmp}\wireguard.msi') + '" /qn /norestart DO_NOT_LAUNCH=1', '', SW_HIDE, ewWaitUntilTerminated, ExitCode) then
      Result := 'Unable to launch the official WireGuard installer.'
    else if (ExitCode <> 0) and (ExitCode <> 3010) then
      Result := 'WireGuard installation failed (code ' + IntToStr(ExitCode) + ').'
    else
      NeedsRestart := ExitCode = 3010;
  end;
end;
