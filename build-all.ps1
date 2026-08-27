[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $CertificateThumbprint,

    [switch] $BuildInstaller,

    [string] $TimestampUrl
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

& (Join-Path $repoRoot 'scripts\Test-PublicTree.ps1')
& (Join-Path $repoRoot 'scripts\Build-Drivers.ps1') -Configuration $Configuration

if ($CertificateThumbprint) {
    $signParameters = @{
        Configuration = $Configuration
        CertificateThumbprint = $CertificateThumbprint
    }
    if ($TimestampUrl) { $signParameters.TimestampUrl = $TimestampUrl }
    & (Join-Path $repoRoot 'scripts\Sign-DriverPackages.ps1') @signParameters
} elseif ($BuildInstaller) {
    throw '-BuildInstaller requires -CertificateThumbprint because the installer embeds signed driver packages.'
}

if ($BuildInstaller) {
    & (Join-Path $repoRoot 'installer\build.ps1') `
        -Configuration $Configuration `
        -CertificateThumbprint $CertificateThumbprint `
        -TimestampUrl $TimestampUrl
}

Write-Host 'Build pipeline completed.'
