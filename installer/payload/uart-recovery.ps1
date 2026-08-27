$ErrorActionPreference = 'Continue'

$taskName = 'Bluetooth Mic Mac UART H4 Recovery'
$probeStateRoot = Join-Path $env:ProgramData 'BluetoothMicMac-UartH4Probe'
$probeStatePath = Join-Path $probeStateRoot 'state.json'
$recoveryLogPath = Join-Path $probeStateRoot 'recovery.log'
$installerRoot = Join-Path $env:ProgramData 'BluetoothMicMacInstaller'
$installerStatePath = Join-Path $installerRoot 'state.json'
$failureMarker = Join-Path $installerRoot 'uart-recovery-failed.txt'
$uartHardwareId = 'PCI\VEN_8086&DEV_A328&SUBSYS_72708086'

function Write-RecoveryLog {
    param([string] $Message)
    New-Item -ItemType Directory -Path $probeStateRoot -Force | Out-Null
    Add-Content -LiteralPath $recoveryLogPath -Value ('{0:u} {1}' -f (Get-Date), $Message) -Encoding UTF8
}

function Find-UniquePnpInstance {
    param([Parameter(Mandatory)][string] $InstancePrefix)
    $matches = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -like "$InstancePrefix*"
    })
    if ($matches.Count -eq 1) { return [string]$matches[0].InstanceId }
    return ''
}

function Get-TargetInstances {
    $recordedUart = ''
    if (Test-Path -LiteralPath $probeStatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $probeStatePath -Raw | ConvertFrom-Json
            if ([string]$state.TargetInstance -like "$uartHardwareId*") {
                $recordedUart = [string]$state.TargetInstance
            }
        }
        catch {}
    }
    if (-not $recordedUart) {
        $recordedUart = Find-UniquePnpInstance -InstancePrefix $uartHardwareId
    }
    [pscustomobject]@{
        Uart = $recordedUart
        Parent = Find-UniquePnpInstance -InstancePrefix 'ACPI\BCM2E7C\'
        Radio = Find-UniquePnpInstance -InstancePrefix 'BCMBTBUS\BLUETOOTH\'
    }
}

function Get-TargetHealth {
    $instances = Get-TargetInstances
    $uart = if ($instances.Uart) { Get-PnpDevice -InstanceId $instances.Uart -ErrorAction SilentlyContinue }
    $parent = if ($instances.Parent) { Get-PnpDevice -InstanceId $instances.Parent -ErrorAction SilentlyContinue }
    $radio = if ($instances.Radio) { Get-PnpDevice -InstanceId $instances.Radio -ErrorAction SilentlyContinue }
    $filter = Get-CimInstance Win32_SystemDriver -Filter "Name='UartH4Probe'" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Healthy =
            $uart.Status -eq 'OK' -and
            $parent.Status -eq 'OK' -and
            $radio.Status -eq 'OK' -and
            $filter -and $filter.State -eq 'Running'
        Uart = "$($uart.Status)/$($uart.Problem)"
        Parent = "$($parent.Status)/$($parent.Problem)"
        Radio = "$($radio.Status)/$($radio.Problem)"
        Filter = if ($filter) { [string]$filter.State } else { 'Missing' }
    }
}

function Set-InstallerFailure {
    param([string] $Message)
    New-Item -ItemType Directory -Path $installerRoot -Force | Out-Null
    Set-Content -LiteralPath $failureMarker -Value $Message -Encoding UTF8
    if (Test-Path -LiteralPath $installerStatePath -PathType Leaf) {
        try {
            $old = Get-Content -LiteralPath $installerStatePath -Raw | ConvertFrom-Json
            [ordered]@{
                InstallerVersion = [string]$old.InstallerVersion
                Phase = 'Failed'
                ResumeUser = [string]$old.ResumeUser
                ResumeUserSid = [string]$old.ResumeUserSid
                RebootCount = [int]$old.RebootCount
                BootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
                UpdatedAt = (Get-Date).ToString('o')
                LastMessage = 'UART recovery guard restored the original Bluetooth stack.'
                LastError = $Message
            } | ConvertTo-Json | Set-Content -LiteralPath $installerStatePath -Encoding UTF8
        }
        catch {
            Write-RecoveryLog "Could not update installer state: $($_.Exception.Message)"
        }
    }
}

for ($attempt = 0; $attempt -lt 18; ++$attempt) {
    $health = Get-TargetHealth
    if ($health.Healthy) {
        Write-RecoveryLog "Target healthy after startup. UART=$($health.Uart), parent=$($health.Parent), radio=$($health.Radio), filter=$($health.Filter)."
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        exit 0
    }
    Start-Sleep -Seconds 5
}

$health = Get-TargetHealth
$failure = "Target remained unhealthy: UART=$($health.Uart), parent=$($health.Parent), radio=$($health.Radio), filter=$($health.Filter)."
Write-RecoveryLog $failure
$removedExactPackage = $false

if (Test-Path -LiteralPath $probeStatePath -PathType Leaf) {
    try {
        $probeState = Get-Content -LiteralPath $probeStatePath -Raw | ConvertFrom-Json
        $publishedInf = [string]$probeState.PublishedInf
        if ($publishedInf -match '^oem\d+\.inf$') {
            $driversXmlText = (& pnputil.exe /enum-drivers /class Extension /format xml 2>$null) -join "`n"
            [xml]$driversXml = $driversXmlText
            $matchingPackage = @($driversXml.PnpUtil.Driver) | Where-Object {
                $_.DriverName -ieq $publishedInf -and
                $_.OriginalName -ieq 'UartH4Probe.inf' -and
                $_.ProviderName -ieq 'Local UART H4 Research'
            } | Select-Object -First 1
            if ($matchingPackage) {
                Write-RecoveryLog "Removing exact UART H4 package $publishedInf."
                & pnputil.exe /delete-driver $publishedInf /uninstall /force |
                    ForEach-Object { Write-RecoveryLog ([string]$_) }
                if ($LASTEXITCODE -eq 0) { $removedExactPackage = $true }
            } else {
                Write-RecoveryLog "Refused removal because $publishedInf did not match the recorded package identity."
            }
        }
    }
    catch {
        Write-RecoveryLog "Recovery package lookup failed: $($_.Exception.Message)"
    }
}

Set-InstallerFailure -Message $failure
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
if ($removedExactPackage) {
    Write-RecoveryLog 'Scheduling one recovery restart after removing the exact failed filter package.'
    & shutdown.exe /r /t 15 /d p:4:1 /c 'Bluetooth Mic Mac recovery restored the original UART driver.'
} else {
    Write-RecoveryLog 'No verified probe package was removed; refusing an automatic recovery reboot.'
}
exit 1
