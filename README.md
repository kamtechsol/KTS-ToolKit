# KTS Toolkit — KamTech Solutions
v1.1.0

A single Windows application (one process, one window) that does hardware
diagnostics, NIC deep-dive, event log correlation, live network monitoring,
CPU/memory/disk stress testing, HTML reporting, and a one-click reboot into
the Windows Recovery Environment. Built with a network module specifically
aimed at chasing intermittent LAN drops (field-targeted against a Dell
OptiPlex 9010 SFF, works on any Windows 10/11 PC).

**Everything runs in-process.** Clicking a button doesn't spawn a separate
`powershell.exe` window — diagnostics run on background threads inside the
same application, using PowerShell runspaces. Task Manager shows exactly one
KTS Toolkit process while it's open.

## Requirements
- Windows 10/11, PowerShell 5.1+ (built in)
- Run as **Administrator** (required for NIC power settings, event log, PnP
  driver queries, and scheduled task registration)

## Files

| File | Purpose |
|---|---|
| `KTS-Toolkit.ps1` | The whole application — engine + GUI, one file |
| `Build-KTSToolkitExe.ps1` | Compiles it into a standalone `KTS-Toolkit.exe` |
| `KTSWatchdog.ps1` | Tiny background check (link/ping) that launches the app itself when it detects trouble |
| `Install-KTSDiagTool.ps1` | Installs everything as a standing Windows tool |
| `Uninstall-KTSDiagTool.ps1` | Removes it cleanly |
| `SETUP.bat` | Double-click installer wrapper (no typed commands needed) |
| `KTS-Toolkit-Setup.nsi` / `KTS-Toolkit-Setup.exe` | Compiled all-in-one Windows installer (see Releases) |

## Option A — just run the app

```powershell
# Right-click PowerShell -> Run as administrator:
powershell -ExecutionPolicy Bypass -File .\KTS-Toolkit.ps1
```

That's it — one window opens with everything in it:

- **Diagnostics** — Run Quick Check, Run Full Diagnostic, Open Reports Folder, Open Last Report
- **Test individual functions** — Test CPU, Test Memory, Test Disk, Test NIC/Network, each with its own duration picker
- **System** — Open Device Manager, Open Event Viewer, Open Network Adapters, Restart Normally
- **Reboot to Recovery Menu (WinRE)** — a clearly separated red button that force-restarts straight into Advanced Startup Options (Safe Mode, System Restore, Startup Repair, Command Prompt). Confirms first — this is disruptive.
- A **live log panel** streams progress from whatever's running
- The serial number/service tag badge is pinned to the top-right corner at all times

Reports land in `C:\ProgramData\KamTech\Reports\<COMPUTERNAME>\<timestamp>\report.html`.

## Option B — compile it into a real .exe (one-time, on a Windows machine with internet)

```powershell
powershell -ExecutionPolicy Bypass -File .\Build-KTSToolkitExe.ps1
```

Installs the free, MIT-licensed `ps2exe` module from the PowerShell Gallery
and compiles `KTS-Toolkit.ps1` into `KTS-Toolkit.exe` — console-free,
double-clickable, self-elevating (UAC prompt on launch). This is now a
**fully self-contained application** — no other script needs to sit next to
it for it to run.

## Option C — install as a standing Windows tool (recommended for an intermittent issue)

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-KTSDiagTool.ps1
```

Or double-click `SETUP.bat` for the same thing without typing a command.

This installs to `C:\Program Files\KamTech\DiagTool` and registers three
scheduled tasks **scoped to the account you install as** (not SYSTEM, not
all users) — they only run while that user is logged on. All three just
launch the same application with different startup arguments:

| Task | Trigger | What it does |
|---|---|---|
| **KTS Boot Check** | 2 min after you log on | Launches the app with `-AutoRun Quick -StartMinimized` |
| **KTS Watchdog** | Every 5 minutes while logged in | Checks link status + ping; on the *first* sign of trouble, launches the app itself with `-AutoRun NetworkOnly` so the incident gets caught live |
| **KTS Weekly Deep Scan** | Sunday 2:00 AM | Launches the app with `-AutoRun Full -StartMinimized` |

It also adds a **KTS Toolkit** shortcut to **your** Start Menu and Desktop,
and **automatically launches the app** as soon as install finishes, so you
get immediate visible confirmation it worked. Pass `-NoAutoLaunch` to skip
that, or `-SkipWatchdog` to leave out the resident watchdog task.

### Watchdog behavior
`KTSWatchdog.ps1` is intentionally tiny — link status + a 2-packet ping,
nothing heavy, every 5 minutes. When it sees the link down or ping failing,
it drops a lock file (so it won't stack overlapping captures for 30
minutes), writes to `C:\ProgramData\KamTech\watchdog.log`, and launches
**the same KTS Toolkit application** (minimized) with `-AutoRun NetworkOnly`
so the drop gets logged in detail. It still only ever opens the one app —
never a second background script process.

### Uninstalling
```powershell
powershell -ExecutionPolicy Bypass -File "C:\Program Files\KamTech\DiagTool\Uninstall-KTSDiagTool.ps1"
```
Add `-PurgeReports` to also delete report history and the watchdog log
(kept by default).

## Option D — compiled all-in-one installer

Check the repo's **Releases** tab for `KTS-Toolkit-Setup.exe` — a genuine
compiled Windows installer (built with NSIS) that does the whole thing with
one download and one run: extracts the app, registers the scheduled tasks
and shortcuts above, and launches it, then leaves a normal Add/Remove
Programs entry for removal later.

## Command-line arguments

`KTS-Toolkit.ps1` / `KTS-Toolkit.exe` accept:
- `-AutoRun <Quick|Full|NetworkOnly|StressOnly>` — kick off that action immediately once the window opens (used by the scheduled tasks above)
- `-AutoRunMinutes <n>` — duration for the auto-run action
- `-StartMinimized` — open minimized instead of front-and-center (used for background-triggered runs)

## What it specifically checks for LAN drops

1. **NIC power management** — `AllowComputerToTurnOffDevice` and Energy
   Efficient Ethernet/Green Ethernet settings. These are the single most
   common cause of "random" desktop LAN drops and are flagged as
   CRITICAL/WARN when enabled.
2. **Driver provenance** — flags when Windows fell back to a generic
   Microsoft NIC driver instead of the Intel/Realtek OEM driver.
3. **Event log correlation** — pulls Kernel-Power 41/6008 (unexpected
   shutdown), NIC provider reset events, and DHCP lease-renewal failures
   from the last 7 days so you can line their timestamps up with the actual
   drop.
4. **Live monitor** — logs per-probe latency/loss and physical link status
   every few seconds, and flags any transition to link-down in real time.
5. **Stress correlation** — runs CPU/RAM/disk load at the same time as the
   network monitor, so if the drop is heat- or load-triggered it should
   show up during the run.

## Recommended workflow for this specific issue

1. Click **Run Quick Check** first — fix anything flagged CRITICAL under
   `NIC-Power` before doing anything else; it's the most likely culprit.
2. If it still drops, click **Test NIC / Network** with a long duration (or
   let the resident watchdog catch it automatically in the background).
3. Cross-reference the timestamp of any loss against the event log findings
   for that same window (both are in the report).
4. If nothing shows up passively, run a stress test to see if load or heat
   reproduces it on demand.

## Notes / known limitations

- Thermal-zone reporting (`MSAcpi_ThermalZoneTemperature`) is absent on
  many desktop motherboards — if so, the tool simply won't report a
  temperature; that's expected, not a bug.
- This is a diagnostic tool, not a fix — it flags and localizes causes, it
  doesn't change adapter settings for you. Recommended fixes are listed in
  the detail text of each finding in the report.
