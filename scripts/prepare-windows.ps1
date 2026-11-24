param(
    [ValidateSet('x64', 'arm64')][string]$Architecture = 'x64',
    [switch]$Install
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$lock = Get-Content (Join-Path $PSScriptRoot 'windows-dependencies.lock.json') -Raw | ConvertFrom-Json
$dependency = $lock.wireguard.$Architecture
$cache = Join-Path $root '.cache/windows'
New-Item -ItemType Directory -Force $cache | Out-Null
$msi = Join-Path $cache ([IO.Path]::GetFileName(([uri]$dependency.url).AbsolutePath))
if (-not (Test-Path -LiteralPath $msi)) { Invoke-WebRequest $dependency.url -OutFile $msi }
if ((Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash -ne $dependency.sha256) {
    throw "WireGuard MSI checksum mismatch: $msi"
}
$signature = Get-AuthenticodeSignature -LiteralPath $msi
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|, )O=WireGuard LLC(,|$)') {
    throw 'WireGuard MSI must have a valid WireGuard LLC Authenticode signature.'
}
if ($Install) {
    $process = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi + '"'), '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -notin 0, 3010) { throw "WireGuard installation failed: $($process.ExitCode)" }
}
Write-Output $msi
