#Requires -RunAsAdministrator
<#
================================================================================
 Install-KTSDiagTool.ps1
 KamTech Solutions - installer for KTS-DiagTool

 Installs KTS-DiagTool.ps1 + KTSWatchdog.ps1 as a Windows-resident utility
 scoped to the CURRENT user (the admin running this installer) - not SYSTEM,
 not all users:
   - Copies files to Program Files\KamTech\DiagTool (shared program files,
     needs admin to write - this part is unavoidable)
   - Registers 3 scheduled tasks under the current user account, set to run
     only while that user is logged on:
       * KTS Boot Check      - Quick mode, 2 min after this user logs on
       * KTS Watchdog        - every 5 min, auto-captures on a detected drop
       * KTS Weekly Deep Scan- Full mode, Sunday 02:00
   - Adds shortcuts to THIS user's Start Menu and Desktop (not All Users)
   - Registers a per-user (HKCU) Add/Remove Programs entry
   - Auto-launches the KTS Toolkit GUI as soon as install finishes, so
     there's immediate visible confirmation it worked

 Run from the folder containing KTS-DiagTool.ps1, KTSWatchdog.ps1, and
 Uninstall-KTSDiagTool.ps1:

   powershell -ExecutionPolicy Bypass -File .\Install-KTSDiagTool.ps1
================================================================================
#>

param(
    [string]$InstallPath = 'C:\Program Files\KamTech\DiagTool',
    [switch]$SkipWatchdog,
    [switch]$NoAutoLaunch,
    # Set by the compiled Setup.exe (NSIS), which registers its own
    # Add/Remove Programs entry and its own Uninstall.exe - so this script
    # shouldn't also write a separate uninstall registry key in that case.
    [switch]$SkipRegistryEntry
)

$ErrorActionPreference = 'Stop'
$SourceDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProgDataDir  = 'C:\ProgramData\KamTech'
$ReportsDir   = "$ProgDataDir\Reports"
$KTSVersion   = '1.0.0'

# Current user = whoever is running this elevated install (via UAC, their own
# token is still used - $env:USERNAME resolves to them, not to a different
# admin account), which is who every task/shortcut below gets scoped to.
$CurrentUser    = "$env:USERDOMAIN\$env:USERNAME"
$StartMenuDir   = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\KamTech Solutions'
$DesktopDir     = [Environment]::GetFolderPath('Desktop')

Write-Host "== KamTech Solutions - KTS-DiagTool installer v$KTSVersion ==" -ForegroundColor Cyan
Write-Host "Installing for current user: $CurrentUser"

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

$diagScript     = Join-Path $InstallPath 'KTS-DiagTool.ps1'
$watchdogScript = Join-Path $InstallPath 'KTSWatchdog.ps1'
$toolkitGui     = Join-Path $InstallPath 'KTS-Toolkit-GUI.ps1'
$toolkitExe     = Join-Path $InstallPath 'KTS-Toolkit.exe'

# ------------------------------------------------------------------------------
# 2. Scheduled tasks - current user only, only fire while that user is logged on
# ------------------------------------------------------------------------------
$principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

function Register-KTSTask {
    param($Name, $Action, $Trigger)
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    }
    Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $Trigger `
        -Principal $principal -Settings $settings -Description 'KamTech Solutions diagnostic tool' | Out-Null
    Write-Host "Registered scheduled task: $Name (user: $CurrentUser)"
}

# Boot check - Quick mode, 2 min after THIS user logs on
$bootAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$diagScript`" -Mode Quick"
$bootTrigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$bootTrigger.Delay = 'PT2M'
Register-KTSTask -Name 'KTS Boot Check' -Action $bootAction -Trigger $bootTrigger

# Weekly deep scan - Full mode, Sunday 02:00 (only runs if this user is logged on then)
$weeklyAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$diagScript`" -Mode Full -NetworkMonitorMinutes 15 -StressDurationMinutes 10"
$weeklyTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2:00AM
Register-KTSTask -Name 'KTS Weekly Deep Scan' -Action $weeklyAction -Trigger $weeklyTrigger

# Resident watchdog - every 5 minutes while this user is logged on
if (-not $SkipWatchdog) {
    $wdAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdogScript`""
    $wdTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
    Register-KTSTask -Name 'KTS Watchdog' -Action $wdAction -Trigger $wdTrigger
} else {
    Write-Host 'Skipping watchdog task (-SkipWatchdog specified).'
}

# ------------------------------------------------------------------------------
# 3. Shortcuts - THIS user's Start Menu AND Desktop (not All Users)
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null
$wsh = New-Object -ComObject WScript.Shell

function New-KTSShortcut {
    param($Folder, $Name, $TargetPath, $TargetArgs, $IconLocation)
    $sc = $wsh.CreateShortcut((Join-Path $Folder "$Name.lnk"))
    $sc.TargetPath = $TargetPath
    $sc.Arguments  = $TargetArgs
    $sc.WorkingDirectory = $InstallPath
    $sc.IconLocation = $IconLocation
    $sc.Save()
}

New-KTSShortcut -Folder $StartMenuDir -Name 'Run Quick Check' -TargetPath 'powershell.exe' `
    -TargetArgs "-ExecutionPolicy Bypass -NoExit -File `"$diagScript`" -Mode Quick" -IconLocation 'powershell.exe,0'
New-KTSShortcut -Folder $StartMenuDir -Name 'Run Full Diagnostic' -TargetPath 'powershell.exe' `
    -TargetArgs "-ExecutionPolicy Bypass -NoExit -File `"$diagScript`" -Mode Full" -IconLocation 'powershell.exe,0'
New-KTSShortcut -Folder $StartMenuDir -Name 'Open Reports Folder' -TargetPath 'powershell.exe' `
    -TargetArgs "-Command `"Invoke-Item '$ReportsDir'`"" -IconLocation 'powershell.exe,0'
New-KTSShortcut -Folder $StartMenuDir -Name 'Uninstall' -TargetPath 'powershell.exe' `
    -TargetArgs "-ExecutionPolicy Bypass -File `"$InstallPath\Uninstall-KTSDiagTool.ps1`"" -IconLocation 'powershell.exe,0'

# KTS Toolkit launcher: prefer the compiled .exe (no console window, double-
# clickable, UAC-prompts itself) - fall back to launching the GUI script
# directly through PowerShell if the exe wasn't built yet. Placed in BOTH
# the Start Menu and the Desktop.
if ($hasExe) {
    $toolkitTarget = $toolkitExe
    $toolkitArgs   = ''
    $toolkitIcon   = $toolkitExe
} else {
    $toolkitTarget = 'powershell.exe'
    $toolkitArgs   = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$toolkitGui`""
    $toolkitIcon   = 'powershell.exe,0'
}
New-KTSShortcut -Folder $StartMenuDir -Name 'KTS Toolkit' -TargetPath $toolkitTarget -TargetArgs $toolkitArgs -IconLocation $toolkitIcon
New-KTSShortcut -Folder $DesktopDir   -Name 'KTS Toolkit' -TargetPath $toolkitTarget -TargetArgs $toolkitArgs -IconLocation $toolkitIcon

Write-Host "Created Start Menu shortcuts under 'KamTech Solutions' for $CurrentUser"
Write-Host "Created Desktop shortcut: KTS Toolkit"
if (-not $hasExe) {
    Write-Host "NOTE: KTS-Toolkit.exe wasn't found next to the installer - 'KTS Toolkit' currently launches the GUI via PowerShell. Run Build-KTSToolkitExe.ps1 and re-run the installer to switch it to the compiled .exe." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 4. Add/Remove Programs entry - per-user (HKCU), skipped when the compiled
#    Setup.exe installed this (it registers its own machine-wide entry).
# ------------------------------------------------------------------------------
if (-not $SkipRegistryEntry) {
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\KTSDiagTool'
    New-Item -Path $uninstallKey -Force | Out-Null
    Set-ItemProperty -Path $uninstallKey -Name 'DisplayName'     -Value 'KTS-DiagTool (KamTech Solutions)'
    Set-ItemProperty -Path $uninstallKey -Name 'DisplayVersion'  -Value $KTSVersion
    Set-ItemProperty -Path $uninstallKey -Name 'Publisher'       -Value 'KamTech Solutions'
    Set-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $InstallPath
    Set-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value "powershell.exe -ExecutionPolicy Bypass -File `"$InstallPath\Uninstall-KTSDiagTool.ps1`""
    Set-ItemProperty -Path $uninstallKey -Name 'NoModify'        -Value 1 -Type DWord
    Set-ItemProperty -Path $uninstallKey -Name 'NoRepair'        -Value 1 -Type DWord
    Write-Host 'Registered per-user Add/Remove Programs entry.'
} else {
    Write-Host 'Skipping Add/Remove Programs entry (owned by Setup.exe).'
}

Write-Host "`n== Install complete ==" -ForegroundColor Green
Write-Host "Tool:      $InstallPath"
Write-Host "Reports:   $ReportsDir"
Write-Host "User:      $CurrentUser (all scheduled tasks/shortcuts are scoped to this account only)"
Write-Host "Watchdog:  $(if ($SkipWatchdog) { 'not installed' } else { 'every 5 min while logged in, auto-captures on drop' })"

# ------------------------------------------------------------------------------
# 5. Auto-launch the toolkit right now, so install success is immediately visible
# ------------------------------------------------------------------------------
if (-not $NoAutoLaunch) {
    Write-Host 'Launching KTS Toolkit...'
    try {
        Start-Process -FilePath $toolkitTarget -ArgumentList $toolkitArgs
    } catch {
        Write-Host "Could not auto-launch the toolkit: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Launch it manually from the Desktop or Start Menu shortcut 'KTS Toolkit'."
    }
}
