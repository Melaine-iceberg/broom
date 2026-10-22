<#
.SYNOPSIS
    Package Broom for Windows: signed MSIX, optional App Installer update feed, portable ZIP.

.DESCRIPTION
    Reproducible packaging pipeline built on the Windows App CLI (winapp).

        1. flutter build windows --release
        2. prune font families the app never references (tool/prune_unused_fonts.dart)
        3. stage the Release output together with the MSIX manifest and tile assets
        4. derive the MSIX version from pubspec.yaml (x.y.z+build -> x.y.z.build)
        5. sign with signing\broom-release.pfx, creating that certificate only once
        6. optional broom.appinstaller feed for OS-managed automatic updates
        7. optional portable ZIP for users who cannot trust a certificate
        8. export the public .cer and write SHA-256 checksums

    The MSIX identity (Name / Publisher) is defined in windows/packaging/Package.appxmanifest.
    Changes to either value produce a different package identity: existing installs will not
    upgrade in place. The signing certificate has the same constraint: replacing it breaks the
    update chain for everyone who already trusted the old one.

.EXAMPLE
    pwsh -File tool/package_windows.ps1

.EXAMPLE
    pwsh -File tool/package_windows.ps1 -UpdateFeedUrl https://example.com/broom/broom.appinstaller

.EXAMPLE
    pwsh -File tool/package_windows.ps1 -SkipBuild -CertificatePath .\signing\prod.pfx -CertificatePassword ***
#>
[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$Publisher = 'CN=Broom',
    [string]$CertificatePath,
    [string]$CertificatePassword = 'password',
    [string]$Version,
    [string]$UpdateFeedUrl,
    [switch]$SkipBuild,
    [switch]$SkipPortable,
    [switch]$SkipMsix
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$packagingDir = Join-Path $root 'windows\packaging'
$manifestSource = Join-Path $packagingDir 'Package.appxmanifest'
$releaseDir = Join-Path $root "build\windows\x64\runner\$Configuration"
$stageDir = Join-Path $root 'build\windows\msix\stage'
$distDir = Join-Path $root 'dist'
$signingDir = Join-Path $root 'signing'
$releaseCert = Join-Path $signingDir 'broom-release.pfx'

function Get-MsixVersion {
    $pubspec = Get-Content -Path (Join-Path $root 'pubspec.yaml') -Raw
    $pattern = '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?\s*$'
    if ($pubspec -notmatch $pattern) {
        throw 'Unable to read "version:" from pubspec.yaml.'
    }
    $revision = if ($Matches[4]) { $Matches[4] } else { '0' }
    return "$($Matches[1]).$($Matches[2]).$($Matches[3]).$revision"
}

if (-not (Test-Path $manifestSource)) {
    throw "Manifest not found: $manifestSource"
}
if (-not (Test-Path (Join-Path $packagingDir 'Assets'))) {
    throw "Tile assets not found: $packagingDir\Assets (run: winapp manifest update-assets <icon> --manifest $manifestSource)"
}

$version = if ($Version) { $Version } else { Get-MsixVersion }
Write-Host "Broom packaging: version $version" -ForegroundColor Cyan

if (-not $SkipBuild) {
    Write-Host '-> flutter build windows --release' -ForegroundColor Cyan
    Push-Location $root
    try {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build failed (exit $LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path (Join-Path $releaseDir 'broom.exe'))) {
    throw "Release output not found: $releaseDir\broom.exe"
}

# --- Prune font families the app never uses -------------------------------------
# lucide_icons_flutter declares six variable-font weight variants that this app
# never imports; the engine still registers every FontManifest family at startup,
# so they cost ~2.9 MB of asset reads on each cold start. The tool refuses to drop
# a family that still appears under lib/. Runs before staging and the portable ZIP
# so both artifacts ship the pruned bundle.
Write-Host '-> pruning unused font families' -ForegroundColor Cyan
$fontBundle = Join-Path $releaseDir 'data\flutter_assets'
$dartExe = (Get-Command dart -ErrorAction SilentlyContinue).Source
if (-not $dartExe) {
    $flutterExe = (Get-Command flutter -ErrorAction SilentlyContinue).Source
    if ($flutterExe) {
        $dartExe = Join-Path (Split-Path -Parent (Split-Path -Parent $flutterExe)) 'bin\cache\dart-sdk\bin\dart.exe'
    }
}
if (-not $dartExe) {
    throw 'Neither dart nor flutter is on PATH; cannot prune unused font families.'
}
& $dartExe (Join-Path $root 'tool\prune_unused_fonts.dart') --bundle $fontBundle
if ($LASTEXITCODE -ne 0) { throw "font pruning failed (exit $LASTEXITCODE)" }

New-Item -ItemType Directory -Path $distDir -Force | Out-Null

# --- Stage: package layout = release output + manifest + tile assets -------------
Write-Host '-> staging package layout' -ForegroundColor Cyan
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $stageDir -Recurse -Force
Copy-Item -Path (Join-Path $packagingDir 'Assets') -Destination $stageDir -Recurse -Force

$manifest = Get-Content -Path $manifestSource -Raw
$manifest = $manifest -replace '(<Identity\s[^>]*?Version=")[^"]+(")', ('${1}' + $version + '${2}')
$stagedManifest = Join-Path $stageDir 'Package.appxmanifest'
Set-Content -Path $stagedManifest -Value $manifest -Encoding UTF8

$stagedVersion = [regex]::Match($manifest, '<Identity\s[^>]*?Version="([^"]+)"').Groups[1].Value
Write-Host "   staged identity version: $stagedVersion"

# --- Portable ZIP ---------------------------------------------------------------
if (-not $SkipPortable) {
    $zipPath = Join-Path $distDir "broom_${version}_win-x64-portable.zip"
    Write-Host "-> portable zip: $zipPath" -ForegroundColor Cyan
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
}

# --- MSIX -----------------------------------------------------------------------
if (-not $SkipMsix) {
    $msixPath = Join-Path $distDir "broom_${stagedVersion}_x64.msix"
    if (Test-Path $msixPath) { Remove-Item $msixPath -Force }

    $packageArgs = @(
        'package', $stageDir,
        '--manifest', $stagedManifest,
        '--output', $msixPath
    )

    # The signing identity must stay stable across releases. A fresh certificate per build
    # would force every user to trust a new certificate and would break App Installer
    # upgrades, so the certificate is created once and reused from signing\.
    $effectiveCert = $CertificatePath
    if (-not $effectiveCert) {
        if (Test-Path $releaseCert) {
            $effectiveCert = $releaseCert
        }
        else {
            Write-Host "-> no release certificate found, creating one: $releaseCert" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $signingDir -Force | Out-Null
            & winapp cert generate --manifest $stagedManifest --publisher $Publisher --output $releaseCert `
                --valid-days 3650 --export-cer --password $CertificatePassword
            if ($LASTEXITCODE -ne 0) { throw "winapp cert generate failed (exit $LASTEXITCODE)" }
            $effectiveCert = $releaseCert
        }
    }

    $resolvedCert = (Resolve-Path $effectiveCert).Path
    Write-Host "-> signing with: $resolvedCert" -ForegroundColor Cyan
    $packageArgs += @('--cert', $resolvedCert, '--cert-password', $CertificatePassword)

    & winapp @packageArgs
    if ($LASTEXITCODE -ne 0) { throw "winapp package failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $msixPath)) { throw "MSIX was not produced: $msixPath" }

    # Users only ever need the public certificate to trust the package; the .pfx with the
    # private key stays in signing\ and must never be distributed.
    $publicCert = Join-Path $distDir 'Broom.cer'
    $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $resolvedCert,
        $CertificatePassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    [IO.File]::WriteAllBytes($publicCert, $pfxCert.Export('Cert'))
    Write-Host "-> public certificate: $publicCert (subject $($pfxCert.Subject), expires $($pfxCert.NotAfter.ToString('yyyy-MM-dd')))" -ForegroundColor Cyan

    # --- App Installer feed ------------------------------------------------------
    # Installing through this file (not the bare .msix) is what enables OS-managed
    # automatic updates: App Installer remembers the feed URI and re-checks it.
    if ($UpdateFeedUrl) {
        if ($UpdateFeedUrl -notmatch '^https://') {
            throw 'UpdateFeedUrl must be an https:// URL.'
        }
        $appInstallerPath = Join-Path $distDir 'broom.appinstaller'
        $feedDir = $UpdateFeedUrl.Substring(0, $UpdateFeedUrl.LastIndexOf('/') + 1)
        $packageUri = $feedDir + (Split-Path -Leaf $msixPath)
        $identity = [xml](Get-Content -Path $stagedManifest)
        $template = @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="$UpdateFeedUrl" Version="$stagedVersion" xmlns="http://schemas.microsoft.com/appx/appinstaller/2021">
  <MainPackage Name="$($identity.Package.Identity.Name)" Version="$stagedVersion" Publisher="$($identity.Package.Identity.Publisher)" ProcessorArchitecture="x64" Uri="$packageUri" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="0" ShowPrompt="false" UpdateBlocksActivation="false" />
    <AutomaticBackgroundTask />
  </UpdateSettings>
</AppInstaller>
"@
        Set-Content -Path $appInstallerPath -Value $template -Encoding UTF8
        Write-Host "-> App Installer feed: $appInstallerPath" -ForegroundColor Cyan
        Write-Host "   package URI: $packageUri"
    }
    else {
        Write-Host '-> no -UpdateFeedUrl supplied, skipped broom.appinstaller (no auto-update feed)' -ForegroundColor Yellow
    }
}

# --- Checksums ------------------------------------------------------------------
$checksumPath = Join-Path $distDir 'SHA256SUMS.txt'
if (Test-Path $checksumPath) { Remove-Item $checksumPath -Force }
$lines = @()
Get-ChildItem -Path $distDir -File |
    Where-Object { $_.Extension -in @('.msix', '.msixbundle', '.zip', '.cer', '.appinstaller') } |
    Sort-Object Name |
    ForEach-Object {
        $hash = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $lines += "$hash  $($_.Name)"
    }
if ($lines.Count -gt 0) {
    Set-Content -Path $checksumPath -Value $lines -Encoding ASCII
    Write-Host "-> checksums: $checksumPath" -ForegroundColor Cyan
}

Write-Host ''
Write-Host 'Artifacts in dist:' -ForegroundColor Green
Get-ChildItem -Path $distDir -File |
    Sort-Object Name |
    Format-Table Name, @{ Name = 'Size (MB)'; Expression = { [math]::Round($_.Length / 1MB, 1) } } -AutoSize
