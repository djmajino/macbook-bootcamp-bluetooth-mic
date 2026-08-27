[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[string]

$forbiddenExtensions = @(
    '.sys', '.cat', '.cer', '.pfx', '.p12', '.pvk', '.pdb', '.exe', '.dll',
    '.lib', '.obj', '.dmp', '.etl', '.evtx', '.wav', '.zip', '.cab'
)
$ignoredDirectories = @('.git', 'artifacts', 'build', 'obj', 'bin', 'dist', 'x64', 'Debug', 'Release')
$files = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | Where-Object {
    $relativeParts = $_.FullName.Substring($repoRoot.Length).TrimStart('\').Split('\')
    -not ($relativeParts | Where-Object { $_ -in $ignoredDirectories })
})

foreach ($file in $files) {
    if ($file.Extension -in $forbiddenExtensions) {
        $errors.Add("Forbidden generated or sensitive file: $($file.FullName)")
    }
    if ($file.Name -match '(?i)(private.?key|secret|password|token)') {
        $errors.Add("Suspicious file name: $($file.FullName)")
    }

    # Alternate data streams are not represented by Git, but can carry local
    # download provenance or other machine-specific metadata in a working tree.
    $alternateStreams = @(Get-Item -LiteralPath $file.FullName -Stream * -ErrorAction SilentlyContinue |
        Where-Object { $_.Stream -ne ':$DATA' })
    foreach ($stream in $alternateStreams) {
        $errors.Add("NTFS alternate data stream '$($stream.Stream)': $($file.FullName)")
    }
}

$textExtensions = @('.md', '.txt', '.ps1', '.cs', '.c', '.cpp', '.h', '.inf', '.inx', '.vcxproj', '.json', '.yml', '.yaml', '.gitattributes', '.gitignore')
$patterns = [ordered]@{
    'Local Windows user path' = '(?i)[A-Z]:\\Users\\[^<\\\s]+'
    'Local Windows slash-style user path' = '(?i)[A-Z]:/Users/[^</\s]+'
    'Machine-generated account name' = '(?i)DESKTOP-[A-Z0-9]+\\'
    'Private key material' = '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
    'Literal 40-hex identity or certificate thumbprint' = '(?i)(?<![0-9A-F])[0-9A-F]{40}(?![0-9A-F])'
    'Complete PCI device instance' = '(?i)PCI\\VEN_[0-9A-F]{4}[^\r\n"'']*\\[0-9A-F&]+'
    'Complete Broadcom radio instance' = '(?i)BCMBTBUS\\BLUETOOTH\\[0-9A-F&]+'
    'Complete Bluetooth enumerator instance' = '(?i)BTHENUM[\\#][^\r\n"'']*[\\#][0-9A-F&]+'
    'Windows security identifier' = '(?i)S-1-5-21-(?:\d+-){3}\d+'
    'Bluetooth or network MAC address' = '(?i)(?:[0-9A-F]{2}[:-]){5}[0-9A-F]{2}'
    'GitHub token' = '(?i)gh[pousr]_[A-Za-z0-9]{20,}'
    'Generic bearer token' = '(?i)Authorization\s*:\s*Bearer\s+[A-Za-z0-9._-]{16,}'
}

foreach ($file in $files | Where-Object { $_.Extension -in $textExtensions -or $_.Name -in @('.gitignore', '.gitattributes') }) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    foreach ($pattern in $patterns.GetEnumerator()) {
        if ($content -match $pattern.Value) {
            $errors.Add("$($pattern.Key): $($file.FullName)")
        }
    }
}

if ($errors.Count -gt 0) {
    $errors | Sort-Object -Unique | ForEach-Object { Write-Error $_ }
    throw "Public-tree audit failed with $($errors.Count) finding(s)."
}

Write-Host "Public-tree audit passed for $($files.Count) source files."
