[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Start', 'Resume', 'Uninstall')]
    [string] $Mode = 'Inspect',

    [switch] $AllowTestSigning
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$installerVersion = '1.0.0'
$expectedModel = 'MacBookPro16,1'
$minimumWindowsBuild = 18362
$expectedUartVersion = ''
$expectedHfpVersion = ''
$expectedCertificateThumbprint = ''
$uartHardwareId = 'PCI\VEN_8086&DEV_A328&SUBSYS_72708086'
$uartInstance = ''
$parentInstance = ''
$radioInstance = ''
$hfpHardwareId = 'Root\BthHfpAudio'

$programRoot = Join-Path $env:ProgramData 'BluetoothMicMacInstaller'
$payloadRoot = $PSScriptRoot
$statePath = Join-Path $programRoot 'state.json'
$logPath = Join-Path $programRoot 'installer.log'
$installedExe = Join-Path $programRoot 'BluetoothMicMacInstaller.exe'
$resumeTaskName = 'Bluetooth Mic Mac Installer Resume'
$uartRecoveryTaskName = 'Bluetooth Mic Mac UART H4 Recovery'
$uartRecoveryStateRoot = Join-Path $env:ProgramData 'BluetoothMicMac-UartH4Probe'
$uartRecoveryStatePath = Join-Path $uartRecoveryStateRoot 'state.json'
$recoveryFailureMarker = Join-Path $programRoot 'uart-recovery-failed.txt'

$nativeHelper = Join-Path $payloadRoot 'native\BluetoothMicMacNative.exe'
$manifestPath = Join-Path $payloadRoot 'payload-manifest.json'
$uartRoot = Join-Path $payloadRoot 'drivers\uart'
$uartInf = Join-Path $uartRoot 'UartH4Probe.inf'
$uartSys = Join-Path $uartRoot 'UartH4Probe.sys'
$uartCat = Join-Path $uartRoot 'UartH4Probe.cat'
$uartCer = Join-Path $uartRoot 'UartH4Probe.cer'
$uartQuery = Join-Path $uartRoot 'UartH4Query.exe'
$uartRecoveryScript = Join-Path $payloadRoot 'uart-recovery.ps1'
$hfpRoot = Join-Path $payloadRoot 'drivers\hfp'
$hfpInf = Join-Path $hfpRoot 'BthHfpAudio.inf'
$hfpSys = Join-Path $hfpRoot 'BthHfpAudio.sys'
$hfpCat = Join-Path $hfpRoot 'BthHfpAudio.cat'
$hfpCer = Join-Path $hfpRoot 'BthHfpAudio.cer'

function ConvertTo-OneLine {
    param([AllowNull()][object] $Value)
    if ($null -eq $Value) { return '' }
    (([string]$Value) -replace '[\r\n]+', ' ' -replace '\|', '/')
}

function Send-Protocol {
    param(
        [string] $Kind,
        [AllowNull()][object] $Value
    )
    [Console]::Out.WriteLine([string]::Format(
        '@@{0}|{1}',
        $Kind,
        (ConvertTo-OneLine $Value)))
}

function Send-Result {
    param(
        [string] $Kind,
        [string] $Message
    )
    $resultLine = [string]::Format(
        '@@RESULT|{0}|{1}',
        (ConvertTo-OneLine $Kind),
        (ConvertTo-OneLine $Message))
    [Console]::Out.WriteLine($resultLine)
    if (Test-Path -LiteralPath $programRoot -PathType Container) {
        $logLine = [string]::Format(
            '{0:u} RESULT {1}: {2}',
            (Get-Date),
            (ConvertTo-OneLine $Kind),
            (ConvertTo-OneLine $Message))
        Add-Content -LiteralPath $logPath -Value $logLine -Encoding UTF8
    }
}

function Send-Check {
    param(
        [Parameter(Mandatory)][int] $Order,
        [Parameter(Mandatory)][string] $State,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Details
    )
    [Console]::Out.WriteLine([string]::Format(
        '@@CHECK|{0}|{1}|{2}|{3}',
        $Order,
        (ConvertTo-OneLine $State),
        (ConvertTo-OneLine $Title),
        (ConvertTo-OneLine $Details)))
}

function Write-InstallerLog {
    param([string] $Message)
    New-Item -ItemType Directory -Path $programRoot -Force | Out-Null
    $line = '{0:u} {1}' -f (Get-Date), (ConvertTo-OneLine $Message)
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    Send-Protocol -Kind 'LOG' -Value $Message
}

function Test-Administrator {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'This installer must run with administrator privileges.'
    }
}

function Get-CurrentBootTime {
    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
}

function Get-ResumeIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{
        Name = $identity.Name
        Sid = $identity.User.Value
    }
}

function Read-InstallerState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    catch {
        throw "The saved setup state is damaged: $($_.Exception.Message)"
    }
}

function Save-InstallerState {
    param(
        [Parameter(Mandatory)][string] $Phase,
        [string] $Message = '',
        [string] $ErrorMessage = '',
        [Nullable[int]] $RebootCount
    )
    $old = Read-InstallerState
    $identity = Get-ResumeIdentity
    $count = if ($null -ne $RebootCount) {
        [int]$RebootCount
    } elseif ($old -and $null -ne $old.RebootCount) {
        [int]$old.RebootCount
    } else {
        0
    }
    $resumeName = if ($old -and $old.ResumeUser) { [string]$old.ResumeUser } else { $identity.Name }
    $resumeSid = if ($old -and $old.ResumeUserSid) { [string]$old.ResumeUserSid } else { $identity.Sid }
    $state = [ordered]@{
        InstallerVersion = $installerVersion
        Phase = $Phase
        ResumeUser = $resumeName
        ResumeUserSid = $resumeSid
        RebootCount = $count
        BootTime = Get-CurrentBootTime
        UpdatedAt = (Get-Date).ToString('o')
        LastMessage = $Message
        LastError = $ErrorMessage
    }
    New-Item -ItemType Directory -Path $programRoot -Force | Out-Null
    $temporaryPath = "$statePath.new"
    $state | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $statePath -Force
    [pscustomobject]$state
}

function Assert-PayloadIntegrity {
    Send-Protocol -Kind 'STATUS' -Value 'Verifying the embedded driver payload...'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The payload manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ([string]$manifest.Version -ne $installerVersion) {
        throw "Unsupported payload version '$($manifest.Version)'."
    }
    $script:expectedCertificateThumbprint = ([string]$manifest.CertificateThumbprint).ToUpperInvariant()
    $script:expectedUartVersion = [string]$manifest.UartDriverVersion
    $script:expectedHfpVersion = [string]$manifest.HfpDriverVersion
    if ($script:expectedCertificateThumbprint -notmatch '^[0-9A-F]{40}$' -or
        $script:expectedUartVersion -notmatch '^[0-9]+(?:\.[0-9]+){3}$' -or
        $script:expectedHfpVersion -notmatch '^[0-9]+(?:\.[0-9]+){3}$') {
        throw 'The payload manifest contains invalid signing or driver-version metadata.'
    }
    Resolve-TargetInstances
    $payloadPrefix = [IO.Path]::GetFullPath($payloadRoot).TrimEnd('\') + '\'
    foreach ($entry in @($manifest.Files)) {
        $relative = ([string]$entry.Path).Replace('/', '\')
        $fullPath = [IO.Path]::GetFullPath((Join-Path $payloadRoot $relative))
        if (-not $fullPath.StartsWith($payloadPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The manifest contains an invalid path: $relative"
        }
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "A payload file is missing: $relative"
        }
        $actual = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
        if ($actual -ne [string]$entry.Sha256) {
            throw "The payload checksum does not match: $relative"
        }
    }

    foreach ($certificatePath in @($uartCer, $hfpCer)) {
        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
        if ($certificate.Thumbprint -ne $expectedCertificateThumbprint) {
            throw "Unexpected certificate in file: $certificatePath"
        }
    }
    foreach ($signedPath in @($uartSys, $uartCat, $hfpSys, $hfpCat)) {
        $signature = Get-AuthenticodeSignature -LiteralPath $signedPath
        if (-not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -ne $expectedCertificateThumbprint) {
            throw "The file signature does not match the release certificate: $signedPath"
        }
    }
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [string[]] $Arguments = @(),
        [string] $Description = $FilePath
    )
    Write-InstallerLog $Description
    $output = @(& $FilePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
            Write-InstallerLog ([string]$line)
        }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output -join "`n"
    }
}

function Test-TestSigningActive {
    $output = @(& $nativeHelper status-testsigning 2>&1)
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) { Write-InstallerLog ([string]$line) }
    if ($exitCode -eq 0) { return $true }
    if ($exitCode -eq 3) { return $false }
    throw "Could not determine the active Test Mode state (native helper exit=$exitCode)."
}

function Get-SecureBootState {
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { return 'Enabled' }
        return 'Disabled'
    }
    catch [PlatformNotSupportedException] {
        return 'Unsupported'
    }
    catch {
        if ($_.Exception.Message -match '(?i)not supported|nepodpor') { return 'Unsupported' }
        Write-InstallerLog "Secure Boot could not be read directly: $($_.Exception.Message)"
        return 'Unknown'
    }
}

function Get-PnpTarget {
    param([string] $InstanceId)
    if ([string]::IsNullOrWhiteSpace($InstanceId)) { return $null }
    Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
}

function Find-UniquePnpInstance {
    param([Parameter(Mandatory)][string] $InstancePrefix)
    $matches = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like "$InstancePrefix*"
    })
    if ($matches.Count -eq 1) { return [string]$matches[0].InstanceId }
    return ''
}

function Resolve-TargetInstances {
    $script:uartInstance = Find-UniquePnpInstance -InstancePrefix $uartHardwareId
    $script:parentInstance = Find-UniquePnpInstance -InstancePrefix 'ACPI\BCM2E7C\'
    $script:radioInstance = Find-UniquePnpInstance -InstancePrefix 'BCMBTBUS\BLUETOOTH\'
}

function Get-PnpPropertyValue {
    param(
        [string] $InstanceId,
        [string] $KeyName
    )
    $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction SilentlyContinue
    if ($property) { return $property.Data }
    return $null
}

function Get-HfpRootDevices {
    @(Get-PnpDevice -InstanceId 'ROOT\MEDIA\*' -ErrorAction SilentlyContinue | ForEach-Object {
        $device = $_
        $hardwareIds = @((Get-PnpPropertyValue -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds'))
        if ($hardwareIds -contains $hfpHardwareId) { $device }
    })
}

function Get-DriverService {
    param([string] $Name)
    Get-CimInstance Win32_SystemDriver -Filter "Name='$Name'" -ErrorAction SilentlyContinue
}

function Test-DriverBinaryHash {
    param(
        [AllowNull()][object] $Service,
        [string] $ExpectedFile
    )
    if (-not $Service -or [string]::IsNullOrWhiteSpace([string]$Service.PathName)) { return $false }
    $path = ([string]$Service.PathName).Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $ExpectedFile -Algorithm SHA256).Hash
}

function Test-UartQuery {
    $output = @(& $uartQuery 2>&1)
    $exitCode = $LASTEXITCODE
    if ($output.Count -gt 0) {
        Write-InstallerLog ([string]$output[0])
    }
    if ($exitCode -ne 0) {
        foreach ($line in @($output | Select-Object -Skip 1 -First 10)) {
            Write-InstallerLog ([string]$line)
        }
    }
    $exitCode -eq 0 -and (($output -join "`n") -match '(?i)state\s+v5|version\s*[:=]\s*5')
}

function Get-InstallStatus {
    $computerModel = [string](Get-CimInstance Win32_ComputerSystem).Model
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $windowsBuild = [int]$operatingSystem.BuildNumber
    $supportedWindows = [Environment]::Is64BitOperatingSystem -and
        $windowsBuild -ge $minimumWindowsBuild
    $uart = Get-PnpTarget $uartInstance
    $parent = Get-PnpTarget $parentInstance
    $radio = Get-PnpTarget $radioInstance
    $baseHealthy =
        $uart -and $uart.Status -eq 'OK' -and
        $parent -and $parent.Status -eq 'OK' -and
        $radio -and $radio.Status -eq 'OK'

    $uartService = Get-DriverService 'UartH4Probe'
    $uartBinaryExact = Test-DriverBinaryHash -Service $uartService -ExpectedFile $uartSys
    $uartQueryOkay = $false
    if ($baseHealthy -and $uartService -and $uartService.State -eq 'Running' -and $uartBinaryExact) {
        $uartQueryOkay = Test-UartQuery
    }
    $uartComplete = $baseHealthy -and $uartService -and
        $uartService.State -eq 'Running' -and $uartBinaryExact -and $uartQueryOkay

    $hfpDevices = @(Get-HfpRootDevices)
    $hfpService = Get-DriverService 'BthHfpAudio'
    $hfpBinaryExact = Test-DriverBinaryHash -Service $hfpService -ExpectedFile $hfpSys
    $hfpVersion = if ($hfpDevices.Count -eq 1) {
        [string](Get-PnpPropertyValue -InstanceId $hfpDevices[0].InstanceId -KeyName 'DEVPKEY_Device_DriverVersion')
    } else { '' }
    $hfpDeviceService = if ($hfpDevices.Count -eq 1) {
        [string](Get-PnpPropertyValue -InstanceId $hfpDevices[0].InstanceId -KeyName 'DEVPKEY_Device_Service')
    } else { '' }
    $hfpComplete = $hfpDevices.Count -eq 1 -and
        $hfpDevices[0].Status -eq 'OK' -and
        $hfpVersion -eq $expectedHfpVersion -and
        $hfpDeviceService -eq 'BthHfpAudio' -and
        $hfpService -and $hfpService.State -eq 'Running' -and $hfpBinaryExact

    $uartPackages = @(Get-UartPackages)
    $hfpPackages = @(Get-HfpPackages)
    $certificateInstalled =
        [bool](Get-Item -LiteralPath "Cert:\LocalMachine\Root\$expectedCertificateThumbprint" -ErrorAction SilentlyContinue) -or
        [bool](Get-Item -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$expectedCertificateThumbprint" -ErrorAction SilentlyContinue)
    $anyInstalled =
        $uartService -or $hfpService -or $hfpDevices.Count -gt 0 -or
        $uartPackages.Count -gt 0 -or $hfpPackages.Count -gt 0 -or
        $certificateInstalled
    $testSigningActive = Test-TestSigningActive
    $secureBootState = if ($testSigningActive) { 'NotRequired' } else { Get-SecureBootState }

    [pscustomobject]@{
        Model = $computerModel
        SupportedModel = $computerModel -eq $expectedModel
        WindowsBuild = $windowsBuild
        SupportedWindows = [bool]$supportedWindows
        TestSigningActive = [bool]$testSigningActive
        SecureBootState = $secureBootState
        UartStatus = if ($uart) { "$($uart.Status)/$($uart.Problem)" } else { 'MISSING' }
        ParentStatus = if ($parent) { "$($parent.Status)/$($parent.Problem)" } else { 'MISSING' }
        RadioStatus = if ($radio) { "$($radio.Status)/$($radio.Problem)" } else { 'MISSING' }
        BaseHealthy = [bool]$baseHealthy
        UartServiceState = if ($uartService) { [string]$uartService.State } else { 'Missing' }
        UartBinaryExact = [bool]$uartBinaryExact
        UartQueryOkay = [bool]$uartQueryOkay
        UartComplete = [bool]$uartComplete
        HfpDeviceCount = $hfpDevices.Count
        HfpDeviceStatus = if ($hfpDevices.Count -eq 1) { "$($hfpDevices[0].Status)/$($hfpDevices[0].Problem)" } else { 'MissingOrDuplicate' }
        HfpVersion = $hfpVersion
        HfpServiceState = if ($hfpService) { [string]$hfpService.State } else { 'Missing' }
        HfpBinaryExact = [bool]$hfpBinaryExact
        HfpComplete = [bool]$hfpComplete
        UartPackageCount = $uartPackages.Count
        HfpPackageCount = $hfpPackages.Count
        CertificateInstalled = [bool]$certificateInstalled
        AnyInstalled = [bool]$anyInstalled
        Complete = [bool](
            $supportedWindows -and
            $computerModel -eq $expectedModel -and
            $baseHealthy -and
            $testSigningActive -and
            $uartComplete -and
            $hfpComplete)
    }
}

function Write-StatusSummary {
    param([object] $Status)
    Write-InstallerLog "Model=$($Status.Model), WindowsBuild=$($Status.WindowsBuild), SupportedWindows=$($Status.SupportedWindows), TestMode=$($Status.TestSigningActive)"
    Write-InstallerLog "Bluetooth: UART=$($Status.UartStatus), parent=$($Status.ParentStatus), radio=$($Status.RadioStatus)"
    Write-InstallerLog "UART filter: complete=$($Status.UartComplete), service=$($Status.UartServiceState), exactBinary=$($Status.UartBinaryExact), query=$($Status.UartQueryOkay), packages=$($Status.UartPackageCount)"
    Write-InstallerLog "HFP audio: complete=$($Status.HfpComplete), devices=$($Status.HfpDeviceCount), status=$($Status.HfpDeviceStatus), version=$($Status.HfpVersion), service=$($Status.HfpServiceState), exactBinary=$($Status.HfpBinaryExact), packages=$($Status.HfpPackageCount)"
    Write-InstallerLog "Release certificate installed=$($Status.CertificateInstalled), any project component installed=$($Status.AnyInstalled)"
}

function Write-ReadinessChecklist {
    param([Parameter(Mandatory)][object] $Status)

    if (-not $Status.SupportedWindows) {
        Send-Check -Order 1 -State 'BLOCKED' -Title 'Apple Boot Camp target' -Details "Windows 10 version 1903 (build $minimumWindowsBuild) or later, x64, is required."
    } elseif (-not $Status.SupportedModel) {
        Send-Check -Order 1 -State 'BLOCKED' -Title 'Apple Boot Camp target' -Details 'This Mac model is not supported by this installer.'
    } elseif ($Status.BaseHealthy) {
        Send-Check -Order 1 -State 'READY' -Title 'Apple Boot Camp target' -Details 'The Windows version, Mac model, and required Boot Camp Bluetooth devices are supported and healthy.'
    } else {
        Send-Check -Order 1 -State 'MISSING' -Title 'Apple Boot Camp target' -Details 'Install or repair Apple Boot Camp Support Software, then restart Windows.'
    }

    if ($Status.TestSigningActive) {
        Send-Check -Order 2 -State 'READY' -Title 'Windows Test Mode' -Details 'Test Mode is active in this Windows session.'
    } elseif ($Status.SecureBootState -eq 'Enabled') {
        Send-Check -Order 2 -State 'BLOCKED' -Title 'Windows Test Mode' -Details 'Disable Secure Boot in firmware before continuing.'
    } else {
        Send-Check -Order 2 -State 'ACTION REQUIRED' -Title 'Windows Test Mode' -Details 'Setup can enable Test Mode automatically and restart Windows.'
    }

    if ($Status.CertificateInstalled) {
        Send-Check -Order 3 -State 'READY' -Title 'Self-signed driver certificate' -Details 'The included driver certificate is trusted by Windows.'
    } else {
        Send-Check -Order 3 -State 'PENDING' -Title 'Self-signed driver certificate' -Details 'Setup will trust the included certificate automatically.'
    }

    if ($Status.UartComplete) {
        Send-Check -Order 4 -State 'READY' -Title 'UART H4 Bluetooth filter' -Details 'The Bluetooth transport filter is installed and working.'
    } elseif ($Status.UartServiceState -ne 'Missing' -or $Status.UartPackageCount -gt 0) {
        Send-Check -Order 4 -State 'ACTION REQUIRED' -Title 'UART H4 Bluetooth filter' -Details 'An older or incomplete filter will be repaired automatically.'
    } else {
        Send-Check -Order 4 -State 'PENDING' -Title 'UART H4 Bluetooth filter' -Details 'Setup installs this after Test Mode and the certificate are ready.'
    }

    if ($Status.HfpComplete) {
        Send-Check -Order 5 -State 'READY' -Title 'HFP microphone + audio endpoint' -Details 'The microphone and headset audio driver is installed and working.'
    } elseif ($Status.HfpDeviceCount -gt 0 -or $Status.HfpServiceState -ne 'Missing' -or $Status.HfpPackageCount -gt 0) {
        Send-Check -Order 5 -State 'ACTION REQUIRED' -Title 'HFP microphone + audio endpoint' -Details 'An older or incomplete audio driver will be repaired automatically.'
    } else {
        Send-Check -Order 5 -State 'PENDING' -Title 'HFP microphone + audio endpoint' -Details 'Setup installs this after the Bluetooth transport filter is ready.'
    }

    if ($Status.Complete) {
        Send-Check -Order 6 -State 'READY' -Title 'Final full-duplex readiness' -Details 'Bluetooth playback and headset microphone support are ready.'
    } elseif (-not $Status.SupportedWindows -or -not $Status.SupportedModel -or -not $Status.BaseHealthy -or $Status.SecureBootState -eq 'Enabled') {
        Send-Check -Order 6 -State 'BLOCKED' -Title 'Final full-duplex readiness' -Details 'Resolve the blocked prerequisite above before installation can continue.'
    } else {
        Send-Check -Order 6 -State 'PENDING' -Title 'Final full-duplex readiness' -Details 'Setup completes this after the preceding checklist items.'
    }
}

function Assert-CompatibleTarget {
    param([object] $Status)
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This package supports only 64-bit Windows.'
    }
    if ($Status.WindowsBuild -lt $minimumWindowsBuild) {
        throw "This package requires Windows 10 version 1903 (build $minimumWindowsBuild) or later; detected build $($Status.WindowsBuild)."
    }
    if ($Status.Model -ne $expectedModel) {
        throw "This package is restricted to $expectedModel; the detected model is '$($Status.Model)'."
    }
    if (-not $Status.BaseHealthy) {
        throw "Required Apple Boot Camp Bluetooth drivers are missing or unhealthy: UART=$($Status.UartStatus), parent=$($Status.ParentStatus), radio=$($Status.RadioStatus). Install or reinstall Apple Boot Camp Support Software, restart Windows, and run this setup again."
    }
}

function Import-TestCertificate {
    foreach ($certificatePath in @($uartCer, $hfpCer)) {
        Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
        Import-Certificate -FilePath $certificatePath -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' | Out-Null
    }
    Write-InstallerLog "Test certificate $expectedCertificateThumbprint is trusted in LocalMachine."
}

function Register-ResumeTask {
    $state = Read-InstallerState
    if (-not $state) { throw 'Setup state is missing before resume-task registration.' }
    if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
        throw "The persistent installer copy is missing: $installedExe"
    }
    $action = New-ScheduledTaskAction -Execute $installedExe -Argument '--resume'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User ([string]$state.ResumeUser)
    $principal = New-ScheduledTaskPrincipal -UserId ([string]$state.ResumeUserSid) -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $resumeTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-InstallerLog "Automatic resume at logon was registered for $($state.ResumeUser)."
}

function Unregister-ResumeTask {
    Unregister-ScheduledTask -TaskName $resumeTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Register-UartRecoveryTask {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$uartRecoveryScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $uartRecoveryTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-InstallerLog 'The UART filter recovery guard is ready.'
}

function Get-UartPackages {
    $xmlText = (& pnputil.exe /enum-drivers /class Extension /format xml 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($xmlText)) { return @() }
    try { [xml]$xml = $xmlText } catch { return @() }
    @($xml.PnpUtil.Driver) | Where-Object {
        $_.OriginalName -ieq 'UartH4Probe.inf' -and
        $_.ProviderName -ieq 'Local UART H4 Research'
    }
}

function Get-HfpPackages {
    $xmlText = (& pnputil.exe /enum-drivers /class Media /format xml 2>$null) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($xmlText)) { return @() }
    try { [xml]$xml = $xmlText } catch { return @() }
    @($xml.PnpUtil.Driver) | Where-Object {
        $_.OriginalName -ieq 'BthHfpAudio.inf' -and
        $_.ProviderName -ieq 'BthHfpAudio experiment'
    }
}

function Install-UartFilter {
    Send-Protocol -Kind 'PROGRESS' -Value 45
    Send-Protocol -Kind 'STATUS' -Value 'Installing the protected UART H4 filter...'
    Import-TestCertificate
    Remove-Item -LiteralPath $recoveryFailureMarker -Force -ErrorAction SilentlyContinue

    $stage = Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/add-driver', $uartInf) -Description 'Staging UART H4 driver package.'
    if ($stage.ExitCode -notin @(0, 259, 3010)) {
        throw "PnP staging UART filtra zlyhal (exit=$($stage.ExitCode))."
    }
    $package = @(Get-UartPackages | Where-Object {
        ([string]$_.DriverVersion) -match ([regex]::Escape($expectedUartVersion) + '$')
    }) | Select-Object -First 1
    if (-not $package -or [string]$package.DriverName -notmatch '^oem\d+\.inf$') {
        throw 'The exact UART package could not be identified after staging.'
    }

    New-Item -ItemType Directory -Path $uartRecoveryStateRoot -Force | Out-Null
    [ordered]@{
        PreparedAt = (Get-Date).ToString('o')
        PublishedInf = [string]$package.DriverName
        CertificateThumbprint = $expectedCertificateThumbprint
        TargetInstance = $uartInstance
    } | ConvertTo-Json | Set-Content -LiteralPath $uartRecoveryStatePath -Encoding UTF8
    Register-UartRecoveryTask

    $activate = Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/add-driver', $uartInf, '/install') -Description "Activating UART H4 package $($package.DriverName)."
    if ($activate.ExitCode -notin @(0, 259, 3010)) {
        throw "UART filter activation failed (exit=$($activate.ExitCode))."
    }
    Save-InstallerState -Phase 'AwaitingUartBoot' -Message "UART filter $($package.DriverName) was activated; waiting for restart." | Out-Null
    Request-InstallerReboot -Reason 'Completing Bluetooth UART filter setup.'
}

function Install-HfpAudio {
    Send-Protocol -Kind 'PROGRESS' -Value 75
    Send-Protocol -Kind 'STATUS' -Value 'Installing the HFP microphone and full-duplex audio endpoint...'
    Import-TestCertificate
    $devices = @(Get-HfpRootDevices)
    if ($devices.Count -gt 1) {
        throw "Found $($devices.Count) $hfpHardwareId devices; refusing to create another duplicate."
    }

    $stage = Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/add-driver', $hfpInf) -Description 'Staging HFP audio driver package.'
    if ($stage.ExitCode -notin @(0, 259, 3010)) {
        throw "PnP staging of the HFP audio package failed (exit=$($stage.ExitCode))."
    }
    $nativeMode = if ($devices.Count -eq 0) { 'install-root' } else { 'update-driver' }
    $native = Invoke-CapturedProcess -FilePath $nativeHelper -Arguments @($nativeMode, $hfpInf, $hfpHardwareId) -Description "Native HFP operation: $nativeMode."
    if ($native.ExitCode -ne 0) {
        throw "Creating or updating the HFP root device failed (exit=$($native.ExitCode))."
    }
    Save-InstallerState -Phase 'AwaitingAudioBoot' -Message 'The HFP audio driver was installed; waiting for restart.' | Out-Null
    Request-InstallerReboot -Reason 'Completing Bluetooth HFP audio driver setup.'
}

function Request-InstallerReboot {
    param([string] $Reason)
    $state = Read-InstallerState
    $nextCount = if ($state) { [int]$state.RebootCount + 1 } else { 1 }
    if ($nextCount -gt 4) {
        throw 'Setup exceeded the safety limit of four automatic restarts.'
    }
    Save-InstallerState -Phase ([string]$state.Phase) -Message $Reason -RebootCount $nextCount | Out-Null
    Register-ResumeTask
    Send-Protocol -Kind 'PROGRESS' -Value 90
    Send-Protocol -Kind 'STATUS' -Value 'Windows will restart in 20 seconds. Setup will resume automatically after logon.'
    Send-Result -Kind 'RebootScheduled' -Message 'Restart scheduled; no further clicks are required after logon.'
    $shutdown = Invoke-CapturedProcess -FilePath 'shutdown.exe' -Arguments @('/r', '/t', '20', '/d', 'p:2:4', '/c', $Reason) -Description 'Scheduling controlled installer reboot.'
    if ($shutdown.ExitCode -ne 0) {
        throw "Could not schedule the restart (exit=$($shutdown.ExitCode))."
    }
}

function Enable-TestSigningAndReboot {
    $secureBoot = Get-SecureBootState
    Write-InstallerLog "SecureBoot=$secureBoot"
    if ($secureBoot -eq 'Enabled') {
        throw 'Secure Boot is enabled. Windows cannot activate these self-signed drivers until Secure Boot is disabled in firmware.'
    }
    Send-Protocol -Kind 'PROGRESS' -Value 20
    Send-Protocol -Kind 'STATUS' -Value 'Enabling Windows Test Mode for the self-signed drivers...'
    Import-TestCertificate
    $bcd = Invoke-CapturedProcess -FilePath 'bcdedit.exe' -Arguments @('/set', 'testsigning', 'on') -Description 'Enabling TESTSIGNING in the active boot configuration.'
    if ($bcd.ExitCode -ne 0) {
        throw "BCDEdit could not enable Test Mode (exit=$($bcd.ExitCode)): $($bcd.Output)"
    }
    Save-InstallerState -Phase 'AwaitingTestModeBoot' -Message 'TESTSIGNING is configured; waiting for restart.' | Out-Null
    Request-InstallerReboot -Reason 'Enabling Windows Test Mode for Bluetooth microphone support.'
}

function Wait-ForUartAfterBoot {
    Send-Protocol -Kind 'STATUS' -Value 'Waiting for Bluetooth initialization and checking the UART recovery guard...'
    for ($attempt = 0; $attempt -lt 22; ++$attempt) {
        if (Test-Path -LiteralPath $recoveryFailureMarker -PathType Leaf) {
            $message = Get-Content -LiteralPath $recoveryFailureMarker -Raw -ErrorAction SilentlyContinue
            throw "The UART recovery guard restored the original Bluetooth driver: $message"
        }
        $uart = Get-PnpTarget $uartInstance
        $parent = Get-PnpTarget $parentInstance
        $radio = Get-PnpTarget $radioInstance
        $service = Get-DriverService 'UartH4Probe'
        if ($uart.Status -eq 'OK' -and $parent.Status -eq 'OK' -and $radio.Status -eq 'OK' -and
            $service -and $service.State -eq 'Running' -and
            (Test-DriverBinaryHash -Service $service -ExpectedFile $uartSys)) {
            Write-InstallerLog "The UART filter became healthy after $($attempt * 5) seconds."
            return
        }
        $progress = [Math]::Min(65, 35 + $attempt)
        Send-Protocol -Kind 'PROGRESS' -Value $progress
        Start-Sleep -Seconds 5
    }
    throw 'Bluetooth or the UART filter was still unhealthy after 110 seconds; see the recovery log for details.'
}

function Complete-Installation {
    Save-InstallerState -Phase 'Complete' -Message 'All required components are installed and active.' | Out-Null
    Unregister-ResumeTask
    Unregister-ScheduledTask -TaskName $uartRecoveryTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Send-Protocol -Kind 'PROGRESS' -Value 100
    Send-Protocol -Kind 'STATUS' -Value 'Everything required is installed and active.'
    Send-Result -Kind 'Installed' -Message 'Done. Bluetooth headsets can use playback and microphone audio.'
    Write-InstallerLog 'Installation completed and verified.'
}

function Continue-Installation {
    $state = Read-InstallerState
    if ($state -and $state.Phase -eq 'AwaitingUartBoot') {
        Wait-ForUartAfterBoot
    }
    if (Test-Path -LiteralPath $recoveryFailureMarker -PathType Leaf) {
        $message = Get-Content -LiteralPath $recoveryFailureMarker -Raw -ErrorAction SilentlyContinue
        throw "The UART filter recovery guard was activated: $message"
    }

    $status = Get-InstallStatus
    Write-StatusSummary $status
    Write-ReadinessChecklist $status
    Assert-CompatibleTarget $status
    if (-not $status.TestSigningActive) {
        throw 'Windows Test Mode is not active after restart; setup stopped safely.'
    }
    if (-not $status.UartComplete) {
        Install-UartFilter
        return
    }
    if (-not $status.HfpComplete) {
        Install-HfpAudio
        return
    }
    Complete-Installation
}

function Remove-DriverPackageSet {
    param(
        [Parameter(Mandatory)][object[]] $Packages,
        [Parameter(Mandatory)][string] $Description
    )
    foreach ($package in $Packages) {
        $publishedInf = [string]$package.DriverName
        if ($publishedInf -notmatch '^oem\d+\.inf$') {
            throw "Refusing an unexpected published INF name: $publishedInf"
        }
        $remove = Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/delete-driver', $publishedInf, '/uninstall', '/force') -Description "Removing exact $Description package $publishedInf."
        if ($remove.ExitCode -notin @(0, 259, 3010)) {
            throw "Removing $publishedInf failed (exit=$($remove.ExitCode))."
        }
    }
}

function Begin-Uninstallation {
    Send-Protocol -Kind 'PROGRESS' -Value 15
    Send-Protocol -Kind 'STATUS' -Value 'Removing Bluetooth Mic Mac components...'
    $status = Get-InstallStatus
    Write-StatusSummary $status
    Write-ReadinessChecklist $status
    if ($status.Model -ne $expectedModel) {
        throw "This removal package is restricted to $expectedModel; the detected model is '$($status.Model)'."
    }

    Save-InstallerState -Phase 'Uninstalling' -Message 'The user requested a complete restore.' -RebootCount 0 | Out-Null
    Register-ResumeTask
    Unregister-ScheduledTask -TaskName $uartRecoveryTaskName -Confirm:$false -ErrorAction SilentlyContinue

    foreach ($device in @(Get-HfpRootDevices)) {
        $removeDevice = Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/remove-device', [string]$device.InstanceId) -Description "Removing exact HFP root device $($device.InstanceId)."
        if ($removeDevice.ExitCode -notin @(0, 259, 3010)) {
            throw "Removing HFP root device $($device.InstanceId) failed (exit=$($removeDevice.ExitCode))."
        }
    }

    Send-Protocol -Kind 'PROGRESS' -Value 40
    Remove-DriverPackageSet -Packages @(Get-HfpPackages) -Description 'HFP audio'
    Remove-DriverPackageSet -Packages @(Get-UartPackages) -Description 'UART H4'

    Send-Protocol -Kind 'PROGRESS' -Value 65
    Send-Protocol -Kind 'STATUS' -Value 'Restoring the normal Windows boot-signing policy...'
    $bcd = Invoke-CapturedProcess -FilePath 'bcdedit.exe' -Arguments @('/set', 'testsigning', 'off') -Description 'Disabling TESTSIGNING in the active boot configuration.'
    if ($bcd.ExitCode -ne 0) {
        throw "BCDEdit could not disable Test Mode (exit=$($bcd.ExitCode)): $($bcd.Output)"
    }

    Save-InstallerState -Phase 'AwaitingUninstallBoot' -Message 'Drivers were removed and TESTSIGNING was disabled; waiting for restart.' | Out-Null
    Request-InstallerReboot -Reason 'Restoring the original Boot Camp Bluetooth configuration.'
}

function Remove-ReleaseCertificate {
    foreach ($storePath in @(
        "Cert:\LocalMachine\Root\$expectedCertificateThumbprint",
        "Cert:\LocalMachine\TrustedPublisher\$expectedCertificateThumbprint")) {
        if (Test-Path -LiteralPath $storePath) {
            Remove-Item -LiteralPath $storePath -Force
            Write-InstallerLog "Removed release certificate from $storePath."
        }
    }
}

function Start-PostExitCleanup {
    $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    $parentProcessId = if ($currentProcess) { [int]$currentProcess.ParentProcessId } else { 0 }
    $escapedProgramRoot = $programRoot.Replace("'", "''")
    $cleanupCommand = @"
`$target = [IO.Path]::GetFullPath('$escapedProgramRoot')
`$expected = [IO.Path]::GetFullPath((Join-Path `$env:ProgramData 'BluetoothMicMacInstaller'))
if (-not `$target.Equals(`$expected, [StringComparison]::OrdinalIgnoreCase)) { exit 2 }
if ($parentProcessId -gt 0) { Wait-Process -Id $parentProcessId -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction SilentlyContinue
foreach (`$extra in @(
    (Join-Path `$env:ProgramData 'BluetoothMicMac-UartH4Probe'),
    (Join-Path `$env:ProgramData 'BluetoothMicMac-HfpAudio'))) {
    `$fullExtra = [IO.Path]::GetFullPath(`$extra)
    `$programDataPrefix = [IO.Path]::GetFullPath(`$env:ProgramData).TrimEnd('\') + '\'
    if (`$fullExtra.StartsWith(`$programDataPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath `$fullExtra -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cleanupCommand))
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) | Out-Null
}

function Finish-Uninstallation {
    Send-Protocol -Kind 'PROGRESS' -Value 75
    Send-Protocol -Kind 'STATUS' -Value 'Verifying the restored Boot Camp Bluetooth stack...'
    Invoke-CapturedProcess -FilePath 'pnputil.exe' -Arguments @('/scan-devices') -Description 'Scanning for restored base devices.' | Out-Null

    $baseHealthy = $false
    for ($attempt = 0; $attempt -lt 18; ++$attempt) {
        $uart = Get-PnpTarget $uartInstance
        $parent = Get-PnpTarget $parentInstance
        $radio = Get-PnpTarget $radioInstance
        $baseHealthy =
            $uart.Status -eq 'OK' -and
            $parent.Status -eq 'OK' -and
            $radio.Status -eq 'OK'
        if ($baseHealthy) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $baseHealthy) {
        throw 'The base Boot Camp Bluetooth stack did not become healthy after removal.'
    }
    if (Test-TestSigningActive) {
        throw 'Windows Test Mode is still active after the removal restart.'
    }

    $remainingHfpDevices = @(Get-HfpRootDevices)
    $remainingUartPackages = @(Get-UartPackages)
    $remainingHfpPackages = @(Get-HfpPackages)
    $uartService = Get-DriverService 'UartH4Probe'
    $hfpService = Get-DriverService 'BthHfpAudio'
    if ($remainingHfpDevices.Count -ne 0 -or
        $remainingUartPackages.Count -ne 0 -or
        $remainingHfpPackages.Count -ne 0 -or
        $uartService -or $hfpService) {
        throw "Removal verification found leftovers: HFP devices=$($remainingHfpDevices.Count), UART packages=$($remainingUartPackages.Count), HFP packages=$($remainingHfpPackages.Count), UART service=$([bool]$uartService), HFP service=$([bool]$hfpService)."
    }

    Remove-ReleaseCertificate
    Save-InstallerState -Phase 'Uninstalled' -Message 'The original Boot Camp Bluetooth configuration was restored.' | Out-Null
    Unregister-ResumeTask
    Unregister-ScheduledTask -TaskName $uartRecoveryTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Send-Protocol -Kind 'PROGRESS' -Value 100
    Send-Protocol -Kind 'STATUS' -Value 'The original Windows Bluetooth configuration has been restored.'
    Send-Result -Kind 'Uninstalled' -Message 'Drivers, root device, test certificate, Test Mode, and setup tasks were removed. Setup files will be deleted after this window closes.'
    Write-InstallerLog 'Uninstallation completed and verified.'
    Start-PostExitCleanup
}

function Inspect-Installation {
    Assert-PayloadIntegrity
    $status = Get-InstallStatus
    Write-StatusSummary $status
    Write-ReadinessChecklist $status
    if ($status.Model -ne $expectedModel) {
        Send-Result -Kind 'Blocked' -Message "Unsupported computer: $($status.Model). This package is restricted to $expectedModel."
        return
    }
    if (-not $status.BaseHealthy) {
        $blockedKind = if ($status.AnyInstalled) { 'BlockedInstalled' } else { 'Blocked' }
        $baseMessage = "Required Apple Boot Camp Bluetooth drivers are missing or unhealthy: UART=$($status.UartStatus), parent=$($status.ParentStatus), radio=$($status.RadioStatus). Install or reinstall Apple Boot Camp Support Software, restart Windows, and run this setup again."
        if ($status.AnyInstalled) {
            $baseMessage += ' Existing Bluetooth Mic Mac components can still be removed with Uninstall / restore Windows.'
        }
        Send-Result -Kind $blockedKind -Message $baseMessage
        return
    }
    if ($status.Complete -and $status.TestSigningActive) {
        Send-Protocol -Kind 'PROGRESS' -Value 100
        Send-Result -Kind 'AlreadyInstalled' -Message 'Everything required is already installed, active, and at the expected version.'
        return
    }
    if (-not $status.TestSigningActive) {
        $secureBoot = $status.SecureBootState
        if ($secureBoot -eq 'Enabled') {
            $blockedKind = if ($status.AnyInstalled) { 'BlockedInstalled' } else { 'Blocked' }
            Send-Result -Kind $blockedKind -Message 'Secure Boot is enabled; disable it in firmware before using self-signed drivers. Installed project components can still be removed.'
            return
        }
        $testModeKind = if ($status.AnyInstalled) { 'NeedsTestModeRepair' } else { 'NeedsTestMode' }
        Send-Result -Kind $testModeKind -Message 'Windows Test Mode is not active. Setup can enable it and resume automatically after restart.'
        return
    }
    $kind = if ($status.UartServiceState -ne 'Missing' -or $status.HfpDeviceCount -gt 0) { 'ReadyRepair' } else { 'Ready' }
    Send-Result -Kind $kind -Message 'The computer is compatible; missing or older components will be installed automatically.'
}

try {
    Assert-Administrator
    New-Item -ItemType Directory -Path $programRoot -Force | Out-Null
    Write-InstallerLog "Bluetooth Mic Mac installer $installerVersion started: mode=$Mode"

    switch ($Mode) {
        'Inspect' {
            Send-Protocol -Kind 'PROGRESS' -Value 5
            Send-Protocol -Kind 'STATUS' -Value 'Checking the computer and installed components...'
            Inspect-Installation
        }

        'Start' {
            Assert-PayloadIntegrity
            $status = Get-InstallStatus
            Write-StatusSummary $status
            Write-ReadinessChecklist $status
            Assert-CompatibleTarget $status
            if ($status.Complete -and $status.TestSigningActive) {
                Complete-Installation
                break
            }
            Save-InstallerState -Phase 'Working' -Message 'The user started setup.' -RebootCount 0 | Out-Null
            Register-ResumeTask
            if (-not $status.TestSigningActive) {
                if (-not $AllowTestSigning) {
                    throw 'Enabling Test Mode was not confirmed.'
                }
                Enable-TestSigningAndReboot
                break
            }
            Continue-Installation
        }

        'Resume' {
            Assert-PayloadIntegrity
            $state = Read-InstallerState
            if (-not $state) {
                throw 'The saved state for the in-progress setup is missing.'
            }
            if ($state.Phase -eq 'Failed') {
                Unregister-ResumeTask
                Send-Result -Kind 'Error' -Message ([string]$state.LastError)
                break
            }
            Send-Protocol -Kind 'PROGRESS' -Value 30
            if ($state.Phase -eq 'AwaitingUninstallBoot') {
                Finish-Uninstallation
            } else {
                Continue-Installation
            }
        }

        'Uninstall' {
            Assert-PayloadIntegrity
            Begin-Uninstallation
        }
    }
}
catch {
    $message = ConvertTo-OneLine $_.Exception.Message
    Write-InstallerLog "ERROR: $message"
    if ($Mode -ne 'Inspect') {
        try { Save-InstallerState -Phase 'Failed' -Message 'Setup stopped safely.' -ErrorMessage $message | Out-Null } catch {}
        Unregister-ResumeTask
    }
    Send-Protocol -Kind 'STATUS' -Value 'Setup stopped safely.'
    Send-Result -Kind 'Error' -Message "$message Log: $logPath"
    exit 1
}
