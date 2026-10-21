<#
.SYNOPSIS
    Install the Broom MSIX package on Windows.

.DESCRIPTION
    Run this from an elevated PowerShell window (the MSIX deployment service validates the
    signature as SYSTEM, so both steps below need administrator rights):

        1. Trust the signing certificate in the machine stores (Root + TrustedPeople).
           Skip this only if the package is signed by a certificate the machine already trusts.
        2. Register the package for the current user.

    Pass -AppInstaller to install through the App Installer feed. That is the recommended
    route: Windows records the feed URI and keeps the app updated from it automatically.
    Passing -Package instead installs a single .msix and gets no automatic updates.

    Uninstall:
        Get-AppxPackage -Name Broom | Remove-AppxPackage
        Get-ChildItem Cert:\LocalMachine\Root | Where-Object Subject -eq 'CN=Broom' | Remove-Item

.EXAMPLE
    .\tool\install_msix.ps1 -AppInstaller .\dist\broom.appinstaller -Certificate .\dist\Broom.cer

.EXAMPLE
    .\tool\install_msix.ps1 -Package .\dist\broom_0.4.0.4_x64.msix -Certificate .\dist\Broom.cer
#>
[CmdletBinding()]
param(
    [string]$Package,

    [string]$AppInstaller,

    [string]$Certificate,

    [string]$CertificatePassword = 'password',

    [switch]$SkipCertificate
)

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run in an elevated PowerShell window (Run as administrator).'
}

if (-not $Package -and -not $AppInstaller) {
    throw 'Pass -AppInstaller <broom.appinstaller> (recommended) or -Package <broom.msix>.'
}
if ($Package -and $AppInstaller) {
    throw 'Pass either -AppInstaller or -Package, not both.'
}

$sourcePath = if ($AppInstaller) { (Resolve-Path $AppInstaller).Path } else { (Resolve-Path $Package).Path }
if (-not (Test-Path $sourcePath)) { throw "Installer source not found: $sourcePath" }

if (-not $SkipCertificate) {
    if (-not $Certificate) { throw 'Pass -Certificate <pfx|cer> or -SkipCertificate.' }
    $certPath = (Resolve-Path $Certificate).Path
    foreach ($store in @('Root', 'TrustedPeople')) {
        Write-Host "-> trusting certificate in LocalMachine\$store" -ForegroundColor Cyan
        if ($certPath -like '*.pfx') {
            & certutil.exe -f -p $CertificatePassword -importpfx $store $certPath | Out-Null
        }
        else {
            & certutil.exe -f -addstore $store $certPath | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw "certutil import into $store failed (exit $LASTEXITCODE)" }
    }
}

if ($AppInstaller) {
    Write-Host "-> installing from App Installer feed: $sourcePath" -ForegroundColor Cyan
    Write-Host '   Windows will keep the app updated from the feed URI recorded in this file.'
    Add-AppxPackage -Appinstaller $sourcePath
}
else {
    Write-Host "-> installing package: $sourcePath" -ForegroundColor Cyan
    Write-Host '   No App Installer feed is registered, so this install will not auto-update.' -ForegroundColor Yellow
    Add-AppxPackage -Path $sourcePath
}

Get-AppxPackage -Name Broom |
    Select-Object Name, Version, PackageFullName, InstallLocation, Status |
    Format-List
Write-Host 'Done. Launch "Broom" from the Start menu.' -ForegroundColor Green
