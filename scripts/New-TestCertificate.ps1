[CmdletBinding()]
param(
    [string] $Subject = 'Bluetooth Mic Mac Local Test',
    [ValidateRange(1, 5)]
    [int] $ValidYears = 2
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$outputRoot = Join-Path $repoRoot 'artifacts\signing'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$distinguishedName = if ($Subject -match '^CN=') { $Subject } else { "CN=$Subject" }
$certificate = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $distinguishedName `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA `
    -KeyLength 3072 `
    -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable `
    -NotAfter (Get-Date).AddYears($ValidYears)

$cerPath = Join-Path $outputRoot 'BluetoothMicMac-Test.cer'
Export-Certificate -Cert $certificate -FilePath $cerPath -Force | Out-Null

Write-Host 'Created a non-exportable local test-signing key.'
Write-Host "Public certificate: $cerPath"
Write-Host "Thumbprint: $($certificate.Thumbprint)"

[pscustomobject]@{
    Thumbprint = $certificate.Thumbprint
    CertificatePath = $cerPath
    Subject = $certificate.Subject
    Expires = $certificate.NotAfter
}
