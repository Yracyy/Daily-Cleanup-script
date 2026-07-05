# Daily Cleanup

A fast Windows junk-file cleaner that runs automatically every time you log in — no Disk Cleanup, no DISM, no manual clicking.

## Why I built this

Built-in tools like Disk Cleanup (`cleanmgr.exe`) are slow, require interaction, and don't cover things like browser caches, Teams cache, or crash dumps. I wanted something that runs automatically at logon as SYSTEM, logs exactly what it did, and never touches anything that could break an app or lose personal files.

It's intentionally **not** run with `-WindowStyle Hidden`. The console window pops up briefly on login so you actually see it working — a quick visual confirmation that your device just got cleaned, instead of a background task you just have to trust is doing something.

## What it cleans

| # | Category |
|---|----------|
| 01 | User & Windows system temp folders |
| 02 | Windows Update download cache |
| 03 | Prefetch (`.pf`) files |
| 04 | Windows Error Reporting archives |
| 05 | Thumbnail & icon caches |
| 06 | Recycle Bin |
| 07 | Delivery Optimization cache |
| 08 | Browser caches — Edge, Chrome, Firefox, Brave |
| 09 | Microsoft Office file cache & orphaned unsaved files |
| 10 | Microsoft Teams cache |
| 11 | Windows & CBS component logs (older than N days) |
| 12 | Crash dumps & memory dump files |
| 13 | IIS logs (if IIS is installed, older than N days) |
| 14 | Java deployment cache |
| 15 | User crash dump folder |
| 16 | DNS client cache (flush) |
| 17 | Old cleanup log files (self-cleaning) |

## What it deliberately does NOT touch

- `C:\Windows\Installer` (needed for app repair/uninstall)
- Documents / Desktop / Downloads
- The Windows Registry
- Any file currently in use — skipped silently, never forced
- `C:\Windows.old` — only detected and reported in the log, never auto-deleted (it's your call whether you're past the OS-upgrade rollback window)

## Requirements

- Windows 10 / 11 / Server 2019+
- PowerShell 5.1+
- Administrator or SYSTEM privileges

## Setup

1. Save `DailyCleanup.ps1` to `C:\Scripts\DailyCleanup.ps1`
2. Register the scheduled task by running this once in an **elevated** PowerShell window:

   ```powershell
   $scriptPath = "C:\Scripts\DailyCleanup.ps1"

   $action = New-ScheduledTaskAction `
       -Execute   "powershell.exe" `
       -Argument  "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

   $trigger  = New-ScheduledTaskTrigger -AtLogOn

   $settings = New-ScheduledTaskSettingsSet `
       -ExecutionTimeLimit  (New-TimeSpan -Hours 1) `
       -MultipleInstances   IgnoreNew `
       -StartWhenAvailable

   Register-ScheduledTask `
       -TaskName  "DailyWindowsCleanup" `
       -Action    $action `
       -Trigger   $trigger `
       -Settings  $settings `
       -RunLevel  Highest `
       -User      "SYSTEM" `
       -Force
   ```

That's it — the task now runs every time the user logs on, under the SYSTEM account.

**Note on `-WindowStyle Hidden`:** this is deliberately left out. The script runs in a visible console window on logon so the user can actually see it executing — a quick, tangible confirmation that their device just got cleaned, rather than a silent background task they have to trust is working. If you'd rather it run invisibly, just add `-WindowStyle Hidden` back into the `-Argument` string above.

## Logs

Every run writes a timestamped log to:
```
C:\Logs\DailyCleanup\Cleanup_yyyy-MM-dd.log
```
Logs older than 30 days are purged automatically (configurable — see below).

## Configuration

All tunable values live in one place near the top of the script:

```powershell
$Config = @{
    LogDir           = "C:\Logs\DailyCleanup"
    KeepLogsDays     = 30    # Purge cleanup logs older than N days
    WinLogDays       = 7     # Delete Windows/CBS logs older than N days
    IisLogDays       = 30    # Delete IIS logs older than N days
    OfficeOrphanDays = 7     # Delete Office unsaved files older than N days
}
```

## Troubleshooting

**The task didn't run when I logged in (laptop users especially)**

By default, Task Scheduler tasks created with `Register-ScheduledTask` have a condition that says *"Start the task only if the computer is on AC power"*. If your laptop is unplugged when you log in, the task silently skips itself — no error, no log, no console window, it just doesn't run.

To fix this:
1. Open **Task Scheduler** (`taskschd.msc`)
2. Find **DailyWindowsCleanup** in the Task Scheduler Library
3. Right-click → **Properties**
4. Go to the **Conditions** tab
5. Under **Power**, untick **"Start the task only if the computer is on AC power"**
6. Click **OK**

This is the #1 reason a scheduled task "just doesn't run" on laptops — worth checking first before assuming the script itself is broken.

**The task ran but the log shows almost nothing was cleaned**

Normal if you ran it recently or the caches are already small — check the summary lines at the bottom of the log (`Tracked freed` and `C: actual delta`) rather than individual step counts.

**"Cannot be loaded because running scripts is disabled on this system"**

Your PowerShell execution policy is blocking the script. Either:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
or unblock the specific file if it was downloaded from the internet:
```powershell
Unblock-File -Path "C:\Scripts\DailyCleanup.ps1"
```

**Task shows as "Running" indefinitely / never completes**

Check for a locked file causing a hang (rare, since all deletions use `-ErrorAction Stop` inside try/catch and skip on failure). If it's genuinely stuck, the `ExecutionTimeLimit` of 1 hour will force-stop it — you'll see an incomplete log for that day.

**Windows.old notice keeps appearing in the log**

This is intentional — the script will never auto-delete `C:\Windows.old` since it's your rollback safety net after a Windows upgrade. If you're confident you don't need to roll back, remove it manually:
```powershell
Remove-Item "C:\Windows.old" -Recurse -Force
```

## License

MIT
