# KTS-DiagTool — KamTech Solutions Diagnostic & Stress Test Tool
v1.0.0

A PowerShell-based hardware diagnostic and stress-test suite, with a network
module built specifically to chase intermittent LAN drops (built against a
Dell OptiPlex 9010 SFF, works on any Windows 10/11 PC). Can be run as a
one-off script or installed as a resident Windows tool that boot-checks,
watches the LAN continuously, and auto-captures detail the moment a drop
happens — without anyone needing to be at the machine.

## Requirements
- Windows 10/11, PowerShell 5.1+ (built in)
- Run as **Administrator** (required for NIC power settings, event log, PnP
  driver queries, and scheduled task registration)

## Files

| File | Purpose |
|---|---|
| `KTS-DiagTool.ps1` | The diagnostic/stress-test engine itself |
| `KTS-Toolkit-GUI.ps1` | Graphical front-end over the engine - buttons, not command lines |
| `Build-KTSToolkitExe.ps1` | Compiles the GUI script into a standalone `KTS-Toolkit.exe` |
| `KTSWatchdog.ps1` | Lightweight resident check — link/ping status; auto-triggers a capture on trouble |
| `Install-KTSDiagTool.ps1` | Installs everything below as a standing Windows tool |
| `Uninstall-KTSDiagTool.ps1` | Removes it cleanly |

## Option C — the graphical KTS Toolkit (recommended if you want point-and-click)

`KTS-Toolkit-GUI.ps1` is a full windowed UI over the same engine:

- **Diagnostics** — Run Quick Check, Run Full Diagnostic, Open Reports Folder, Open Last Report
- **Test individual functions** — Test CPU, Test Memory, Test Disk, Test NIC/Network, each with its own duration picker, so you can isolate one subsystem instead of running everything
- **System** — Open Device Manager, Open Event Viewer, Open Network Adapters, Restart Normally
- **Reboot to Recovery Menu (WinRE)** — a clearly separated red button that force-restarts straight into the Windows Advanced Startup Options menu (Safe Mode, System Restore, Startup Repair, Command Prompt). It confirms first — this is disruptive and closes open work.
- A **live log panel** streams output from whatever's running
- The serial number/service tag badge is pinned to the top-right corner at all times

### Build it into a real .exe (one-time, on a Windows machine with internet)

```powershell
# From the folder containing KTS-Toolkit-GUI.ps1 and KTS-DiagTool.ps1:
powershell -ExecutionPolicy Bypass -File .\Build-KTSToolkitExe.ps1
```

This installs the (free, MIT-licensed) `ps2exe` module from the PowerShell
Gallery and compiles `KTS-Toolkit-GUI.ps1` into `KTS-Toolkit.exe` — a
double-clickable, console-free executable that prompts for UAC elevation
itself (it needs admin for NIC settings, event logs, and the recovery
reboot). It calls `KTS-DiagTool.ps1` as a subprocess, so keep them in the
same folder — the installer copies both automatically if the exe exists
alongside it when you run `Install-KTSDiagTool.ps1`.

If you'd rather skip compiling, `KTS-Toolkit-GUI.ps1` runs the exact same UI
directly through PowerShell:
```powershell
powershell -ExecutionPolicy Bypass -File .\KTS-Toolkit-GUI.ps1
```

## Option A — run the engine once, ad hoc

```powershell
# Right-click PowerShell -> Run as administrator, then:
cd C:\path\to\ktsdiag
powershell -ExecutionPolicy Bypass -File .\KTS-DiagTool.ps1 -Mode Full
```

Reports land in:
```
C:\ProgramData\KamTech\Reports\<COMPUTERNAME>\<timestamp>\report.html
```

## Option D — one-click install (SETUP.bat)

Double-click `SETUP.bat`. It requests admin elevation (UAC prompt) and runs
`Install-KTSDiagTool.ps1` for you — no typing a PowerShell command required.
Everything else in this README still applies once it's installed.

## Option B — install everything as a standing Windows tool (recommended for this issue)

Since the LAN drop is intermittent, the installer turns the tool into a
background process so it catches the drop even when nobody's watching:

```powershell
# From the folder containing all four files, elevated:
powershell -ExecutionPolicy Bypass -File .\Install-KTSDiagTool.ps1
```

This installs to `C:\Program Files\KamTech\DiagTool` and registers three
SYSTEM scheduled tasks:

| Task | Trigger | What it does |
|---|---|---|
| **KTS Boot Check** | 2 min after every boot | Quick inventory + NIC/power audit + event scan |
| **KTS Watchdog** | Every 5 minutes, always | Checks link status + ping; on the *first* sign of trouble, immediately kicks off a 10-min live capture (`-Mode NetworkOnly`) so the incident gets caught with detail |
| **KTS Weekly Deep Scan** | Sunday 2:00 AM | Full diagnostic + 10-min stress test + 15-min network monitor |

It also adds Start Menu shortcuts under **KamTech Solutions** (Run Quick
Check, Run Full Diagnostic, Open Reports Folder, Uninstall) and a normal
Add/Remove Programs entry.

Skip the watchdog task if you only want boot + weekly checks:
```powershell
powershell -ExecutionPolicy Bypass -File .\Install-KTSDiagTool.ps1 -SkipWatchdog
```

### Watchdog behavior
`KTSWatchdog.ps1` is intentionally light — link status + a 2-packet ping,
nothing heavy running every 5 minutes. When it sees the link down or ping
failing, it drops a lock file (so it won't stack overlapping captures for
30 minutes), writes to `C:\ProgramData\KamTech\watchdog.log`, and launches
a hidden `KTS-DiagTool.ps1 -Mode NetworkOnly` capture in the background to
log the incident in detail. Check `watchdog.log` first for a quick history
of every trouble tick before digging into a full report folder.

### Uninstalling
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\KamTech\DiagTool\Uninstall-KTSDiagTool.ps1"
```
Add `-PurgeReports` to also delete report history and the watchdog log
(kept by default).

## Modes

| Mode | What it does | Typical run time |
|---|---|---|
| `Quick` | Hardware inventory, NIC config/power audit, 7-day event log scan | ~1 min |
| `NetworkOnly` | Quick checks + live ping/loss/link-status monitor | your `-NetworkMonitorMinutes` |
| `StressOnly` | CPU/RAM/disk load + network monitor running concurrently | your `-StressDurationMinutes` |
| `Full` (default) | Everything above, in sequence | monitor + stress time combined |

## Useful parameters

- `-NetworkMonitorMinutes 60` — run the live connectivity logger for an hour instead of the 30-min default. For an intermittent drop, longer is better — consider running `NetworkOnly` overnight.
- `-StressDurationMinutes 15` — how long to load CPU/RAM/disk while also monitoring the network, to see if drops correlate with load or heat.
- `-PingTarget`, `-SecondaryPingTarget` — external hosts to ping (default `1.1.1.1` / `8.8.8.8`).
- `-GatewayOverride` — force a specific gateway IP if auto-detection picks the wrong route.

## What it specifically checks for LAN drops

1. **NIC power management** — `AllowComputerToTurnOffDevice` and Energy
   Efficient Ethernet/Green Ethernet settings. These are the single most
   common cause of "random" desktop LAN drops and are flagged as
   CRITICAL/WARN when enabled.
2. **Driver provenance** — flags when Windows fell back to a generic
   Microsoft NIC driver instead of the Intel/Realtek OEM driver.
3. **Event log correlation** — pulls Kernel-Power 41/6008 (unexpected
   shutdown), NIC provider reset events, and DHCP lease-renewal failures
   from the last 7 days into `event_findings.csv` so you can line their
   timestamps up with the actual drop.
4. **Live monitor** — logs per-probe latency/loss and physical link status
   every few seconds to `network_monitor.csv`, and flags any transition to
   link-down in real time.
5. **Stress correlation** — runs CPU/RAM/disk load at the same time as the
   network monitor, so if the drop is heat- or load-triggered it should
   show up during the run.

## Recommended workflow for this specific issue

1. Run `-Mode Quick` first — fix anything flagged CRITICAL under
   `NIC-Power` before doing anything else; it's the most likely culprit.
2. If it still drops, run `-Mode NetworkOnly -NetworkMonitorMinutes 240`
   (or longer) left running in the background while the machine is used
   normally, to catch the drop live.
3. Cross-reference the timestamp of any loss in `network_monitor.csv`
   against `event_findings.csv` for that same window.
4. If nothing shows up passively, run `-Mode StressOnly` to see if load or
   heat reproduces it on demand.

## Notes / known limitations

- Thermal-zone reporting (`MSAcpi_ThermalZoneTemperature`) is absent on
  many desktop motherboards including some 9010 boards — if so, the tool
  will simply not report a temperature and this is expected, not a bug.
- This is a diagnostic tool, not a fix — it flags and localizes causes,
  it doesn't change adapter settings for you. Recommended fixes are listed
  in the `Detail` column of each finding.
