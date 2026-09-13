#Requires -RunAsAdministrator
<#
================================================================================
 KTS-Toolkit-GUI.ps1
 KamTech Solutions - KTS Toolkit (graphical front-end)

 A WinForms UI over KTS-DiagTool.ps1: buttons to run individual system
 function tests, kick off the full diagnostic/stress suite, and reboot
 straight into the Windows Recovery Environment (Advanced Startup Options).

 This script IS the source for the compiled executable - see
 Build-KTSToolkitExe.ps1 to turn it into KTS-Toolkit.exe with ps2exe.
 It also runs directly with:
   powershell -ExecutionPolicy Bypass -File .\KTS-Toolkit-GUI.ps1
================================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$KTS_Version   = '1.0.0'
$InstallDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$DiagScript    = Join-Path $InstallDir 'KTS-DiagTool.ps1'
$ReportsRoot   = 'C:\ProgramData\KamTech\Reports'
$HostName      = $env:COMPUTERNAME
$NavyColor     = [System.Drawing.ColorTranslator]::FromHtml('#0B1F3A')
$PanelColor    = [System.Drawing.ColorTranslator]::FromHtml('#122a4d')
$RedColor      = [System.Drawing.ColorTranslator]::FromHtml('#B3122B')
$TextColor     = [System.Drawing.ColorTranslator]::FromHtml('#EAEEF5')
$MutedColor    = [System.Drawing.ColorTranslator]::FromHtml('#8894a8')

if (-not (Test-Path $DiagScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "KTS-DiagTool.ps1 not found next to this tool in:`n$InstallDir`n`nReinstall or place both files in the same folder.",
        'KTS Toolkit - missing component', 'OK', 'Error') | Out-Null
    exit 1
}

# ------------------------------------------------------------------------------
# Grab the serial number once, up front, for the persistent corner badge
# ------------------------------------------------------------------------------
function Get-KTSSerial {
    try {
        $bios  = Get-CimInstance Win32_BIOS
        $board = Get-CimInstance Win32_BaseBoard
        $s = $bios.SerialNumber
        if ([string]::IsNullOrWhiteSpace($s) -or $s -match 'To Be Filled|Default string|None|System Serial') {
            $s = $board.SerialNumber
        }
        if ([string]::IsNullOrWhiteSpace($s)) { return 'UNKNOWN' }
        return $s.Trim()
    } catch { return 'UNKNOWN' }
}
$SerialNumber = Get-KTSSerial

# ------------------------------------------------------------------------------
# Main form
# ------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "KTS Toolkit - KamTech Solutions (v$KTS_Version)"
$form.Size = New-Object System.Drawing.Size(880, 620)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $NavyColor
$form.ForeColor = $TextColor
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- Persistent serial number badge, pinned to the top-right corner ---
$badge = New-Object System.Windows.Forms.Label
$badge.Text = "SERIAL / SERVICE TAG`n$SerialNumber"
$badge.TextAlign = 'MiddleCenter'
$badge.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
$badge.ForeColor = $TextColor
$badge.BackColor = $PanelColor
$badge.BorderStyle = 'FixedSingle'
$badge.Size = New-Object System.Drawing.Size(220, 44)
$badge.Location = New-Object System.Drawing.Point(($form.ClientSize.Width - 232), 10)
$badge.Anchor = 'Top,Right'
$form.Controls.Add($badge)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "KAMTECH SOLUTIONS  //  KTS Toolkit"
$titleLabel.ForeColor = $RedColor
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$titleLabel.Location = New-Object System.Drawing.Point(16, 14)
$titleLabel.AutoSize = $true
$form.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.Text = "Host: $HostName"
$subLabel.ForeColor = $MutedColor
$subLabel.Location = New-Object System.Drawing.Point(16, 42)
$subLabel.AutoSize = $true
$form.Controls.Add($subLabel)

# --- Output/log panel ---
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#081428')
$logBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#8fd0ff')
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.Location = New-Object System.Drawing.Point(16, 340)
$logBox.Size = New-Object System.Drawing.Size(840, 220)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($logBox)

function Write-GuiLog {
    param([string]$Text)
    $ts = Get-Date -Format 'HH:mm:ss'
    $logBox.AppendText("[$ts] $Text`r`n")
}

# ------------------------------------------------------------------------------
# Runs KTS-DiagTool.ps1 as a background process and streams its output into
# the log box, without freezing the UI.
# ------------------------------------------------------------------------------
function Invoke-KTSDiagAsync {
    param([string]$Arguments, [string]$ActionName)

    Write-GuiLog "Starting: $ActionName"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-ExecutionPolicy Bypass -File `"$DiagScript`" $Arguments"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    $outHandler = {
        if ($EventArgs.Data) {
            $form.Invoke([Action]{ Write-GuiLog $EventArgs.Data })
        }
    }
    Register-ObjectEvent -InputObject $proc -EventName 'OutputDataReceived' -Action $outHandler | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived'  -Action $outHandler | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName 'Exited' -Action {
        $form.Invoke([Action]{ Write-GuiLog "Finished: $($Event.MessageData)" })
    } -MessageData $ActionName | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
}

function Confirm-Action {
    param([string]$Message, [string]$Title)
    $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'YesNo', 'Warning')
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

# ------------------------------------------------------------------------------
# Button factory
# ------------------------------------------------------------------------------
function New-KTSButton {
    param($Text, $X, $Y, $Width = 190, $Height = 34)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($Width, $Height)
    $btn.BackColor = $PanelColor
    $btn.ForeColor = $TextColor
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml('#1e3a63')
    $form.Controls.Add($btn)
    return $btn
}

function New-KTSGroupLabel {
    param($Text, $X, $Y)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.ForeColor = $MutedColor
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Bold)
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.AutoSize = $true
    $form.Controls.Add($lbl)
}

# --- Column 1: Diagnostics ---
New-KTSGroupLabel 'DIAGNOSTICS' 16 76
$btnQuick = New-KTSButton 'Run Quick Check' 16 96
$btnFull  = New-KTSButton 'Run Full Diagnostic' 16 136
$btnReports = New-KTSButton 'Open Reports Folder' 16 176
$btnLastReport = New-KTSButton 'Open Last Report' 16 216

$btnQuick.Add_Click({ Invoke-KTSDiagAsync '-Mode Quick' 'Quick Check' })
$btnFull.Add_Click({ Invoke-KTSDiagAsync '-Mode Full' 'Full Diagnostic' })
$btnReports.Add_Click({
    New-Item -ItemType Directory -Path $ReportsRoot -Force | Out-Null
    Invoke-Item $ReportsRoot
})
$btnLastReport.Add_Click({
    $hostDir = Join-Path $ReportsRoot $HostName
    if (Test-Path $hostDir) {
        $latest = Get-ChildItem $hostDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
        $reportFile = Join-Path $latest.FullName 'report.html'
        if (Test-Path $reportFile) { Invoke-Item $reportFile }
        else { Write-GuiLog 'No report.html found in the most recent run folder yet.' }
    } else {
        Write-GuiLog 'No reports found yet - run a check first.'
    }
})

# --- Column 2: Individual system function tests ---
New-KTSGroupLabel 'TEST INDIVIDUAL FUNCTIONS' 232 76
$durationLabel = New-Object System.Windows.Forms.Label
$durationLabel.Text = 'Duration (min):'
$durationLabel.ForeColor = $MutedColor
$durationLabel.Location = New-Object System.Drawing.Point(232, 96)
$durationLabel.AutoSize = $true
$form.Controls.Add($durationLabel)

$durationPicker = New-Object System.Windows.Forms.NumericUpDown
$durationPicker.Minimum = 1
$durationPicker.Maximum = 120
$durationPicker.Value = 5
$durationPicker.Location = New-Object System.Drawing.Point(340, 94)
$durationPicker.Size = New-Object System.Drawing.Size(60, 24)
$form.Controls.Add($durationPicker)

$btnCpu    = New-KTSButton 'Test CPU'        232 126
$btnMemory = New-KTSButton 'Test Memory'     232 166
$btnDisk   = New-KTSButton 'Test Disk'       232 206
$btnNic    = New-KTSButton 'Test NIC / Network' 232 246

$btnCpu.Add_Click({ Invoke-KTSDiagAsync "-Mode StressOnly -StressDurationMinutes $($durationPicker.Value) -StressComponents CPU" 'CPU Test' })
$btnMemory.Add_Click({ Invoke-KTSDiagAsync "-Mode StressOnly -StressDurationMinutes $($durationPicker.Value) -StressComponents Memory" 'Memory Test' })
$btnDisk.Add_Click({ Invoke-KTSDiagAsync "-Mode StressOnly -StressDurationMinutes $($durationPicker.Value) -StressComponents Disk" 'Disk Test' })
$btnNic.Add_Click({ Invoke-KTSDiagAsync "-Mode NetworkOnly -NetworkMonitorMinutes $($durationPicker.Value)" 'NIC / Network Test' })

# --- Column 3: System actions ---
New-KTSGroupLabel 'SYSTEM' 448 76
$btnDeviceMgr = New-KTSButton 'Open Device Manager' 448 96
$btnEventVwr  = New-KTSButton 'Open Event Viewer' 448 136
$btnNetAdapters = New-KTSButton 'Open Network Adapters' 448 176
$btnRestart   = New-KTSButton 'Restart Normally' 448 216

$btnDeviceMgr.Add_Click({ Start-Process devmgmt.msc })
$btnEventVwr.Add_Click({ Start-Process eventvwr.msc })
$btnNetAdapters.Add_Click({ Start-Process ncpa.cpl })
$btnRestart.Add_Click({
    if (Confirm-Action 'Restart the computer normally now?' 'Confirm restart') {
        Write-GuiLog 'Restarting normally...'
        Start-Process shutdown.exe -ArgumentList '/r','/t','5'
    }
})

# --- Recovery menu button, set apart and clearly marked ---
$btnRecovery = New-Object System.Windows.Forms.Button
$btnRecovery.Text = "Reboot to Recovery Menu (WinRE)"
$btnRecovery.Location = New-Object System.Drawing.Point(448, 264)
$btnRecovery.Size = New-Object System.Drawing.Size(220, 44)
$btnRecovery.BackColor = $RedColor
$btnRecovery.ForeColor = $TextColor
$btnRecovery.FlatStyle = 'Flat'
$btnRecovery.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRecovery)
$btnRecovery.Add_Click({
    $msg = "This immediately restarts the computer into the Windows Recovery Environment (Advanced Startup Options) - Safe Mode, System Restore, Startup Repair, Command Prompt, etc.`n`nSave any open work first. Continue?"
    if (Confirm-Action $msg 'Reboot to Recovery Menu') {
        Write-GuiLog 'Rebooting into Windows Recovery Environment...'
        # /o = boot to Advanced Startup Options (WinRE); /r = restart; /f = force close apps
        Start-Process shutdown.exe -ArgumentList '/r','/o','/f','/t','5'
    }
})

$recoveryNote = New-Object System.Windows.Forms.Label
$recoveryNote.Text = "Boots to Safe Mode / System Restore / Startup Repair menu"
$recoveryNote.ForeColor = $MutedColor
$recoveryNote.Font = New-Object System.Drawing.Font('Segoe UI', 7)
$recoveryNote.Location = New-Object System.Drawing.Point(448, 310)
$recoveryNote.Size = New-Object System.Drawing.Size(220, 26)
$form.Controls.Add($recoveryNote)

Write-GuiLog "KTS Toolkit v$KTS_Version ready. Host $HostName, serial $SerialNumber."
[System.Windows.Forms.Application]::Run($form)
