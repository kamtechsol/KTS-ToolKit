#Requires -RunAsAdministrator
<#
================================================================================
 KTS-DiagTool.ps1
 KamTech Solutions - Hardware Diagnostic & Stress Test Tool
 Version 1.0.0

 Purpose:
   General-purpose Windows hardware diagnostic + stress test utility, with a
   dedicated deep-dive network module built specifically to chase intermittent
   LAN dropouts (built and field-targeted against a Dell OptiPlex 9010 SFF,
   but works on any Windows 10/11 box).

 Modes:
   -Mode Quick        Inventory + NIC config snapshot + event log scan (~1 min)
   -Mode NetworkOnly   Quick checks + live connectivity/latency/error monitor
   -Mode StressOnly    CPU/RAM/Disk/NIC load test only
   -Mode Full          Everything: inventory, NIC deep-dive, event correlation,
                        network monitor, stress test, HTML report (default)

 Usage:
   powershell -ExecutionPolicy Bypass -File .\KTS-DiagTool.ps1 -Mode Full
   powershell -ExecutionPolicy Bypass -File .\KTS-DiagTool.ps1 -Mode NetworkOnly -NetworkMonitorMinutes 60
================================================================================
#>

param(
    [ValidateSet('Quick','Full','NetworkOnly','StressOnly')]
    [string]$Mode = 'Full',

    [int]$StressDurationMinutes = 10,
    [int]$NetworkMonitorMinutes = 30,
    [int]$PingIntervalSeconds = 2,
    [string]$PingTarget = '1.1.1.1',
    [string]$SecondaryPingTarget = '8.8.8.8',
    [string]$GatewayOverride = '',

    # Which load generators to run during -Mode StressOnly. Lets a front-end
    # (e.g. KTS-Toolkit-GUI.ps1) trigger a single component test - "Test CPU
    # only" - instead of always running the full combined stress test.
    [ValidateSet('CPU','Memory','Disk','Network')]
    [string[]]$StressComponents = @('CPU','Memory','Disk','Network')
)

# ------------------------------------------------------------------------------
# Branding / constants
# ------------------------------------------------------------------------------
$Global:KTS_Version   = '1.0.0'
$Global:KTS_Brand     = 'KamTech Solutions'
$Global:KTS_ColorNavy = '#0B1F3A'
$Global:KTS_ColorRed  = '#B3122B'
$HostName    = $env:COMPUTERNAME
$RunStamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$OutputRoot  = "C:\ProgramData\KamTech\Reports\$HostName"
$RunFolder   = Join-Path $OutputRoot $RunStamp
New-Item -ItemType Directory -Path $RunFolder -Force | Out-Null

$LogPath          = Join-Path $RunFolder 'ktsdiag.log'
$NetLogCsv        = Join-Path $RunFolder 'network_monitor.csv'
$InventoryJson    = Join-Path $RunFolder 'inventory.json'
$EventFindingsCsv = Join-Path $RunFolder 'event_findings.csv'
$ReportHtml       = Join-Path $RunFolder 'report.html'

$Findings = New-Object System.Collections.Generic.List[Object]

function Write-KTSLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line
}

function Add-Finding {
    param(
        [string]$Category,
        [ValidateSet('OK','INFO','WARN','CRITICAL')][string]$Severity,
        [string]$Detail
    )
    $Findings.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Category  = $Category
        Severity  = $Severity
        Detail    = $Detail
    })
    Write-KTSLog "$Category :: $Detail" $Severity
}

Write-KTSLog "=== $KTS_Brand DiagTool v$KTS_Version starting on $HostName (Mode=$Mode) ==="

# ------------------------------------------------------------------------------
# SECTION 1: System / Hardware Inventory
# ------------------------------------------------------------------------------
function Get-KTSInventory {
    Write-KTSLog 'Collecting system inventory...'
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $board= Get-CimInstance Win32_BaseBoard
    $cpu  = Get-CimInstance Win32_Processor
    $mem  = Get-CimInstance Win32_PhysicalMemory
    $disk = Get-CimInstance Win32_DiskDrive
    $os   = Get-CimInstance Win32_OperatingSystem

    # Serial number: prefer the chassis/system serial (Win32_BIOS.SerialNumber is
    # actually the system-enclosure service tag on Dell hardware, not the BIOS
    # chip itself). Fall back to the motherboard serial if the system one is
    # blank or a generic placeholder some OEMs ship ("To be filled by O.E.M.").
    $sysSerial = $bios.SerialNumber
    if ([string]::IsNullOrWhiteSpace($sysSerial) -or $sysSerial -match 'To Be Filled|Default string|None|System Serial') {
        $sysSerial = $board.SerialNumber
    }
    if ([string]::IsNullOrWhiteSpace($sysSerial)) { $sysSerial = 'UNKNOWN' }

    $inv = [PSCustomObject]@{
        Manufacturer       = $cs.Manufacturer
        Model              = $cs.Model
        SerialNumber       = $sysSerial.Trim()
        BiosVersion        = $bios.SMBIOSBIOSVersion
        BiosDate           = $bios.ReleaseDate
        MotherboardMfr     = $board.Manufacturer
        MotherboardModel   = $board.Product
        MotherboardSerial  = $board.SerialNumber
        OS                 = $os.Caption
        OSBuild            = $os.BuildNumber
        CPU                = $cpu.Name -join '; '
        TotalMemoryGB      = [math]::Round(($mem | Measure-Object Capacity -Sum).Sum / 1GB, 1)
        MemoryModules      = $mem.Count
        Disks              = $disk | ForEach-Object { "$($_.Model) ($([math]::Round($_.Size/1GB)) GB)" }
        UptimeHours        = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    }

    $inv | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $InventoryJson

    # Keep the serial visible for the whole run, not just in the report:
    # the console/PowerShell window title bar stays on-screen even when the
    # window is minimized to the taskbar or the console buffer is scrolled.
    try { $Host.UI.RawUI.WindowTitle = "KTS-DiagTool | $HostName | S/N: $($inv.SerialNumber)" } catch {}

    Add-Finding 'Hardware' 'INFO' "Serial number: $($inv.SerialNumber) (source: $(if ($bios.SerialNumber -eq $inv.SerialNumber) {'system/BIOS'} else {'motherboard'}))"
    Add-Finding 'Hardware' 'INFO' "Motherboard: $($inv.MotherboardMfr) $($inv.MotherboardModel), serial $($inv.MotherboardSerial)"
    if ($inv.Model -match '9010') {
        Add-Finding 'Hardware' 'INFO' "Confirmed OptiPlex 9010 SFF. BIOS $($inv.BiosVersion) ($($inv.BiosDate)) - check Dell support site for a newer BIOS; several 9010 revisions fixed NIC power-state/ASPM bugs."
    }
    if ($inv.UptimeHours -lt 0.2) {
        Add-Finding 'Hardware' 'INFO' "System recently rebooted/reset ($([math]::Round($inv.UptimeHours*60)) min uptime)."
    }
    return $inv
}

# ------------------------------------------------------------------------------
# SECTION 2: NIC Deep-Dive (root-cause checks for intermittent LAN drops)
# ------------------------------------------------------------------------------
function Get-KTSNicDiagnostics {
    Write-KTSLog 'Running NIC deep-dive...'
    $adapters = Get-NetAdapter | Where-Object { $_.Virtual -eq $false }

    foreach ($nic in $adapters) {
        Add-Finding 'NIC' 'INFO' "$($nic.Name): $($nic.InterfaceDescription), Status=$($nic.Status), LinkSpeed=$($nic.LinkSpeed), MediaType=$($nic.MediaType)"

        # Driver info
        try {
            $drv = Get-NetAdapter -Name $nic.Name | Select-Object -ExpandProperty DriverInformation -ErrorAction SilentlyContinue
        } catch { $drv = $null }
        $pnp = Get-PnpDevice -InstanceId $nic.PnPDeviceID -ErrorAction SilentlyContinue |
               Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion','DEVPKEY_Device_DriverDate' -ErrorAction SilentlyContinue
        if ($pnp) {
            $verProp  = $pnp | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion'
            $dateProp = $pnp | Where-Object KeyName -eq 'DEVPKEY_Device_DriverDate'
            Add-Finding 'NIC' 'INFO' "$($nic.Name) driver version $($verProp.Data), dated $($dateProp.Data)"
        }

        # --- Power management: the #1 cause of "random" LAN drops ---
        $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        if ($pm) {
            if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                Add-Finding 'NIC-Power' 'CRITICAL' "$($nic.Name): 'Allow the computer to turn off this device to save power' is ENABLED. This is the most common cause of intermittent link drops on desktops. Disable it (Device Manager > adapter > Power Management tab, or Disable-NetAdapterPowerManagement)."
            } else {
                Add-Finding 'NIC-Power' 'OK' "$($nic.Name): computer-controlled device sleep is disabled."
            }
        }

        # Energy Efficient Ethernet / Green Ethernet advanced properties
        $advProps = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue
        foreach ($p in $advProps) {
            if ($p.DisplayName -match 'Energy Efficient|Green Ethernet|EEE') {
                $sev = if ($p.DisplayValue -notmatch 'Disabled|Off') { 'WARN' } else { 'OK' }
                Add-Finding 'NIC-Power' $sev "$($nic.Name): '$($p.DisplayName)' = $($p.DisplayValue). EEE/Green-Ethernet can cause brief renegotiation-induced drops on some switches/routers - try disabling if drops continue."
            }
            if ($p.DisplayName -match 'Interrupt Moderation') {
                Add-Finding 'NIC-Perf' 'INFO' "$($nic.Name): Interrupt Moderation = $($p.DisplayValue)."
            }
            if ($p.DisplayName -match 'Speed.*Duplex|Speed & Duplex') {
                Add-Finding 'NIC-Perf' 'INFO' "$($nic.Name): Speed/Duplex setting = $($p.DisplayValue) (should normally be 'Auto Negotiation' unless the switch port is forced)."
            }
        }

        # Adapter error counters
        $stats = Get-NetAdapterStatistics -Name $nic.Name -ErrorAction SilentlyContinue
        if ($stats) {
            if ($stats.OutboundDiscardedPackets -gt 0 -or $stats.ReceivedPacketErrors -gt 0) {
                Add-Finding 'NIC-Stats' 'WARN' "$($nic.Name): OutboundDiscarded=$($stats.OutboundDiscardedPackets), ReceiveErrors=$($stats.ReceivedPacketErrors) since last counter reset."
            }
        }
    }

    # Onboard NIC driver source sanity check (generic MS driver vs OEM driver)
    $pnpDrivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -eq 'NET' -and $_.DeviceName -notmatch 'Virtual|Bluetooth|WAN Miniport' }
    foreach ($d in $pnpDrivers) {
        if ($d.DriverProviderName -match 'Microsoft' -and $d.DeviceName -notmatch 'Loopback') {
            Add-Finding 'NIC-Driver' 'WARN' "$($d.DeviceName) is using a generic Microsoft-provided driver ($($d.DriverVersion)). Installing the vendor (Intel/Realtek) driver directly from Dell's support page for the 9010 often resolves link-flap issues the inbox driver mishandles."
        }
    }
}

# ------------------------------------------------------------------------------
# SECTION 3: Event Log Correlation
# ------------------------------------------------------------------------------
function Get-KTSEventCorrelation {
    Write-KTSLog 'Scanning event logs for NIC / power / DNS anomalies (last 7 days)...'
    $since = (Get-Date).AddDays(-7)
    $rows = New-Object System.Collections.Generic.List[Object]

    # System log: Kernel-Power 41 (unexpected reboot), 6008 (unexpected shutdown),
    # e1cexpress/e1dexpress/e1rexpress/rtl (NIC reset/link changes), 27 (NIC power state),
    # Dhcp-Client 1002 (lease renew fail), Tcpip 4227/4231 (port exhaustion)
    $filter = @{
        LogName = 'System'
        StartTime = $since
    }
    try {
        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
    } catch {
        $events = @()
        Write-KTSLog "Could not query System event log: $($_.Exception.Message)" 'WARN'
    }

    $interesting = $events | Where-Object {
        ($_.ProviderName -match 'Kernel-Power' -and $_.Id -in 41,42,107) -or
        ($_.Id -eq 6008) -or
        ($_.ProviderName -match 'e1.express|e1.expre|rtl8|Realtek|Intel.*Network|NDIS|Dhcp-Client|Tcpip|Tcpip6|Dnscache') -or
        ($_.ProviderName -match 'e1iexpress|e1cexpress|e1dexpress' )
    }

    foreach ($e in $interesting) {
        $rows.Add([PSCustomObject]@{
            TimeCreated = $e.TimeCreated
            Id          = $e.Id
            Provider    = $e.ProviderName
            Level       = $e.LevelDisplayName
            Message     = ($e.Message -split "`n")[0]
        })
    }
    $rows | Sort-Object TimeCreated -Descending | Export-Csv -Path $EventFindingsCsv -NoTypeInformation -Encoding UTF8

    $kp41 = ($rows | Where-Object Id -eq 41).Count
    $nicResets = ($rows | Where-Object { $_.Provider -match 'e1.express|Realtek|rtl8' }).Count
    $dhcpFail = ($rows | Where-Object { $_.Provider -match 'Dhcp-Client' -and $_.Id -eq 1002 }).Count

    if ($kp41 -gt 0) {
        Add-Finding 'Events' 'CRITICAL' "$kp41 Kernel-Power Event ID 41 (unexpected shutdown/reboot) in the last 7 days. Rule out hard power-button shutdowns and check PSU/power-cable seating on the 9010 SFF."
    }
    if ($nicResets -gt 0) {
        Add-Finding 'Events' 'WARN' "$nicResets NIC driver reset/link-change events logged in the last 7 days - correlate their timestamps against network_monitor.csv drop times."
    }
    if ($dhcpFail -gt 0) {
        Add-Finding 'Events' 'WARN' "$dhcpFail DHCP lease renewal failures logged - if these line up with drops, check router DHCP lease time and consider a DHCP reservation for this host."
    }
    if ($rows.Count -eq 0) {
        Add-Finding 'Events' 'OK' 'No matching NIC/power/DHCP anomaly events found in the last 7 days.'
    }
    return $rows
}

# ------------------------------------------------------------------------------
# SECTION 4: Live Network Monitor (gateway + external latency/loss + NIC counters)
# ------------------------------------------------------------------------------
function Start-KTSNetworkMonitor {
    param([int]$Minutes)

    $gw = $GatewayOverride
    if (-not $gw) {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Sort-Object RouteMetric | Select-Object -First 1).NextHop
    }
    Write-KTSLog "Starting network monitor for $Minutes minute(s). Gateway=$gw Targets=$PingTarget,$SecondaryPingTarget Interval=${PingIntervalSeconds}s"

    'Timestamp,Target,Success,LatencyMs,LinkStatus' | Out-File -Encoding utf8 $NetLogCsv

    $primaryNic = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    $endTime = (Get-Date).AddMinutes($Minutes)
    $lossCount = 0; $totalCount = 0; $dropEvents = 0; $lastLinkUp = $true

    while ((Get-Date) -lt $endTime) {
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
        $linkStatus = if ($primaryNic) { (Get-NetAdapter -Name $primaryNic.Name -ErrorAction SilentlyContinue).Status } else { 'Unknown' }

        if ($linkStatus -ne 'Up' -and $lastLinkUp) {
            $dropEvents++
            Add-Finding 'Live-Monitor' 'CRITICAL' "Physical link DOWN detected on $($primaryNic.Name) at $ts"
        }
        $lastLinkUp = ($linkStatus -eq 'Up')

        foreach ($target in @($gw, $PingTarget, $SecondaryPingTarget) | Where-Object { $_ }) {
            $totalCount++
            $reply = Test-Connection -ComputerName $target -Count 1 -ErrorAction SilentlyContinue
            if ($reply) {
                $lat = if ($reply.PSObject.Properties['Latency']) { $reply.Latency } else { $reply.ResponseTime }
                "$ts,$target,1,$lat,$linkStatus" | Add-Content -Path $NetLogCsv
            } else {
                $lossCount++
                "$ts,$target,0,,$linkStatus" | Add-Content -Path $NetLogCsv
            }
        }
        Start-Sleep -Seconds $PingIntervalSeconds
    }

    $lossPct = if ($totalCount -gt 0) { [math]::Round(($lossCount / $totalCount) * 100, 2) } else { 0 }
    if ($lossPct -ge 5) {
        Add-Finding 'Live-Monitor' 'CRITICAL' "Packet loss $lossPct% across monitor window ($lossCount/$totalCount probes failed). See $NetLogCsv for exact timestamps to cross-reference against event_findings.csv."
    } elseif ($lossPct -gt 0) {
        Add-Finding 'Live-Monitor' 'WARN' "Packet loss $lossPct% across monitor window ($lossCount/$totalCount probes failed)."
    } else {
        Add-Finding 'Live-Monitor' 'OK' "No packet loss detected across $totalCount probes."
    }
    if ($dropEvents -gt 0) {
        Add-Finding 'Live-Monitor' 'CRITICAL' "$dropEvents physical link-down transition(s) observed during the monitor window."
    }
}

# ------------------------------------------------------------------------------
# SECTION 5: Stress Test (CPU / Memory / Disk / Network, to try to reproduce drops under load)
# ------------------------------------------------------------------------------
function Start-KTSStressTest {
    param([int]$Minutes, [string[]]$Components = @('CPU','Memory','Disk','Network'))

    Write-KTSLog "Starting stress test for $Minutes minute(s). Components: $($Components -join ', ')"
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $endTime = (Get-Date).AddMinutes($Minutes)
    $jobsStarted = @()

    if ('CPU' -in $Components) {
        # CPU stress: one runspace per logical core
        1..$cores | ForEach-Object {
            $jobsStarted += Start-Job -ScriptBlock {
                param($end)
                while ((Get-Date) -lt $end) {
                    $x = 0
                    for ($i = 0; $i -lt 2000000; $i++) { $x += [math]::Sqrt($i) }
                }
            } -ArgumentList $endTime
        }
    }

    if ('Memory' -in $Components) {
        # Memory stress: hold a growing block, capped to avoid crashing the host
        $jobsStarted += Start-Job -ScriptBlock {
            param($end)
            $blocks = New-Object System.Collections.Generic.List[byte[]]
            while ((Get-Date) -lt $end -and $blocks.Count -lt 8) {
                $blocks.Add((New-Object byte[] (256MB)))
                Start-Sleep -Seconds 5
            }
            Start-Sleep -Seconds 5
        } -ArgumentList $endTime
    }

    if ('Disk' -in $Components) {
        # Disk stress: write/read/delete a scratch file repeatedly
        $jobsStarted += Start-Job -ScriptBlock {
            param($end, $folder)
            $path = Join-Path $folder 'ktsdiag_diskstress.tmp'
            $buf = New-Object byte[] (64MB)
            (New-Object Random).NextBytes($buf)
            while ((Get-Date) -lt $end) {
                [IO.File]::WriteAllBytes($path, $buf)
                [void][IO.File]::ReadAllBytes($path)
            }
            Remove-Item $path -ErrorAction SilentlyContinue
        } -ArgumentList $endTime, $RunFolder
    }

    if ('Network' -in $Components) {
        # Network load, running on the main thread so it also feeds the live monitor
        Start-KTSNetworkMonitor -Minutes $Minutes
    } else {
        Start-Sleep -Seconds ($Minutes * 60)
    }

    Write-KTSLog 'Stress test window complete, collecting job output...'
    if ($jobsStarted) {
        $jobsStarted | Wait-Job -Timeout 30 | Out-Null
        $jobsStarted | Receive-Job -ErrorAction SilentlyContinue | Out-Null
        $jobsStarted | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    Add-Finding 'Stress' 'INFO' "Stress test complete ($Minutes min, components: $($Components -join ', '), $cores logical cores available). Review event_findings.csv and network_monitor.csv for anything that lines up with the load window."
}

# ------------------------------------------------------------------------------
# SECTION 6: HTML Report (KTS branded)
# ------------------------------------------------------------------------------
function New-KTSReport {
    param($Inventory)

    $sevRank = @{ CRITICAL = 0; WARN = 1; INFO = 2; OK = 3 }
    $sorted = $Findings | Sort-Object { $sevRank[$_.Severity] }

    $worst = 'OK'
    if ($Findings | Where-Object Severity -eq 'CRITICAL') { $worst = 'CRITICAL' }
    elseif ($Findings | Where-Object Severity -eq 'WARN') { $worst = 'WARN' }

    $railColor = switch ($worst) {
        'CRITICAL' { $KTS_ColorRed }
        'WARN'     { '#C98A1E' }
        default    { '#1E8449' }
    }

    $rowsHtml = ($sorted | ForEach-Object {
        $c = switch ($_.Severity) {
            'CRITICAL' { $KTS_ColorRed }
            'WARN'     { '#C98A1E' }
            'OK'       { '#1E8449' }
            default    { '#5A6B87' }
        }
        "<tr><td style='color:$c;font-weight:600;white-space:nowrap'>$($_.Severity)</td><td>$($_.Category)</td><td>$($_.Detail)</td><td style='color:#8894a8;font-size:12px'>$($_.Timestamp)</td></tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html><head><meta charset='utf-8'>
<title>KTS Diagnostic Report - $HostName</title>
<style>
  body { background:#0B1F3A; color:#EAEEF5; font-family:'Segoe UI',Bahnschrift,sans-serif; margin:0; padding:0; }
  .wrap { max-width:1000px; margin:0 auto; padding:32px; }
  .rail { height:8px; background:$railColor; border-radius:4px; margin-bottom:24px; }
  h1 { font-size:22px; margin-bottom:4px; }
  .sub { color:#8894a8; font-size:13px; margin-bottom:24px; }
  .card { background:#122a4d; border:1px solid #1e3a63; border-radius:10px; padding:20px; margin-bottom:20px; }
  table { width:100%; border-collapse:collapse; font-size:13px; }
  th { text-align:left; color:#8894a8; font-weight:500; padding:8px; border-bottom:1px solid #1e3a63; }
  td { padding:8px; border-bottom:1px solid #17325a; vertical-align:top; }
  .brand { color:$KTS_ColorRed; font-weight:700; letter-spacing:0.5px; }
  code { color:#8fd0ff; }
  .serial-badge {
    position:fixed; top:14px; right:18px; z-index:999;
    background:#0B1F3A; border:1px solid $KTS_ColorRed; border-radius:8px;
    padding:8px 14px; font-family:Consolas,monospace; font-size:13px;
    box-shadow:0 2px 10px rgba(0,0,0,0.4);
  }
  .serial-badge .label { color:#8894a8; font-size:10px; letter-spacing:1px; display:block; }
  .serial-badge .value { color:#EAEEF5; font-weight:700; font-size:15px; }
</style></head>
<body>
  <div class='serial-badge'><span class='label'>SERIAL / SERVICE TAG</span><span class='value'>$($Inventory.SerialNumber)</span></div>
  <div class='wrap'>
  <div class='sub'><span class='brand'>KAMTECH SOLUTIONS</span> // KTS-DiagTool v$KTS_Version</div>
  <h1>Diagnostic Report - $HostName</h1>
  <div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; Mode: $Mode &nbsp;|&nbsp; Overall status: <b>$worst</b></div>
  <div class='rail'></div>

  <div class='card'>
    <h3>System</h3>
    <table>
      <tr><td>Model</td><td>$($Inventory.Manufacturer) $($Inventory.Model)</td></tr>
      <tr><td>Serial number</td><td><b>$($Inventory.SerialNumber)</b></td></tr>
      <tr><td>BIOS</td><td>$($Inventory.BiosVersion) ($($Inventory.BiosDate))</td></tr>
      <tr><td>Motherboard</td><td>$($Inventory.MotherboardMfr) $($Inventory.MotherboardModel) (serial $($Inventory.MotherboardSerial))</td></tr>
      <tr><td>OS</td><td>$($Inventory.OS) build $($Inventory.OSBuild)</td></tr>
      <tr><td>CPU</td><td>$($Inventory.CPU)</td></tr>
      <tr><td>Memory</td><td>$($Inventory.TotalMemoryGB) GB across $($Inventory.MemoryModules) module(s)</td></tr>
      <tr><td>Disks</td><td>$($Inventory.Disks -join '<br>')</td></tr>
      <tr><td>Uptime</td><td>$($Inventory.UptimeHours) hours</td></tr>
    </table>
  </div>

  <div class='card'>
    <h3>Findings ($($Findings.Count))</h3>
    <table>
      <tr><th>Severity</th><th>Category</th><th>Detail</th><th>Time</th></tr>
      $rowsHtml
    </table>
  </div>

  <div class='card'>
    <h3>Data files (this run)</h3>
    <table>
      <tr><td><code>inventory.json</code></td><td>Raw hardware inventory</td></tr>
      <tr><td><code>event_findings.csv</code></td><td>Filtered System event log entries (NIC/power/DHCP)</td></tr>
      <tr><td><code>network_monitor.csv</code></td><td>Per-probe latency/loss/link-status log</td></tr>
      <tr><td><code>ktsdiag.log</code></td><td>Full run log</td></tr>
    </table>
  </div>
</div></body></html>
"@
    $html | Out-File -Encoding utf8 $ReportHtml
    Write-KTSLog "Report written to $ReportHtml"
}

# ------------------------------------------------------------------------------
# Orchestration
# ------------------------------------------------------------------------------
$inv = Get-KTSInventory

switch ($Mode) {
    'Quick' {
        Get-KTSNicDiagnostics
        Get-KTSEventCorrelation | Out-Null
    }
    'NetworkOnly' {
        Get-KTSNicDiagnostics
        Get-KTSEventCorrelation | Out-Null
        Start-KTSNetworkMonitor -Minutes $NetworkMonitorMinutes
    }
    'StressOnly' {
        Start-KTSStressTest -Minutes $StressDurationMinutes -Components $StressComponents
    }
    'Full' {
        Get-KTSNicDiagnostics
        Get-KTSEventCorrelation | Out-Null
        Start-KTSNetworkMonitor -Minutes $NetworkMonitorMinutes
        Start-KTSStressTest -Minutes $StressDurationMinutes -Components $StressComponents
    }
}

New-KTSReport -Inventory $inv
Write-KTSLog "=== Run complete. Report: $ReportHtml ==="
Write-Host "`nOpen the report with:`n  Invoke-Item `"$ReportHtml`"`n"
