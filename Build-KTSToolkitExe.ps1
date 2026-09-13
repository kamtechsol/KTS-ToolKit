<#
================================================================================
 Build-KTSToolkitExe.ps1
 KamTech Solutions - compiles KTS-Toolkit.ps1 into a standalone .exe

 Uses the ps2exe PowerShell module (MIT licensed, from the PowerShell
 Gallery) to wrap the WHOLE tool - engine and GUI together - into a real
 Windows executable:
   - No console window (pure GUI)
   - Embeds an admin-required manifest (so double-clicking the exe prompts
     UAC automatically - needed for NIC power settings, event logs, and
     the recovery-menu reboot)
   - Sets file version/company/product metadata to KamTech Solutions

 The result is a single, self-contained application - no separate script
 files to call at runtime, no child powershell.exe processes for any
 action. Every diagnostic/stress test runs on an in-process background
 thread inside this one exe.

 Run this ONCE, on a Windows machine with internet access, from the folder
 containing KTS-Toolkit.ps1:

   powershell -ExecutionPolicy Bypass -File .\Build-KTSToolkitExe.ps1

 Output: KTS-Toolkit.exe, in the same folder. Feed it into
 Install-KTSDiagTool.ps1 (in the same folder) which will pick it up
 automatically and use it in place of the raw script.
================================================================================
#>

$ErrorActionPreference = 'Stop'
$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppScript  = Join-Path $SourceDir 'KTS-Toolkit.ps1'
$OutExe     = Join-Path $SourceDir 'KTS-Toolkit.exe'

if (-not (Test-Path $AppScript)) {
    throw "KTS-Toolkit.ps1 not found in $SourceDir. Run this from the folder containing it."
}

Write-Host '== KamTech Solutions - KTS-Toolkit.exe builder ==' -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'ps2exe module not found - installing from PowerShell Gallery (needs internet)...'
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe -Force

Invoke-ps2exe `
    -inputFile   $AppScript `
    -outputFile  $OutExe `
    -noConsole `
    -requireAdmin `
    -title       'KTS Toolkit' `
    -company     'KamTech Solutions' `
    -product     'KTS Toolkit' `
    -version     '1.1.0.0' `
    -description 'KamTech Solutions hardware diagnostic, stress test & recovery toolkit'

if (Test-Path $OutExe) {
    Write-Host "`nBuild complete: $OutExe" -ForegroundColor Green
    Write-Host 'This is now a fully self-contained application - no other script files needed to run it.'
} else {
    throw 'Build did not produce an output file - check the ps2exe errors above.'
}
