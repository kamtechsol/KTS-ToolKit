@echo off
REM KamTech Solutions - KTS Toolkit one-click installer bootstrap
REM Double-click this file. It elevates to admin and runs Install-KTSDiagTool.ps1.

net session >nul 2>&1
if %errorLevel% == 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KTSDiagTool.ps1"
) else (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process cmd -ArgumentList '/c cd /d \"%~dp0\" && powershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0Install-KTSDiagTool.ps1\" && pause' -Verb RunAs"
)
