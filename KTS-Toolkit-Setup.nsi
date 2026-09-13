; ==============================================================================
; KTS-Toolkit-Setup.nsi
; KamTech Solutions - compiled Windows installer for KTS Toolkit
;
; Produces a single, real Windows executable (KTS-Toolkit-Setup.exe) that:
;   - Prompts for admin elevation (UAC) on launch
;   - Extracts all tool files to Program Files\KamTech\DiagTool
;   - Runs Install-KTSDiagTool.ps1 to register scheduled tasks (boot check,
;     watchdog, weekly deep scan), Start Menu shortcuts, and the KTS Toolkit
;     GUI launcher
;   - Registers a normal Add/Remove Programs entry with its own uninstaller
;
; Built with makensis (NSIS - Nullsoft Scriptable Install System):
;   makensis KTS-Toolkit-Setup.nsi
; ==============================================================================

!define PRODUCT_NAME      "KTS Toolkit"
!define PRODUCT_VERSION   "1.0.0"
!define PRODUCT_PUBLISHER "KamTech Solutions"
!define PRODUCT_DIR_REGKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\KTSToolkit"

Name "${PRODUCT_NAME}"
OutFile "KTS-Toolkit-Setup.exe"
InstallDir "$PROGRAMFILES64\KamTech\DiagTool"
RequestExecutionLevel admin
ShowInstDetails show
ShowUnInstDetails show
BrandingText "${PRODUCT_PUBLISHER}"

!include "MUI2.nsh"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_LICENSE "LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "KTS Toolkit (required)" SEC01
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "KTS-DiagTool.ps1"
  File "KTS-Toolkit-GUI.ps1"
  File "KTSWatchdog.ps1"
  File "Install-KTSDiagTool.ps1"
  File "Uninstall-KTSDiagTool.ps1"
  File "Build-KTSToolkitExe.ps1"
  File "README.md"
  File "LICENSE"

  DetailPrint "Registering scheduled tasks, watchdog, and shortcuts..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-KTSDiagTool.ps1" -InstallPath "$INSTDIR" -SkipRegistryEntry'
  Pop $0
  DetailPrint "Install-KTSDiagTool.ps1 exit code: $0"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "DisplayName"     "${PRODUCT_NAME} (${PRODUCT_PUBLISHER})"
  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "UninstallString" "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "DisplayVersion"  "${PRODUCT_VERSION}"
  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "Publisher"       "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "${PRODUCT_DIR_REGKEY}" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKLM "${PRODUCT_DIR_REGKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${PRODUCT_DIR_REGKEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  DetailPrint "Removing scheduled tasks, shortcuts, and watchdog..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Uninstall-KTSDiagTool.ps1" -InstallPath "$INSTDIR"'
  Pop $0

  Delete "$INSTDIR\KTS-DiagTool.ps1"
  Delete "$INSTDIR\KTS-Toolkit-GUI.ps1"
  Delete "$INSTDIR\KTS-Toolkit.exe"
  Delete "$INSTDIR\KTSWatchdog.ps1"
  Delete "$INSTDIR\Install-KTSDiagTool.ps1"
  Delete "$INSTDIR\Uninstall-KTSDiagTool.ps1"
  Delete "$INSTDIR\Build-KTSToolkitExe.ps1"
  Delete "$INSTDIR\README.md"
  Delete "$INSTDIR\LICENSE"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  RMDir "$PROGRAMFILES64\KamTech"

  DeleteRegKey HKLM "${PRODUCT_DIR_REGKEY}"
SectionEnd
