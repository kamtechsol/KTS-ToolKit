#Requires -RunAsAdministrator
<#
================================================================================
 KTSWatchdog.ps1
 KamTech Solutions - resident LAN watchdog

 Runs on a short interval (as a scheduled task, not a long-lived loop) and:
   - Checks primary NIC link status + quick ping loss
   - On the FIRST sign of trouble, launches the KTS Toolkit application
     itself (visibly, minimized) with -AutoRun NetworkOnly so the drop gets
     caught with detail even if nobody is watching the machine - this still
     opens only the ONE application, not a separate hidden script process
   - Writes a lightweight running log so patterns over days/weeks are visible
     without digging through full report folders

 Installed by Install-KTSDiagTool.ps1 as a scheduled task tied to the
 installing user's account, every 5 minutes while that user is logged on.
================================================================================
#>

param(
    [string]$PingTarget = '1.1.1.1',
    [int]$CaptureMinutesOnTrigger = 10,
    [int]$RearmMinutes = 30
)

$InstallDir    = 'C:\Program Files\KamTech\DiagTool'
$WatchdogLog   = 'C:\ProgramData\KamTech\watchdog.log'
$LockFile      = 'C:\ProgramData\KamTech\watchdog.lock'
$ToolkitExe    = Join-Path $InstallDir 'KTS-Toolkit.exe'
$ToolkitScript = Join-Path $InstallDir 'KTS-Toolkit.ps1'

function Write-WDLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $WatchdogLog -Value $line
}

New-Item -ItemType Directory -Path (Split-Path $WatchdogLog) -Force | Out-Null

# Don't stack captures: if a capture triggered recently, skip this tick.
if (Test-Path $LockFile) {
    $lockAge = (Get-Date) - (Get-Item $LockFile).LastWriteTime
    if ($lockAge.TotalMinutes -lt $RearmMinutes) {
        exit 0
    } else {
        Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
    }
}

$nic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
$linkOk = $null -ne $nic
$pingOk = $false
if ($linkOk) {
    $reply = Test-Connection -ComputerName $PingTarget -Count 2 -ErrorAction SilentlyContinue
    $pingOk = ($reply | Measure-Object).Count -gt 0
}

if (-not $linkOk -or -not $pingOk) {
    Write-WDLog "TROUBLE DETECTED - link=$linkOk ping=$pingOk. Launching KTS Toolkit for a ${CaptureMinutesOnTrigger}min capture."
    New-Item -ItemType File -Path $LockFile -Force | Out-Null

    if (Test-Path $ToolkitExe) {
        Start-Process -FilePath $ToolkitExe -ArgumentList "-AutoRun NetworkOnly -AutoRunMinutes $CaptureMinutesOnTrigger -StartMinimized"
    } elseif (Test-Path $ToolkitScript) {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList "-ExecutionPolicy Bypass -File `"$ToolkitScript`" -AutoRun NetworkOnly -AutoRunMinutes $CaptureMinutesOnTrigger -StartMinimized"
    } else {
        Write-WDLog "ERROR: KTS-Toolkit not found in $InstallDir - capture skipped."
    }
} else {
    Write-WDLog 'OK - link up, ping normal.'
}
