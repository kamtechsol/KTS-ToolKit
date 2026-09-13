<#
================================================================================
 Build-KTSToolkitExe.ps1
 KamTech Solutions - compiles KTS-Toolkit-GUI.ps1 into a standalone .exe

 Uses the ps2exe PowerShell module (MIT licensed, from the PowerShell
 Gallery) to wrap the GUI script into a real Windows executable:
   - No console window (pure GUI)
   - Embeds an admin-required manifest (so double-clicking the exe prompts
     UAC automatically - needed for NIC power settings, event logs, and
     the recovery-menu reboot)
   - Sets file version/company/product metadata to KamTech Solutions

 Run this ONCE, on a Windows machine with internet access, from the folder
 containing KTS-Toolkit-GUI.ps1 and KTS-DiagTool.ps1:

   powershell -ExecutionPolicy Bypass -File .\Build-KTSToolkitExe.ps1

 Output: KTS-Toolkit.exe, in the same folder. Ship that folder (the exe
 plus KTS-DiagTool.ps1, which it calls) to the target machine, or feed it
 into Install-KTSDiagTool.ps1 which will pick up the exe automatically if
 present.
================================================================================
#>

$ErrorActionPreference = 'Stop'
$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuiScript = Join-Path $SourceDir 'KTS-Toolkit-GUI.ps1'
$OutExe    = Join-Path $SourceDir 'KTS-Toolkit.exe'

if (-not (Test-Path $GuiScript)) {
    throw "KTS-Toolkit-GUI.ps1 not found in $SourceDir. Run this from the folder containing it."
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
    -inputFile   $GuiScript `
    -outputFile  $OutExe `
    -noConsole `
    -requireAdmin `
    -title       'KTS Toolkit' `
    -company     'KamTech Solutions' `
    -product     'KTS Toolkit' `
    -version     '1.0.0.0' `
    -description 'KamTech Solutions hardware diagnostic & recovery toolkit'

if (Test-Path $OutExe) {
    Write-Host "`nBuild complete: $OutExe" -ForegroundColor Green
    Write-Host 'Ship this .exe alongside KTS-DiagTool.ps1 (same folder) - the exe calls it as a subprocess for every test.'
} else {
    throw 'Build did not produce an output file - check the ps2exe errors above.'
}
