#Requires -RunAsAdministrator
<#
================================================================================
 KTS-Toolkit.ps1
 KamTech Solutions - KTS Toolkit (single application)
 Version 1.1.0

 This is the WHOLE tool in one file/process: hardware diagnostics, NIC deep-
 dive, event log correlation, network monitor, CPU/memory/disk stress test,
 HTML reporting, and the windowed UI, all running inside ONE PowerShell
 process. Button clicks run diagnostics on background runspaces (real OS
 threads inside this same process) - nothing shells out to a separate
 powershell.exe, so there's exactly one process/window for the whole tool,
 not a new console flashing up per action.

 Optional command-line use (for the resident watchdog task, which needs to
 trigger a capture without a person clicking anything):
   KTS-Toolkit.exe -AutoRun NetworkOnly -AutoRunMinutes 10

 That still launches the ONE application (visibly, so you see it react when
 it catches a drop) and kicks off that action immediately on load.
================================================================================
#>

param(
    [ValidateSet('Quick','Full','NetworkOnly','StressOnly')]
    [string]$AutoRun = '',
    [int]$AutoRunMinutes = 10,
    [switch]$StartMinimized
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==============================================================================
# SHARED CONSTANTS / BRANDING
# ==============================================================================
$Global:KTS_Version   = '1.1.0'
$Global:KTS_Brand     = 'KamTech Solutions'
$Global:KTS_ColorNavy = '#0B1F3A'
$Global:KTS_ColorRed  = '#B3122B'
$InstallDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReportsRoot = 'C:\ProgramData\KamTech\Reports'
$HostNameG   = $env:COMPUTERNAME

# Thread-safe queue the background runspaces write log lines into; the GUI's
# Timer drains it on the UI thread. This is the only channel background
# threads use to talk to the UI - no shared mutable state, no races.
$Global:KTSLogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

# ==============================================================================
# ENGINE: everything below is pure logic, no UI. Each function is later
# extracted (by name, via Get-Item function:<name>) into a background
# runspace's initial session state, so keep them self-contained - anything
# they need must be a parameter or a $script: variable set at the top of
# Invoke-KTSRun, since a runspace's "script" scope is fresh per run.
# ==============================================================================

function Write-KTSLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -Path $script:LogPath -Value $line -ErrorAction Stop } catch {}
    try { $Global:KTSLogQueue.Enqueue($line) } catch {}
}

function Add-Finding {
    param(
        [string]$Category,
        [ValidateSet('OK','INFO','WARN','CRITICAL')][string]$Severity,
        [string]$Detail
    )
    $script:Findings.Add([PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Category  = $Category
        Severity  = $Severity
        Detail    = $Detail
    })
    Write-KTSLog "$Category :: $Detail" $Severity
}

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

function Get-KTSInventory {
    Write-KTSLog 'Collecting system inventory...'
    $cs    = Get-CimInstance Win32_ComputerSystem
    $bios  = Get-CimInstance Win32_BIOS
    $board = Get-CimInstance Win32_BaseBoard
    $cpu   = Get-CimInstance Win32_Processor
    $mem   = Get-CimInstance Win32_PhysicalMemory
    $disk  = Get-CimInstance Win32_DiskDrive
    $os    = Get-CimInstance Win32_OperatingSystem

    $sysSerial = $bios.SerialNumber
    if ([string]::IsNullOrWhiteSpace($sysSerial) -or $sysSerial -match 'To Be Filled|Default string|None|System Serial') {
        $sysSerial = $board.SerialNumber
    }
    if ([string]::IsNullOrWhiteSpace($sysSerial)) { $sysSerial = 'UNKNOWN' }

    $inv = [PSCustomObject]@{
        Manufacturer      = $cs.Manufacturer
        Model             = $cs.Model
        SerialNumber      = $sysSerial.Trim()
        BiosVersion       = $bios.SMBIOSBIOSVersion
        BiosDate          = $bios.ReleaseDate
        MotherboardMfr    = $board.Manufacturer
        MotherboardModel  = $board.Product
        MotherboardSerial = $board.SerialNumber
        OS                = $os.Caption
        OSBuild           = $os.BuildNumber
        CPU               = $cpu.Name -join '; '
        TotalMemoryGB     = [math]::Round(($mem | Measure-Object Capacity -Sum).Sum / 1GB, 1)
        MemoryModules     = $mem.Count
        Disks             = $disk | ForEach-Object { "$($_.Model) ($([math]::Round($_.Size/1GB)) GB)" }
        UptimeHours       = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    }

    $inv | ConvertTo-Json -Depth 4 | Out-File -Encoding utf8 $script:InventoryJson

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

function Get-KTSNicDiagnostics {
    Write-KTSLog 'Running NIC deep-dive...'
    $adapters = Get-NetAdapter | Where-Object { $_.Virtual -eq $false }

    foreach ($nic in $adapters) {
        Add-Finding 'NIC' 'INFO' "$($nic.Name): $($nic.InterfaceDescription), Status=$($nic.Status), LinkSpeed=$($nic.LinkSpeed), MediaType=$($nic.MediaType)"

        $pnp = Get-PnpDevice -InstanceId $nic.PnPDeviceID -ErrorAction SilentlyContinue |
               Get-PnpDeviceProperty -KeyName 'DEVPKEY_Device_DriverVersion','DEVPKEY_Device_DriverDate' -ErrorAction SilentlyContinue
        if ($pnp) {
            $verProp  = $pnp | Where-Object KeyName -eq 'DEVPKEY_Device_DriverVersion'
            $dateProp = $pnp | Where-Object KeyName -eq 'DEVPKEY_Device_DriverDate'
            Add-Finding 'NIC' 'INFO' "$($nic.Name) driver version $($verProp.Data), dated $($dateProp.Data)"
        }

        $pm = Get-NetAdapterPowerManagement -Name $nic.Name -ErrorAction SilentlyContinue
        if ($pm) {
            if ($pm.AllowComputerToTurnOffDevice -eq 'Enabled') {
                Add-Finding 'NIC-Power' 'CRITICAL' "$($nic.Name): 'Allow the computer to turn off this device to save power' is ENABLED. This is the most common cause of intermittent link drops on desktops. Disable it (Device Manager > adapter > Power Management tab, or Disable-NetAdapterPowerManagement)."
            } else {
                Add-Finding 'NIC-Power' 'OK' "$($nic.Name): computer-controlled device sleep is disabled."
            }
        }

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

        $stats = Get-NetAdapterStatistics -Name $nic.Name -ErrorAction SilentlyContinue
        if ($stats) {
            if ($stats.OutboundDiscardedPackets -gt 0 -or $stats.ReceivedPacketErrors -gt 0) {
                Add-Finding 'NIC-Stats' 'WARN' "$($nic.Name): OutboundDiscarded=$($stats.OutboundDiscardedPackets), ReceiveErrors=$($stats.ReceivedPacketErrors) since last counter reset."
            }
        }
    }

    $pnpDrivers = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -eq 'NET' -and $_.DeviceName -notmatch 'Virtual|Bluetooth|WAN Miniport' }
    foreach ($d in $pnpDrivers) {
        if ($d.DriverProviderName -match 'Microsoft' -and $d.DeviceName -notmatch 'Loopback') {
            Add-Finding 'NIC-Driver' 'WARN' "$($d.DeviceName) is using a generic Microsoft-provided driver ($($d.DriverVersion)). Installing the vendor (Intel/Realtek) driver directly from the OEM support page often resolves link-flap issues the inbox driver mishandles."
        }
    }
}

function Get-KTSEventCorrelation {
    Write-KTSLog 'Scanning event logs for NIC / power / DNS anomalies (last 7 days)...'
    $since = (Get-Date).AddDays(-7)
    $rows = New-Object System.Collections.Generic.List[Object]

    try {
        $events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since } -ErrorAction Stop
    } catch {
        $events = @()
        Write-KTSLog "Could not query System event log: $($_.Exception.Message)" 'WARN'
    }

    $interesting = $events | Where-Object {
        ($_.ProviderName -match 'Kernel-Power' -and $_.Id -in 41,42,107) -or
        ($_.Id -eq 6008) -or
        ($_.ProviderName -match 'e1.express|e1.expre|rtl8|Realtek|Intel.*Network|NDIS|Dhcp-Client|Tcpip|Tcpip6|Dnscache') -or
        ($_.ProviderName -match 'e1iexpress|e1cexpress|e1dexpress')
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
    $rows | Sort-Object TimeCreated -Descending | Export-Csv -Path $script:EventFindingsCsv -NoTypeInformation -Encoding UTF8

    $kp41      = ($rows | Where-Object Id -eq 41).Count
    $nicResets = ($rows | Where-Object { $_.Provider -match 'e1.express|Realtek|rtl8' }).Count
    $dhcpFail  = ($rows | Where-Object { $_.Provider -match 'Dhcp-Client' -and $_.Id -eq 1002 }).Count

    if ($kp41 -gt 0) {
        Add-Finding 'Events' 'CRITICAL' "$kp41 Kernel-Power Event ID 41 (unexpected shutdown/reboot) in the last 7 days. Rule out hard power-button shutdowns and check PSU/power-cable seating."
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

function Start-KTSNetworkMonitor {
    param([int]$Minutes)

    $gw = $script:GatewayOverride
    if (-not $gw) {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Sort-Object RouteMetric | Select-Object -First 1).NextHop
    }
    Write-KTSLog "Starting network monitor for $Minutes minute(s). Gateway=$gw Targets=$script:PingTarget,$script:SecondaryPingTarget"

    'Timestamp,Target,Success,LatencyMs,LinkStatus' | Out-File -Encoding utf8 $script:NetLogCsv

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

        foreach ($target in @($gw, $script:PingTarget, $script:SecondaryPingTarget) | Where-Object { $_ }) {
            $totalCount++
            $reply = Test-Connection -ComputerName $target -Count 1 -ErrorAction SilentlyContinue
            if ($reply) {
                $lat = if ($reply.PSObject.Properties['Latency']) { $reply.Latency } else { $reply.ResponseTime }
                "$ts,$target,1,$lat,$linkStatus" | Add-Content -Path $script:NetLogCsv
            } else {
                $lossCount++
                "$ts,$target,0,,$linkStatus" | Add-Content -Path $script:NetLogCsv
            }
        }
        Start-Sleep -Seconds 2
    }

    $lossPct = if ($totalCount -gt 0) { [math]::Round(($lossCount / $totalCount) * 100, 2) } else { 0 }
    if ($lossPct -ge 5) {
        Add-Finding 'Live-Monitor' 'CRITICAL' "Packet loss $lossPct% across monitor window ($lossCount/$totalCount probes failed). See network_monitor.csv for exact timestamps."
    } elseif ($lossPct -gt 0) {
        Add-Finding 'Live-Monitor' 'WARN' "Packet loss $lossPct% across monitor window ($lossCount/$totalCount probes failed)."
    } else {
        Add-Finding 'Live-Monitor' 'OK' "No packet loss detected across $totalCount probes."
    }
    if ($dropEvents -gt 0) {
        Add-Finding 'Live-Monitor' 'CRITICAL' "$dropEvents physical link-down transition(s) observed during the monitor window."
    }
}

# CPU/Memory/Disk load generators run as their OWN mini-runspaces inside this
# SAME process (a RunspacePool) - not Start-Job, which would spawn separate
# powershell.exe processes. Everything stays inside the one running app.
function Start-KTSStressTest {
    param([int]$Minutes, [string[]]$Components = @('CPU','Memory','Disk','Network'))

    Write-KTSLog "Starting stress test for $Minutes minute(s). Components: $($Components -join ', ')"
    $cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    $endTime = (Get-Date).AddMinutes($Minutes)
    $workers = New-Object System.Collections.Generic.List[Object]

    $cpuBlock = {
        param($end)
        while ((Get-Date) -lt $end) {
            $x = 0
            for ($i = 0; $i -lt 2000000; $i++) { $x += [math]::Sqrt($i) }
        }
    }
    $memBlock = {
        param($end)
        $blocks = New-Object System.Collections.Generic.List[byte[]]
        while ((Get-Date) -lt $end -and $blocks.Count -lt 8) {
            $blocks.Add((New-Object byte[] (256MB)))
            Start-Sleep -Seconds 5
        }
        Start-Sleep -Seconds 5
    }
    $diskBlock = {
        param($end, $folder)
        $path = Join-Path $folder 'ktsdiag_diskstress.tmp'
        $buf = New-Object byte[] (64MB)
        (New-Object Random).NextBytes($buf)
        while ((Get-Date) -lt $end) {
            [IO.File]::WriteAllBytes($path, $buf)
            [void][IO.File]::ReadAllBytes($path)
        }
        Remove-Item $path -ErrorAction SilentlyContinue
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, ([Math]::Max(1, $cores) + 2))
    $pool.Open()

    function Start-KTSWorker {
        param($Pool, $Block, $ArgList)
        $ps = [powershell]::Create()
        $ps.RunspacePool = $Pool
        [void]$ps.AddScript($Block)
        foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
        [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }

    if ('CPU' -in $Components) {
        1..$cores | ForEach-Object { $workers.Add((Start-KTSWorker $pool $cpuBlock @($endTime))) }
    }
    if ('Memory' -in $Components) {
        $workers.Add((Start-KTSWorker $pool $memBlock @($endTime)))
    }
    if ('Disk' -in $Components) {
        $workers.Add((Start-KTSWorker $pool $diskBlock @($endTime, $script:RunFolder)))
    }

    if ('Network' -in $Components) {
        Start-KTSNetworkMonitor -Minutes $Minutes
    } else {
        Start-Sleep -Seconds ($Minutes * 60)
    }

    Write-KTSLog 'Stress test window complete, collecting worker output...'
    foreach ($w in $workers) {
        try { $w.PS.EndInvoke($w.Handle) | Out-Null } catch {}
        $w.PS.Dispose()
    }
    $pool.Close(); $pool.Dispose()

    Add-Finding 'Stress' 'INFO' "Stress test complete ($Minutes min, components: $($Components -join ', '), $cores logical cores available). Review event_findings.csv and network_monitor.csv for anything that lines up with the load window."
}

function New-KTSReport {
    param($Inventory)

    $sevRank = @{ CRITICAL = 0; WARN = 1; INFO = 2; OK = 3 }
    $sorted = $script:Findings | Sort-Object { $sevRank[$_.Severity] }

    $worst = 'OK'
    if ($script:Findings | Where-Object Severity -eq 'CRITICAL') { $worst = 'CRITICAL' }
    elseif ($script:Findings | Where-Object Severity -eq 'WARN') { $worst = 'WARN' }

    $railColor = switch ($worst) {
        'CRITICAL' { $Global:KTS_ColorRed }
        'WARN'     { '#C98A1E' }
        default    { '#1E8449' }
    }

    $rowsHtml = ($sorted | ForEach-Object {
        $c = switch ($_.Severity) {
            'CRITICAL' { $Global:KTS_ColorRed }
            'WARN'     { '#C98A1E' }
            'OK'       { '#1E8449' }
            default    { '#5A6B87' }
        }
        "<tr><td style='color:$c;font-weight:600;white-space:nowrap'>$($_.Severity)</td><td>$($_.Category)</td><td>$($_.Detail)</td><td style='color:#8894a8;font-size:12px'>$($_.Timestamp)</td></tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html>
<html><head><meta charset='utf-8'>
<title>KTS Diagnostic Report - $script:HostName</title>
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
  .brand { color:$Global:KTS_ColorRed; font-weight:700; letter-spacing:0.5px; }
  code { color:#8fd0ff; }
  .serial-badge {
    position:fixed; top:14px; right:18px; z-index:999;
    background:#0B1F3A; border:1px solid $Global:KTS_ColorRed; border-radius:8px;
    padding:8px 14px; font-family:Consolas,monospace; font-size:13px;
    box-shadow:0 2px 10px rgba(0,0,0,0.4);
  }
  .serial-badge .label { color:#8894a8; font-size:10px; letter-spacing:1px; display:block; }
  .serial-badge .value { color:#EAEEF5; font-weight:700; font-size:15px; }
</style></head>
<body>
  <div class='serial-badge'><span class='label'>SERIAL / SERVICE TAG</span><span class='value'>$($Inventory.SerialNumber)</span></div>
  <div class='wrap'>
  <div class='sub'><span class='brand'>KAMTECH SOLUTIONS</span> // KTS Toolkit v$Global:KTS_Version</div>
  <h1>Diagnostic Report - $script:HostName</h1>
  <div class='sub'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp; Mode: $script:Mode &nbsp;|&nbsp; Overall status: <b>$worst</b></div>
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
    <h3>Findings ($($script:Findings.Count))</h3>
    <table>
      <tr><th>Severity</th><th>Category</th><th>Detail</th><th>Time</th></tr>
      $rowsHtml
    </table>
  </div>
</div></body></html>
"@
    $html | Out-File -Encoding utf8 $script:ReportHtml
    Write-KTSLog "Report written to $script:ReportHtml"
}

# ------------------------------------------------------------------------------
# Single orchestration entry point - this is what a background runspace calls.
# Every piece of run-scoped state is set with $script: here so the sibling
# functions above (which read the same bare names) resolve them correctly.
# ------------------------------------------------------------------------------
function Invoke-KTSRun {
    param(
        [ValidateSet('Quick','Full','NetworkOnly','StressOnly')]
        [string]$Mode = 'Full',
        [int]$StressDurationMinutes = 10,
        [int]$NetworkMonitorMinutes = 30,
        [string]$PingTarget = '1.1.1.1',
        [string]$SecondaryPingTarget = '8.8.8.8',
        [string]$GatewayOverride = '',
        [string[]]$StressComponents = @('CPU','Memory','Disk','Network')
    )

    $script:Mode                = $Mode
    $script:PingTarget          = $PingTarget
    $script:SecondaryPingTarget = $SecondaryPingTarget
    $script:GatewayOverride     = $GatewayOverride
    $script:HostName            = $env:COMPUTERNAME
    $RunStamp                   = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputRoot                 = "C:\ProgramData\KamTech\Reports\$script:HostName"
    $script:RunFolder           = Join-Path $OutputRoot $RunStamp
    New-Item -ItemType Directory -Path $script:RunFolder -Force | Out-Null

    $script:LogPath          = Join-Path $script:RunFolder 'ktsdiag.log'
    $script:NetLogCsv        = Join-Path $script:RunFolder 'network_monitor.csv'
    $script:InventoryJson    = Join-Path $script:RunFolder 'inventory.json'
    $script:EventFindingsCsv = Join-Path $script:RunFolder 'event_findings.csv'
    $script:ReportHtml       = Join-Path $script:RunFolder 'report.html'
    $script:Findings         = New-Object System.Collections.Generic.List[Object]

    Write-KTSLog "=== KTS Toolkit v$Global:KTS_Version run starting on $script:HostName (Mode=$Mode) ==="
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
    Write-KTSLog "=== Run complete. Report: $script:ReportHtml ==="
    return $script:ReportHtml
}

# ==============================================================================
# GUI
# ==============================================================================
$NavyColor  = [System.Drawing.ColorTranslator]::FromHtml('#0B1F3A')
$PanelColor = [System.Drawing.ColorTranslator]::FromHtml('#122a4d')
$RedColor   = [System.Drawing.ColorTranslator]::FromHtml('#B3122B')
$TextColor  = [System.Drawing.ColorTranslator]::FromHtml('#EAEEF5')
$MutedColor = [System.Drawing.ColorTranslator]::FromHtml('#8894a8')
$SerialNumber = Get-KTSSerial

$form = New-Object System.Windows.Forms.Form
$form.Text = "KTS Toolkit - KamTech Solutions (v$Global:KTS_Version)"
$form.Size = New-Object System.Drawing.Size(880, 620)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $NavyColor
$form.ForeColor = $TextColor
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
if ($StartMinimized) { $form.WindowState = 'Minimized' }

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
$subLabel.Text = "Host: $HostNameG"
$subLabel.ForeColor = $MutedColor
$subLabel.Location = New-Object System.Drawing.Point(16, 42)
$subLabel.AutoSize = $true
$form.Controls.Add($subLabel)

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
# In-process async runner: builds a fresh runspace, injects the engine
# functions (already loaded in THIS process) by name, and invokes Invoke-KTSRun
# on a background thread. A Timer on the UI thread drains the shared log queue
# and, when the run finishes, offers to open the report. No child process is
# ever created for this - Task Manager shows exactly one KTS Toolkit process.
# ------------------------------------------------------------------------------
$Global:KTSActiveRuns = New-Object System.Collections.Generic.List[Object]

$engineFunctionNames = @(
    'Write-KTSLog','Add-Finding','Get-KTSSerial','Get-KTSInventory','Get-KTSNicDiagnostics',
    'Get-KTSEventCorrelation','Start-KTSNetworkMonitor','Start-KTSStressTest','New-KTSReport','Invoke-KTSRun'
)

function New-KTSRunspace {
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fnName in $engineFunctionNames) {
        $fn = Get-Item "function:$fnName"
        $entry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fnName, $fn.Definition)
        $iss.Commands.Add($entry)
    }
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('KTSLogQueue', $Global:KTSLogQueue)
    $rs.SessionStateProxy.SetVariable('KTS_Version', $Global:KTS_Version)
    $rs.SessionStateProxy.SetVariable('KTS_ColorRed', $Global:KTS_ColorRed)
    return $rs
}

function Invoke-KTSAction {
    param([hashtable]$RunParams, [string]$ActionName)

    Write-GuiLog "Starting: $ActionName"
    $rs = New-KTSRunspace
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand('Invoke-KTSRun')
    foreach ($k in $RunParams.Keys) { [void]$ps.AddParameter($k, $RunParams[$k]) }
    $handle = $ps.BeginInvoke()

    $Global:KTSActiveRuns.Add([PSCustomObject]@{
        PS = $ps; RS = $rs; Handle = $handle; Name = $ActionName; Done = $false
    })
}

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 300
$logTimer.Add_Tick({
    $line = $null
    while ($Global:KTSLogQueue.TryDequeue([ref]$line)) {
        $logBox.AppendText("$line`r`n")
    }
    for ($i = $Global:KTSActiveRuns.Count - 1; $i -ge 0; $i--) {
        $r = $Global:KTSActiveRuns[$i]
        if (-not $r.Done -and $r.Handle.IsCompleted) {
            $r.Done = $true
            try {
                $reportPath = $r.PS.EndInvoke($r.Handle)
                Write-GuiLog "Finished: $($r.Name)"
                if ($reportPath -and (Test-Path $reportPath)) {
                    $global:LastReportPath = $reportPath
                }
            } catch {
                Write-GuiLog "Error in $($r.Name): $($_.Exception.Message)"
            } finally {
                $r.PS.Dispose()
                $r.RS.Close(); $r.RS.Dispose()
                $Global:KTSActiveRuns.RemoveAt($i)
            }
        }
    }
})
$logTimer.Start()

function Confirm-Action {
    param([string]$Message, [string]$Title)
    $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'YesNo', 'Warning')
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

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

$btnQuick.Add_Click({ Invoke-KTSAction @{ Mode = 'Quick' } 'Quick Check' })
$btnFull.Add_Click({ Invoke-KTSAction @{ Mode = 'Full' } 'Full Diagnostic' })
$btnReports.Add_Click({
    New-Item -ItemType Directory -Path $ReportsRoot -Force | Out-Null
    Invoke-Item $ReportsRoot
})
$btnLastReport.Add_Click({
    if ($global:LastReportPath -and (Test-Path $global:LastReportPath)) {
        Invoke-Item $global:LastReportPath
        return
    }
    $hostDir = Join-Path $ReportsRoot $HostNameG
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

$btnCpu.Add_Click({ Invoke-KTSAction @{ Mode = 'StressOnly'; StressDurationMinutes = [int]$durationPicker.Value; StressComponents = @('CPU') } 'CPU Test' })
$btnMemory.Add_Click({ Invoke-KTSAction @{ Mode = 'StressOnly'; StressDurationMinutes = [int]$durationPicker.Value; StressComponents = @('Memory') } 'Memory Test' })
$btnDisk.Add_Click({ Invoke-KTSAction @{ Mode = 'StressOnly'; StressDurationMinutes = [int]$durationPicker.Value; StressComponents = @('Disk') } 'Disk Test' })
$btnNic.Add_Click({ Invoke-KTSAction @{ Mode = 'NetworkOnly'; NetworkMonitorMinutes = [int]$durationPicker.Value } 'NIC / Network Test' })

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

$form.Add_FormClosing({
    foreach ($r in $Global:KTSActiveRuns) {
        try { $r.PS.Stop(); $r.PS.Dispose(); $r.RS.Close(); $r.RS.Dispose() } catch {}
    }
})

Write-GuiLog "KTS Toolkit v$Global:KTS_Version ready. Host $HostNameG, serial $SerialNumber."

if ($AutoRun) {
    $form.Add_Shown({
        $runParams = @{ Mode = $AutoRun }
        if ($AutoRun -in @('NetworkOnly','Full')) { $runParams.NetworkMonitorMinutes = $AutoRunMinutes }
        if ($AutoRun -in @('StressOnly','Full'))  { $runParams.StressDurationMinutes = $AutoRunMinutes }
        Invoke-KTSAction $runParams "Auto-run: $AutoRun"
    }.GetNewClosure())
}

[System.Windows.Forms.Application]::Run($form)
