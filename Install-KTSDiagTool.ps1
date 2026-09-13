#Requires -RunAsAdministrator
<#
================================================================================
 Install-KTSDiagTool.ps1
 KamTech Solutions - installer for KTS-DiagTool

 Installs KTS-DiagTool.ps1 + KTSWatchdog.ps1 as a proper Windows-resident
 utility:
   - Copies files to Program Files\KamTech\DiagTool
   - Registers 3 scheduled tasks (SYSTEM):
       * KTS Boot Check      - Quick mode, 2 min after every boot
       * KTS Watchdog        - every 5 min, auto-captures on a detected drop
       * KTS Weekly Deep Scan- Full mode, Sunday 02:00
   - Adds Start Menu shortcuts (Run Quick Check, Run Full Diagnostic,
     Open Reports Folder, Uninstall)
   - Registers an Add/Remove Programs entry so it can be removed the normal
     way, in addition to Uninstall-KTSDiagTool.ps1

 Run from the folder containing KTS-DiagTool.ps1, KTSWatchdog.ps1, and
 Uninstall-KTSDiagTool.ps1:

   powershell -ExecutionPolicy Bypass -File .\Install-KTSDiagTool.ps1
================================================================================
#>

param(
    [string]$InstallPath = 'C:\Program Files\KamTech\DiagTool',
    [switch]$SkipWatchdog
)

$ErrorActionPreference = 'Stop'
$SourceDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProgDataDir = 'C:\ProgramData\KamTech'
$ReportsDir  = "$ProgDataDir\Reports"
$StartMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\KamTech Solutions"
$KTSVersion  = '1.0.0'

Write-Host "== KamTech Solutions - KTS-DiagTool installer v$KTSVersion ==" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Copy files
# ------------------------------------------------------------------------------
$required = @('KTS-DiagTool.ps1','KTSWatchdog.ps1','Uninstall-KTSDiagTool.ps1','KTS-Toolkit-GUI.ps1')
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $SourceDir $f))) {
        throw "Required file '$f' not found next to the installer in $SourceDir. Aborting."
    }
}

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
New-Item -ItemType Directory -Path $ReportsDir  -Force | Out-Null
foreach ($f in $required) {
    Copy-Item -Path (Join-Path $SourceDir $f) -Destination $InstallPath -Force
}
# KTS-Toolkit.exe is optional - only present if Build-KTSToolkitExe.ps1 was run first
$exeSource = Join-Path $SourceDir 'KTS-Toolkit.exe'
$hasExe = Test-Path $exeSource
if ($hasExe) {
    Copy-Item -Path $exeSource -Destination $InstallPath -Force
}
Write-Host "Copied tool files to $InstallPath"

# ------------------------------------------------------------------------------
# 2. Scheduled tasks (all run as SYSTEM so they work with no user logged on)
# ------------------------------------------------------------------------------
$diagScript     = Join-Path $InstallPath 'KTS-DiagTool.ps1'
$watchdogScript = Join-Path $InstallPath 'KTSWatchdog.ps1'
$principal      = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings       = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

function Register-KTSTask {
    param($Name, $Action, $Trigger)
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
    Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger `
        -Principal $principal -Settings $settings -Description 'KamTech Solutions diagnostic tool' | Out-Null
    Write-Host "Registered scheduled task: $Name"
}

# Boot check - Quick mode, 2 min after boot
$bootAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$diagScript`" -Mode Quick"
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$bootTrigger.Delay = 'PT2M'
Register-KTSTask -Name 'KTS Boot Check' -Action $bootAction -Trigger $bootTrigger

# Weekly deep scan - Full mode, Sunday 02:00
$weeklyAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$diagScript`" -Mode Full -NetworkMonitorMinutes 15 -StressDurationMinutes 10"
$weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2:00AM
Register-KTSTask -Name 'KTS Weekly Deep Scan' -Action $weeklyAction -Trigger $weeklyTrigger

# Resident watchdog - every 5 minutes
if (-not $SkipWatchdog) {
    $wdAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScript`""
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
    Register-KTSTask -Name 'KTS Watchdog' -Action $wdAction -Trigger $wdTrigger
} else {
    Write-Host 'Skipping watchdog task (-SkipWatchdog specified).'
}

# ------------------------------------------------------------------------------
# 3. Start Menu shortcuts
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null
$wsh = New-Object -ComObject WScript.Shell

function New-KTSShortcut {
    param($Name, $TargetArgs)
    $sc = $wsh.CreateShortcut((Join-Path $StartMenuDir "$Name.lnk"))
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments  = $TargetArgs
    $sc.WorkingDirectory = $InstallPath
    $sc.IconLocation = 'powershell.exe,0'
    $sc.Save()
}

New-KTSShortcut -Name 'Run Quick Check'      -TargetArgs "-ExecutionPolicy Bypass -NoExit -File `"$diagScript`" -Mode Quick"
New-KTSShortcut -Name 'Run Full Diagnostic'  -TargetArgs "-ExecutionPolicy Bypass -NoExit -File `"$diagScript`" -Mode Full"
New-KTSShortcut -Name 'Open Reports Folder'  -TargetArgs "-Command `"Invoke-Item '$ReportsDir'`""
New-KTSShortcut -Name 'Uninstall'            -TargetArgs "-ExecutionPolicy Bypass -File `"$InstallPath\Uninstall-KTSDiagTool.ps1`""

# KTS Toolkit launcher: prefer the compiled .exe (no console window, double-
# clickable, UAC-prompts itself) - fall back to launching the GUI script
# directly through PowerShell if the exe wasn't built yet.
$toolkitShortcut = $wsh.CreateShortcut((Join-Path $StartMenuDir 'KTS Toolkit.lnk'))
if ($hasExe) {
    $toolkitShortcut.TargetPath = Join-Path $InstallPath 'KTS-Toolkit.exe'
    $toolkitShortcut.Arguments = ''
} else {
    $toolkitShortcut.TargetPath = 'powershell.exe'
    $toolkitShortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $InstallPath 'KTS-Toolkit-GUI.ps1')`""
}
$toolkitShortcut.WorkingDirectory = $InstallPath
$toolkitShortcut.IconLocation = if ($hasExe) { (Join-Path $InstallPath 'KTS-Toolkit.exe') } else { 'powershell.exe,0' }
$toolkitShortcut.Save()

Write-Host "Created Start Menu shortcuts under 'KamTech Solutions'"
if (-not $hasExe) {
    Write-Host "NOTE: KTS-Toolkit.exe wasn't found next to the installer - 'KTS Toolkit' currently launches the GUI via PowerShell. Run Build-KTSToolkitExe.ps1 and re-run the installer to switch it to the compiled .exe." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 4. Add/Remove Programs entry
# ------------------------------------------------------------------------------
$uninstallKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KTSDiagTool'
New-Item -Path $uninstallKey -Force | Out-Null
Set-ItemProperty -Path $uninstallKey -Name 'DisplayName'     -Value 'KTS-DiagTool (KamTech Solutions)'
Set-ItemProperty -Path $uninstallKey -Name 'DisplayVersion'  -Value $KTSVersion
Set-ItemProperty -Path $uninstallKey -Name 'Publisher'       -Value 'KamTech Solutions'
Set-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $InstallPath
Set-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value "powershell.exe -ExecutionPolicy Bypass -File `"$InstallPath\Uninstall-KTSDiagTool.ps1`""
Set-ItemProperty -Path $uninstallKey -Name 'NoModify'        -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name 'NoRepair'        -Value 1 -Type DWord
Write-Host 'Registered Add/Remove Programs entry.'

Write-Host "`n== Install complete ==" -ForegroundColor Green
Write-Host "Tool:      $InstallPath"
Write-Host "Reports:   $ReportsDir"
Write-Host "Watchdog:  $(if ($SkipWatchdog) { 'not installed' } else { 'every 5 min, auto-captures on drop' })"
Write-Host "Run a first check now with:  Start Menu > KamTech Solutions > Run Quick Check"
