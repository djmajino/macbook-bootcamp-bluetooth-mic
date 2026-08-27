[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $CertificateThumbprint,

    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [string] $TimestampUrl
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tools = & (Join-Path $PSScriptRoot 'Get-BuildTools.ps1')
$thumbprint = $CertificateThumbprint.ToUpperInvariant()
$certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -ErrorAction Stop
if (-not $certificate.HasPrivateKey) {
    throw 'The selected certificate does not have an accessible private key.'
}
$ekuOids = @($certificate.EnhancedKeyUsageList | ForEach-Object { [string]$_.ObjectId })
if ($ekuOids -notcontains '1.3.6.1.5.5.7.3.3') {
    throw 'The selected certificate is not valid for code signing.'
}

$unsignedRoot = Join-Path $repoRoot "artifacts\$Configuration\unsigned"
$signedRoot = Join-Path $repoRoot "artifacts\$Configuration\signed"
if (-not (Test-Path -LiteralPath $unsignedRoot -PathType Container)) {
    throw "Unsigned packages are missing. Run scripts\Build-Drivers.ps1 first."
}

$artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts')).TrimEnd('\') + '\'
$fullSignedRoot = [IO.Path]::GetFullPath($signedRoot)
if (-not $fullSignedRoot.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to reset a path outside artifacts.'
}
if (Test-Path -LiteralPath $fullSignedRoot) {
    Remove-Item -LiteralPath $fullSignedRoot -Recurse -Force
}
Copy-Item -LiteralPath $unsignedRoot -Destination $signedRoot -Recurse -Force

$signArguments = @('sign', '/fd', 'SHA256', '/sha1', $thumbprint, '/s', 'My')
if ($TimestampUrl) {
    $signArguments += @('/tr', $TimestampUrl, '/td', 'SHA256')
}

foreach ($packageName in @('uart', 'hfp')) {
    $package = Join-Path $signedRoot $packageName
    $sys = Get-ChildItem -LiteralPath $package -Filter '*.sys' -File | Select-Object -First 1
    if (-not $sys) { throw "No SYS file found in $package." }

    & $tools.SignTool @signArguments $sys.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing $($sys.Name) failed." }

    Get-ChildItem -LiteralPath $package -Filter '*.cat' -File | Remove-Item -Force
    & $tools.Inf2Cat "/driver:$package" /os:10_X64 /uselocaltime
    if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed for $package." }

    $catalog = Get-ChildItem -LiteralPath $package -Filter '*.cat' -File | Select-Object -First 1
    & $tools.SignTool @signArguments $catalog.FullName
    if ($LASTEXITCODE -ne 0) { throw "Signing $($catalog.Name) failed." }

    Export-Certificate -Cert $certificate -FilePath (Join-Path $package "$($sys.BaseName).cer") -Force | Out-Null
    foreach ($signedFile in @($sys.FullName, $catalog.FullName)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $signedFile
        if (-not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne $thumbprint) {
            throw "Signature identity verification failed for $signedFile."
        }
    }
}

Write-Host "Signed packages: $signedRoot"
[pscustomobject]@{
    Configuration = $Configuration
    Root = $signedRoot
    CertificateThumbprint = $thumbprint
}
