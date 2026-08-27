[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]{40}$')]
    [string] $CertificateThumbprint,

    [string] $TimestampUrl
)

$ErrorActionPreference = 'Stop'
$installerVersion = '1.0.0'
$expectedCertificateThumbprint = $CertificateThumbprint.ToUpperInvariant()
$projectRoot = Split-Path -Parent $PSScriptRoot
$tools = & (Join-Path $projectRoot 'scripts\Get-BuildTools.ps1')
$signedRoot = Join-Path $projectRoot "artifacts\$Configuration\signed"
$stageRoot = Join-Path $PSScriptRoot 'build\payload'
$buildRoot = Join-Path $PSScriptRoot 'build'
$distRoot = Join-Path $projectRoot "artifacts\$Configuration\installer"
$payloadZip = Join-Path $buildRoot 'payload.zip'
$iconSource = Join-Path $PSScriptRoot 'assets\btmicmac.png'
$iconPath = Join-Path $buildRoot 'btmicmac.ico'
$outputExe = Join-Path $distRoot 'BluetoothMicMac-HFP-Installer.exe'
$nativeProject = Join-Path $PSScriptRoot 'root_device_installer\root_device_installer.vcxproj'
$nativeExe = Join-Path $PSScriptRoot 'root_device_installer\build\BluetoothMicMacNative.exe'
$msbuild = $tools.MSBuild
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'

$sourceFiles = [ordered]@{
    'drivers\uart\UartH4Probe.cat' = Join-Path $signedRoot 'uart\UartH4Probe.cat'
    'drivers\uart\UartH4Probe.cer' = Join-Path $signedRoot 'uart\UartH4Probe.cer'
    'drivers\uart\UartH4Probe.inf' = Join-Path $signedRoot 'uart\UartH4Probe.inf'
    'drivers\uart\UartH4Probe.sys' = Join-Path $signedRoot 'uart\UartH4Probe.sys'
    'drivers\uart\UartH4Query.exe' = Join-Path $signedRoot 'uart\UartH4Query.exe'
    'drivers\hfp\BthHfpAudio.cat' = Join-Path $signedRoot 'hfp\BthHfpAudio.cat'
    'drivers\hfp\BthHfpAudio.cer' = Join-Path $signedRoot 'hfp\BthHfpAudio.cer'
    'drivers\hfp\BthHfpAudio.inf' = Join-Path $signedRoot 'hfp\BthHfpAudio.inf'
    'drivers\hfp\BthHfpAudio.sys' = Join-Path $signedRoot 'hfp\BthHfpAudio.sys'
    'install.ps1' = Join-Path $PSScriptRoot 'payload\install.ps1'
    'uart-recovery.ps1' = Join-Path $PSScriptRoot 'payload\uart-recovery.ps1'
}

function Reset-Directory {
    param([Parameter(Mandatory)][string] $Path)
    $fullInstallerRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $fullTarget = [IO.Path]::GetFullPath($Path)
    if (-not $fullTarget.StartsWith($fullInstallerRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset a directory outside the installer tree: $fullTarget"
    }
    if (Test-Path -LiteralPath $fullTarget) {
        Remove-Item -LiteralPath $fullTarget -Recurse -Force
    }
    New-Item -ItemType Directory -Path $fullTarget -Force | Out-Null
}

function Write-MultiSizeIcon {
    param(
        [Parameter(Mandatory)][string] $SourcePng,
        [Parameter(Mandatory)][string] $DestinationIco
    )
    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
    $images = New-Object System.Collections.Generic.List[byte[]]
    $sourceImage = [Drawing.Image]::FromFile($SourcePng)
    try {
        foreach ($size in $sizes) {
            $bitmap = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                try {
                    $graphics.Clear([Drawing.Color]::Transparent)
                    $graphics.CompositingMode = [Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
                    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphics.DrawImage($sourceImage, [Drawing.Rectangle]::new(0, 0, $size, $size))
                }
                finally {
                    $graphics.Dispose()
                }
                $stream = [IO.MemoryStream]::new()
                try {
                    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
                    $images.Add($stream.ToArray())
                }
                finally {
                    $stream.Dispose()
                }
            }
            finally {
                $bitmap.Dispose()
            }
        }
    }
    finally {
        $sourceImage.Dispose()
    }

    $fileStream = [IO.File]::Open($DestinationIco, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = [IO.BinaryWriter]::new($fileStream)
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]$sizes.Count)
            $offset = 6 + (16 * $sizes.Count)
            for ($index = 0; $index -lt $sizes.Count; ++$index) {
                $size = $sizes[$index]
                $dimensionByte = if ($size -eq 256) { 0 } else { $size }
                $writer.Write([byte]$dimensionByte)
                $writer.Write([byte]$dimensionByte)
                $writer.Write([byte]0)
                $writer.Write([byte]0)
                $writer.Write([UInt16]1)
                $writer.Write([UInt16]32)
                $writer.Write([UInt32]$images[$index].Length)
                $writer.Write([UInt32]$offset)
                $offset += $images[$index].Length
            }
            foreach ($imageBytes in $images) {
                $writer.Write($imageBytes)
            }
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $fileStream.Dispose()
    }
}

function Get-InfDriverVersion {
    param([Parameter(Mandatory)][string] $Path)
    $line = Get-Content -LiteralPath $Path | Where-Object {
        $_ -match '^\s*DriverVer\s*='
    } | Select-Object -First 1
    if (-not $line -or $line -notmatch ',\s*([0-9]+(?:\.[0-9]+){3})\s*$') {
        throw "Could not read DriverVer from $Path."
    }
    $Matches[1]
}

foreach ($entry in $sourceFiles.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Missing source file: $($entry.Value)"
    }
}
if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) {
    throw "Installer icon source is missing: $iconSource"
}

$uartCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sourceFiles['drivers\uart\UartH4Probe.cer'])
$hfpCertificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sourceFiles['drivers\hfp\BthHfpAudio.cer'])
if ($uartCertificate.Thumbprint -ne $expectedCertificateThumbprint -or
    $hfpCertificate.Thumbprint -ne $expectedCertificateThumbprint) {
    throw 'The driver certificate does not match -CertificateThumbprint.'
}

foreach ($signedKey in @(
    'drivers\uart\UartH4Probe.sys',
    'drivers\uart\UartH4Probe.cat',
    'drivers\hfp\BthHfpAudio.sys',
    'drivers\hfp\BthHfpAudio.cat')) {
    $signature = Get-AuthenticodeSignature -LiteralPath $sourceFiles[$signedKey]
    if (-not $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ne $expectedCertificateThumbprint) {
        throw "The payload signature does not match the selected certificate: $signedKey"
    }
}

$uartVersion = Get-InfDriverVersion -Path $sourceFiles['drivers\uart\UartH4Probe.inf']
$hfpVersion = Get-InfDriverVersion -Path $sourceFiles['drivers\hfp\BthHfpAudio.inf']

if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) { throw "MSBuild is missing: $msbuild" }
& $msbuild $nativeProject /m /p:Configuration=Release /p:Platform=x64 /v:minimal
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $nativeExe -PathType Leaf)) {
    throw 'The native installer helper did not build successfully.'
}

Reset-Directory $stageRoot
New-Item -ItemType Directory -Path $distRoot -Force | Out-Null
foreach ($entry in $sourceFiles.GetEnumerator()) {
    $destination = Join-Path $stageRoot $entry.Key
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    if ([IO.Path]::GetExtension([string]$entry.Value) -ieq '.ps1') {
        $sourceBytes = [IO.File]::ReadAllBytes([string]$entry.Value)
        $hasUtf8Bom = $sourceBytes.Length -ge 3 -and
            $sourceBytes[0] -eq 0xEF -and
            $sourceBytes[1] -eq 0xBB -and
            $sourceBytes[2] -eq 0xBF
        if ($hasUtf8Bom) {
            [IO.File]::WriteAllBytes($destination, $sourceBytes)
        } else {
            $utf8Bytes = New-Object byte[] ($sourceBytes.Length + 3)
            $utf8Bytes[0] = 0xEF
            $utf8Bytes[1] = 0xBB
            $utf8Bytes[2] = 0xBF
            [Buffer]::BlockCopy($sourceBytes, 0, $utf8Bytes, 3, $sourceBytes.Length)
            [IO.File]::WriteAllBytes($destination, $utf8Bytes)
        }
    } else {
        Copy-Item -LiteralPath $entry.Value -Destination $destination -Force
    }
}
$nativeDestination = Join-Path $stageRoot 'native\BluetoothMicMacNative.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $nativeDestination) -Force | Out-Null
Copy-Item -LiteralPath $nativeExe -Destination $nativeDestination -Force

$manifestFiles = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        Path = $_.FullName.Substring($stageRoot.Length + 1).Replace('\', '/')
        Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        Size = $_.Length
    }
})
[ordered]@{
    Version = $installerVersion
    CertificateThumbprint = $expectedCertificateThumbprint
    UartDriverVersion = $uartVersion
    HfpDriverVersion = $hfpVersion
    Files = $manifestFiles
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stageRoot 'payload-manifest.json') -Encoding UTF8

if (Test-Path -LiteralPath $payloadZip) { Remove-Item -LiteralPath $payloadZip -Force }
Compress-Archive -Path (Join-Path $stageRoot '*') -DestinationPath $payloadZip -CompressionLevel Optimal
Write-MultiSizeIcon -SourcePng $iconSource -DestinationIco $iconPath

if (-not (Test-Path -LiteralPath $csc -PathType Leaf)) { throw "C# compiler is missing: $csc" }
$compilerArguments = @(
    '/nologo'
    '/target:winexe'
    '/platform:x64'
    '/optimize+'
    '/debug-'
    '/codepage:65001'
    "/out:$outputExe"
    "/win32manifest:$(Join-Path $PSScriptRoot 'bootstrap\app.manifest')"
    "/win32icon:$iconPath"
    "/resource:$payloadZip,BluetoothMicMac.Payload.zip"
    '/reference:System.dll'
    '/reference:System.Core.dll'
    '/reference:System.Drawing.dll'
    '/reference:System.Windows.Forms.dll'
    '/reference:System.IO.Compression.dll'
    '/reference:System.IO.Compression.FileSystem.dll'
    (Join-Path $PSScriptRoot 'bootstrap\Program.cs')
)
& $csc $compilerArguments
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputExe -PathType Leaf)) {
    throw 'The graphical bootstrap executable did not build successfully.'
}

$signArguments = @('sign', '/fd', 'SHA256', '/sha1', $expectedCertificateThumbprint, '/s', 'My')
if ($TimestampUrl) { $signArguments += @('/tr', $TimestampUrl, '/td', 'SHA256') }
& $tools.SignTool @signArguments $outputExe
if ($LASTEXITCODE -ne 0) { throw 'Signing the installer executable failed.' }

$outputHash = (Get-FileHash -LiteralPath $outputExe -Algorithm SHA256).Hash
Write-Host "Built: $outputExe"
Write-Host "Size:  $((Get-Item -LiteralPath $outputExe).Length) bytes"
Write-Host "SHA256: $outputHash"
