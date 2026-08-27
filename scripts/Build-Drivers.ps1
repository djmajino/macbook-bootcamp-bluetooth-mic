[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tools = & (Join-Path $PSScriptRoot 'Get-BuildTools.ps1')

function Reset-ArtifactDirectory {
    param([Parameter(Mandatory)][string] $Path)
    $artifactRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'artifacts')).TrimEnd('\') + '\'
    $target = [IO.Path]::GetFullPath($Path)
    if (-not $target.StartsWith($artifactRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset a path outside artifacts: $target"
    }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
}

$projects = @(
    (Join-Path $repoRoot 'uart_h4_probe\driver\UartH4Probe.vcxproj'),
    (Join-Path $repoRoot 'uart_h4_probe\tools\UartH4Query.vcxproj'),
    (Join-Path $repoRoot 'hfp_audio\BthHfpEndpoints.vcxproj'),
    (Join-Path $repoRoot 'hfp_audio\BthHfpAudio.vcxproj')
)

foreach ($project in $projects) {
    & $tools.MSBuild $project /m /t:Rebuild "/p:Configuration=$Configuration" `
        /p:Platform=x64 "/p:WindowsTargetPlatformVersion=$($tools.WdkVersion)" `
        /p:SignMode=Off /v:minimal
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed for $project with exit code $LASTEXITCODE."
    }
}

$unsignedRoot = Join-Path $repoRoot "artifacts\$Configuration\unsigned"
$uartPackage = Join-Path $unsignedRoot 'uart'
$hfpPackage = Join-Path $unsignedRoot 'hfp'
Reset-ArtifactDirectory $unsignedRoot
New-Item -ItemType Directory -Path $uartPackage,$hfpPackage -Force | Out-Null

$uartBuild = Join-Path $repoRoot "uart_h4_probe\build\$Configuration"
$hfpBuild = Join-Path $repoRoot "build\$Configuration\hfp_audio\driver"

$copyMap = [ordered]@{
    (Join-Path $uartBuild 'driver\UartH4Probe.sys') = (Join-Path $uartPackage 'UartH4Probe.sys')
    (Join-Path $uartBuild 'driver\UartH4Probe.inf') = (Join-Path $uartPackage 'UartH4Probe.inf')
    (Join-Path $uartBuild 'driver\UartH4Probe.pdb') = (Join-Path $uartPackage 'UartH4Probe.pdb')
    (Join-Path $uartBuild 'tools\UartH4Query.exe') = (Join-Path $uartPackage 'UartH4Query.exe')
    (Join-Path $hfpBuild 'BthHfpAudio.sys') = (Join-Path $hfpPackage 'BthHfpAudio.sys')
    (Join-Path $hfpBuild 'BthHfpAudio.inf') = (Join-Path $hfpPackage 'BthHfpAudio.inf')
    (Join-Path $hfpBuild 'BthHfpAudio.pdb') = (Join-Path $hfpPackage 'BthHfpAudio.pdb')
}

foreach ($entry in $copyMap.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $entry.Key -PathType Leaf)) {
        throw "Expected build output is missing: $($entry.Key)"
    }
    Copy-Item -LiteralPath $entry.Key -Destination $entry.Value -Force
}

foreach ($package in @($uartPackage, $hfpPackage)) {
    if (Test-Path -LiteralPath $tools.InfVerif -PathType Leaf) {
        $inf = Get-ChildItem -LiteralPath $package -Filter '*.inf' -File | Select-Object -First 1
        & $tools.InfVerif /w $inf.FullName
        if ($LASTEXITCODE -ne 0) { throw "InfVerif rejected $($inf.Name)." }
    }
    & $tools.Inf2Cat "/driver:$package" /os:10_X64 /uselocaltime
    if ($LASTEXITCODE -ne 0) { throw "Inf2Cat failed for $package." }
}

Write-Host "Unsigned packages: $unsignedRoot"
[pscustomobject]@{
    Configuration = $Configuration
    Root = $unsignedRoot
    UartPackage = $uartPackage
    HfpPackage = $hfpPackage
}
