# proton-qbit-port-sync

Sync the Proton VPN forwarded port into qBittorrent on Windows. The script:
1. Reads the forwarded port from Proton VPN logs
2. Updates `Session\Port` in `qBittorrent.ini`
3. Restarts qBittorrent so the new port is applied

This repository contains a single PowerShell script: `proton-qbit-port-sync.ps1`.

## Requirements

- Windows 10/11
- Proton VPN (with Port Forwarding enabled)
- qBittorrent installed
- PowerShell 5.1+ (built-in on Windows)

## Install

1. Create a folder for the script, for example:
   - `C:\Scripts\proton-qbit-port-sync`
2. Place `proton-qbit-port-sync.ps1` inside that folder.
3. (Optional) Create a log directory (the script will auto-create it):
   - `%ProgramData%\ProtonQbitPortSync`

## Usage

Run manually to validate:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
```

### Optional parameters

- `-ProtonVpnLogDir`  
  Default: `%LOCALAPPDATA%\Proton\Proton VPN\Logs`
- `-QbitConfigPath`  
  Default: `%APPDATA%\qBittorrent\qBittorrent.ini`
- `-QbitExePath`  
  Default: auto-detect (Program Files, PATH, registry)
- `-LogPath`  
  Default: `%ProgramData%\ProtonQbitPortSync\proton-qbit-port-sync.log`
- `-LogTailLines`  
  Default: `2000`
- `-SkipRestartIfSame`  
  Skip restart if the port did not change
- `-WhatIf`  
  Dry-run (no file writes, no restart)

Example with explicit paths:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1" `
  -QbitExePath "C:\Program Files\qBittorrent\qbittorrent.exe" `
  -LogPath "C:\Logs\proton-qbit-port-sync.log"
```

## Task Scheduler setup (Windows)

### Option A: Import the XML template

1. Open Task Scheduler.
2. In the right panel, click **Import Task...**
3. Select `task-scheduler-example.xml` from this repo.
4. Edit the task:
   - **Actions** tab: update the script path in Arguments.
   - **General** tab: set your user and enable **Run with highest privileges**.
5. Save.

### Option B: Create manually

1. Open Task Scheduler and click **Create Task...**
2. **General** tab:
   - Name: `Proton qBittorrent Port Sync`
   - Run whether user is logged on or not
   - Run with highest privileges
3. **Triggers** tab:
   - New... -> Begin the task: **At log on**
   - (Optional) Delay: **3 minutes**
4. **Actions** tab:
   - New... -> Action: **Start a program**
   - Program/script: `powershell.exe`
   - Add arguments:
     ```
     -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1"
     ```
5. **Settings** tab:
   - Allow task to be run on demand
   - Stop the task if it runs longer than 10 minutes

### Validate

Run the task manually once and check the log:

```
%ProgramData%\ProtonQbitPortSync\proton-qbit-port-sync.log
```

## Troubleshooting

- **No 'Port pair' line found**
  - Verify Proton VPN is connected with Port Forwarding enabled.
  - Check `%LOCALAPPDATA%\Proton\Proton VPN\Logs`.
- **qBittorrent does not restart**
  - Provide `-QbitExePath` explicitly.
- **Config not updated**
  - Verify `%APPDATA%\qBittorrent\qBittorrent.ini` exists and is accessible.

## Placeholders

Any user-specific paths or identifiers must be replaced with your own values:

- `C:\Scripts\proton-qbit-port-sync\proton-qbit-port-sync.ps1`
- `%LOCALAPPDATA%` / `%APPDATA%` / `%ProgramData%`

