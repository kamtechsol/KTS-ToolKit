#Requires -RunAsAdministrator
<#
================================================================================
 Uninstall-KTSDiagTool.ps1
 KamTech Solutions - removes the KTS-DiagTool installation

 Removes scheduled tasks, Start Menu shortcuts, and the Add/Remove Programs
 entry. Reports already generated are kept by default (pass -PurgeReports
 to delete them too).
================================================================================
#>

param(
    [string]$InstallPath = 'C:\Program Files\KamTech\DiagTool',
    [switch]$PurgeReports
)

$ErrorActionPreference = 'SilentlyContinue'
Write-Host '== KamTech Solutions - KTS-DiagTool uninstaller ==' -ForegroundColor Cyan

foreach ($task in @('KTS Boot Check','KTS Weekly Deep Scan','KTS Watchdog')) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false
        Write-Host "Removed scheduled task: $task"
    }
}

$startMenuDir = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\KamTech Solutions"
if (Test-Path $startMenuDir) {
    Remove-Item $startMenuDir -Recurse -Force
    Write-Host 'Removed Start Menu shortcuts.'
}

Remove-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\KTSDiagTool' -Force
Write-Host 'Removed Add/Remove Programs entry.'

if ($PurgeReports) {
    Remove-Item 'C:\ProgramData\KamTech\Reports' -Recurse -Force
    Remove-Item 'C:\ProgramData\KamTech\watchdog.log' -Force
    Remove-Item 'C:\ProgramData\KamTech\watchdog.lock' -Force
    Write-Host 'Purged report history and watchdog log.'
} else {
    Write-Host 'Report history kept at C:\ProgramData\KamTech\Reports (use -PurgeReports to delete it too).'
}

# Remove the install directory last, since this script is running from inside it.
# Schedule a delayed self-cleanup via a detached process so the file lock releases first.
Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$InstallPath`"" -WindowStyle Hidden

Write-Host "`nUninstall complete." -ForegroundColor Green
