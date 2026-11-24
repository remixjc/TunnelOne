param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [switch]$SkipInstaller
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$releaseTag = $env:GITHUB_REF_NAME
if ($env:GITHUB_REF_TYPE -eq 'tag' -and $releaseTag -ne "v$version") { throw 'Release tag differs from VERSION.' }
$msi = & (Join-Path $PSScriptRoot 'prepare-windows.ps1') -Architecture $Architecture
$publish = Join-Path $root "build/windows-$Architecture/publish"
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $publish, $dist | Out-Null
# Single-file, self-contained distribution; users do not need to install .NET.
dotnet publish (Join-Path $root 'Windows/TunnelOne.Windows') -c Release -r "win-$Architecture" --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o $publish
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
$dependencyDir = Join-Path $publish 'Dependencies'
New-Item -ItemType Directory -Force $dependencyDir | Out-Null
Copy-Item -LiteralPath $msi -Destination (Join-Path $dependencyDir 'wireguard.msi')
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination $publish
Copy-Item -LiteralPath (Join-Path $root 'ThirdParty/WireGuard-Windows-LICENSE') -Destination $dependencyDir
Copy-Item -LiteralPath (Join-Path $root 'ThirdParty/DotNet-LICENSE') -Destination $dependencyDir
Copy-Item -LiteralPath (Join-Path $root 'ThirdParty/DotNet-ThirdPartyNotices.txt') -Destination $dependencyDir
Copy-Item -LiteralPath (Join-Path $root 'docs/windows.md') -Destination (Join-Path $publish 'README-Windows.md')
# Only the macOS distribution embeds Mihomo. Windows uses the official WireGuard backend.
$signed = $false
if ($env:WINDOWS_CSC_LINK) {
    if (-not $env:WINDOWS_CSC_KEY_PASSWORD) { throw 'WINDOWS_CSC_KEY_PASSWORD is required with WINDOWS_CSC_LINK.' }
    $pfx = Join-Path $root ('.cache/windows/signing-' + [guid]::NewGuid().ToString('N') + '.pfx')
    try {
        [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CSC_LINK))
        $password = ConvertTo-SecureString $env:WINDOWS_CSC_KEY_PASSWORD -AsPlainText -Force
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $signature = Set-AuthenticodeSignature -LiteralPath (Join-Path $publish 'TunnelOne.exe') -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
        if ($signature.Status -ne 'Valid') { throw 'Windows Authenticode signing failed.' }
        $signed = $true
    } finally {
        if ($certificate) { $certificate.Dispose() }
        if (Test-Path -LiteralPath $pfx) { Remove-Item -LiteralPath $pfx -Force }
    }
}
$stem = "TunnelOne-$version-windows-$Architecture"
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath (Join-Path $dist "$stem-portable.zip") -Force
if (-not $SkipInstaller) {
    $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'
    if (-not (Test-Path -LiteralPath $iscc)) { throw 'Install Inno Setup 6, or use -SkipInstaller for a portable build.' }
    & $iscc "/DAppVersion=$version" "/DAppArch=$Architecture" "/DSourceDir=$publish" "/DOutputDir=$dist" (Join-Path $root 'Windows/installer.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Windows installer build failed.' }
    if ($signed) {
        # Reopen the key only for the final installer signature.
        $keyBytes = [Convert]::FromBase64String($env:WINDOWS_CSC_LINK)
        try {
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($keyBytes, $env:WINDOWS_CSC_KEY_PASSWORD, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
            $signature = Set-AuthenticodeSignature -LiteralPath (Join-Path $dist "$stem-setup.exe") -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
            if ($signature.Status -ne 'Valid') { throw 'Windows installer signing failed.' }
        } finally { if ($certificate) { $certificate.Dispose() }; [Array]::Clear($keyBytes, 0, $keyBytes.Length) }
    }
}
$assets = Get-ChildItem -LiteralPath $dist -File | Where-Object Name -Like "$stem-*" | Where-Object Extension -In '.exe', '.zip'
$checksums = $assets | Sort-Object Name | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $_.Name }
[IO.File]::WriteAllLines((Join-Path $dist "SHA256SUMS-Windows-$Architecture.txt"), [string[]]$checksums, [Text.UTF8Encoding]::new($false))
Write-Output "Windows $Architecture build complete. TunnelOne Authenticode signed: $signed"
