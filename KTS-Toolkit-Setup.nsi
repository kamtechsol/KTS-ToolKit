; ==============================================================================
; KTS-Toolkit-Setup.nsi
; KamTech Solutions - compiled Windows installer for KTS Toolkit
;
; Produces a single, real Windows executable (KTS-Toolkit-Setup.exe) that:
;   - Prompts for admin elevation (UAC) on launch
;   - Extracts the tool to Program Files\KamTech\DiagTool
;   - Runs Install-KTSDiagTool.ps1 to register scheduled tasks (boot check,
;     watchdog, weekly deep scan) and shortcuts for the current user
;   - Registers a normal Add/Remove Programs entry with its own uninstaller
;
; The installed tool itself (KTS-Toolkit.ps1, or KTS-Toolkit.exe if you ran
; Build-KTSToolkitExe.ps1 first) is ONE application - engine and GUI in a
; single process, no separate script files invoked at runtime.
;
; Built with makensis (NSIS - Nullsoft Scriptable Install System):
;   makensis KTS-Toolkit-Setup.nsi
; ==============================================================================

!define PRODUCT_NAME      "KTS Toolkit"
!define PRODUCT_VERSION   "1.1.0"
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
  File "KTS-Toolkit.ps1"
  File "KTSWatchdog.ps1"
  File "Install-KTSDiagTool.ps1"
  File "Uninstall-KTSDiagTool.ps1"
  File "Build-KTSToolkitExe.ps1"
  File "README.md"
  File "LICENSE"
  ; Only bundled if Build-KTSToolkitExe.ps1 was run before makensis - not
  ; required, the tool runs fine as the raw .ps1 via the shortcuts below too.
  File /nonfatal "KTS-Toolkit.exe"

  DetailPrint "Registering scheduled tasks, watchdog, and shortcuts (current user)..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Install-KTSDiagTool.ps1" -InstallPath "$INSTDIR" -SkipRegistryEntry -NoAutoLaunch'
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

  ; Launch the app once setup finishes, so success is immediately visible -
  ; prefer the compiled exe if it was bundled, else fall back to the script.
  IfFileExists "$INSTDIR\KTS-Toolkit.exe" 0 UseScriptFallback
    Exec '"$INSTDIR\KTS-Toolkit.exe"'
    Goto LaunchDone
  UseScriptFallback:
    Exec 'powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\KTS-Toolkit.ps1"'
  LaunchDone:
SectionEnd

Section "Uninstall"
  DetailPrint "Removing scheduled tasks, shortcuts, and watchdog..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\Uninstall-KTSDiagTool.ps1" -InstallPath "$INSTDIR"'
  Pop $0

  Delete "$INSTDIR\KTS-Toolkit.ps1"
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
