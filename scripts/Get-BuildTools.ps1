[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'Visual Studio Installer (vswhere.exe) was not found.'
}

$visualStudio = & $vswhere -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -property installationPath
if (-not $visualStudio) {
    throw 'Visual Studio 2022 C++ Build Tools were not found.'
}

$msbuild = Join-Path $visualStudio 'MSBuild\Current\Bin\amd64\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild -PathType Leaf)) {
    throw "MSBuild was not found under $visualStudio."
}

$kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$binRoot = Join-Path $kitsRoot 'bin'
if (-not (Test-Path -LiteralPath $binRoot -PathType Container)) {
    throw 'Windows 10/11 SDK and WDK tools were not found.'
}

$versions = @(Get-ChildItem -LiteralPath $binRoot -Directory | Where-Object {
    $_.Name -match '^10\.\d+\.\d+\.\d+$'
} | Sort-Object { [version]$_.Name } -Descending)

$selected = $null
foreach ($version in $versions) {
    $candidate = [pscustomobject]@{
        Version = $version.Name
        # Inf2Cat is distributed as an x86 host tool even for x64 driver packages.
        Inf2Cat = Join-Path $version.FullName 'x86\Inf2Cat.exe'
        InfVerif = Join-Path $kitsRoot "Tools\$($version.Name)\x64\InfVerif.exe"
        SignTool = Join-Path $version.FullName 'x64\signtool.exe'
    }
    if ((Test-Path -LiteralPath $candidate.Inf2Cat -PathType Leaf) -and
        (Test-Path -LiteralPath $candidate.SignTool -PathType Leaf)) {
        $selected = $candidate
        break
    }
}

if (-not $selected) {
    throw 'Inf2Cat.exe and SignTool.exe were not found in an installed Windows SDK/WDK.'
}

[pscustomobject]@{
    VisualStudio = $visualStudio
    MSBuild = $msbuild
    KitsRoot = $kitsRoot
    WdkVersion = $selected.Version
    Inf2Cat = $selected.Inf2Cat
    InfVerif = $selected.InfVerif
    SignTool = $selected.SignTool
}
