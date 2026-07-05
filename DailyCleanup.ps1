#Requires -RunAsAdministrator
<#
.SYNOPSIS
    DailyCleanup.ps1  -  Fast, silent Windows junk cleaner for Task Scheduler

.DESCRIPTION
    Removes temporary files, caches, crash dumps, and browser junk WITHOUT
    using Disk Cleanup (cleanmgr.exe), DISM, or any slow/interactive tool.
    Designed to run automatically every time the user logs on, in a visible
    console window -- giving the user a quick, tangible confirmation that
    their device was just cleaned, rather than a silent background task
    they have to take on faith. Safe to run as SYSTEM or Administrator.
    Any locked/in-use file is silently skipped; nothing critical is touched.

.WHAT THIS SCRIPT CLEARS
    [01] User & Windows system temp folders
    [02] Windows Update download cache
    [03] Prefetch (.pf) files
    [04] Windows Error Reporting archives
    [05] Thumbnail & icon caches
    [06] Recycle Bin
    [07] Delivery Optimization cache
    [08] Browser caches  -- Edge, Chrome, Firefox, Brave
    [09] Microsoft Office file cache & orphaned unsaved files
    [10] Microsoft Teams cache
    [11] Windows & CBS component logs  (older than N days)
    [12] Crash dumps & memory dump files
    [13] IIS logs  (if IIS is installed, older than N days)
    [14] Java deployment cache
    [15] User crash dump folder
    [16] DNS client cache  (flush)
    [17] Old cleanup log files

.WHAT THIS SCRIPT DOES NOT TOUCH
    - C:\Windows\Installer       (needed for app repair/uninstall)
    - User Documents / Desktop / Downloads
    - Windows Registry
    - Any file currently in use  (skipped silently)
    - C:\Windows.old             (detected and reported only -- see NOTICE in log)

.TASK SCHEDULER  -  ONE-TIME SETUP
    Run the block below once in an elevated PowerShell to register the task.
    Change the script path to wherever you saved this file.

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

    The task runs every time the user logs on, under the SYSTEM account,
    in a visible console window (no -WindowStyle Hidden) so the user sees
    it clean their device on login.
    Logs: C:\Logs\DailyCleanup\Cleanup_yyyy-MM-dd.log

.NOTES
    Tested  : Windows 10 / 11 / Server 2019+
    Requires: Administrator or SYSTEM privileges
    Schedule: At logon (visible window, no user interaction needed)
#>

# ==============================================================================
#  CONFIGURATION  -- edit these values to suit your environment
# ==============================================================================
$Config = @{
    LogDir           = "C:\Logs\DailyCleanup"
    KeepLogsDays     = 30    # Purge cleanup logs older than N days
    WinLogDays       = 7     # Delete Windows/CBS logs older than N days
    IisLogDays       = 30    # Delete IIS logs older than N days
    OfficeOrphanDays = 7     # Delete Office unsaved files older than N days
}
# ==============================================================================

Set-StrictMode -Version Latest
$Host.UI.RawUI.WindowTitle = "Daily Cleanup - Script By Yracy"
$ErrorActionPreference = "SilentlyContinue"

# ------------------------------------------------------------------------------
#  LOGGING SETUP
# ------------------------------------------------------------------------------
if (-not (Test-Path $Config.LogDir)) {
    New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
}
$Script:LogFile = Join-Path $Config.LogDir ("Cleanup_" + (Get-Date -Format 'yyyy-MM-dd') + ".log")

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","CLEAN","WARN","ERROR")][string]$Level = "INFO"
    )

    $line = "[" + (Get-Date -Format 'HH:mm:ss') + "] [" + $Level + "]  " + $Message

    Add-Content -Path $Script:LogFile -Value $line -Encoding UTF8

    switch ($Level) {
        "INFO"  { Write-Host $line -ForegroundColor Cyan }
        "CLEAN" { Write-Host $line -ForegroundColor Green }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
    }
}

$Script:StartTime = Get-Date

function Show-Step {
    param(
        [int]$Percent,
        [string]$Status
    )

    Write-Progress -Activity "Daily Cleanup" -Status $Status -PercentComplete $Percent
    Write-Log $Status -Level INFO
}

# ------------------------------------------------------------------------------
#  CORE HELPERS
# ------------------------------------------------------------------------------
[long]$Script:TotalFreedBytes = 0

function Remove-JunkFiles {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label,
        [string] $Filter    = "*",
        [switch] $Recurse,
        [int]    $OlderThan = 0
    )

    if (-not (Test-Path $Path)) { return }

    $scanParams = @{
        Path        = $Path
        Filter      = $Filter
        File        = $true
        Force       = $true
        ErrorAction = "SilentlyContinue"
    }
    if ($Recurse) { $scanParams.Recurse = $true }

    $files = Get-ChildItem @scanParams

    if ($OlderThan -gt 0) {
        $cutoff = (Get-Date).AddDays(-$OlderThan)
        $files  = $files | Where-Object { $_.LastWriteTime -lt $cutoff }
    }

    [long]$freed = 0
    [int] $count = 0
    foreach ($file in $files) {
        try {
            Remove-Item -Path $file.FullName -Force -ErrorAction Stop
            $freed += $file.Length
            $count++
        } catch { }
    }

    $Script:TotalFreedBytes += $freed
    $lvl = if ($count -gt 0) { "CLEAN" } else { "INFO" }
    Write-Log ("{0,-52}  {1,5} file(s)  {2,8:N1} MB" -f $Label, $count, ($freed / 1MB)) -Level $lvl
}

function Remove-JunkDirs {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Label
    )

    if (-not (Test-Path $Path)) { return }

    $dirs = Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue
    [int]$count = 0
    foreach ($d in $dirs) {
        try {
            Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction Stop
            $count++
        } catch { }
    }

    $lvl = if ($count -gt 0) { "CLEAN" } else { "INFO" }
    Write-Log ("{0,-52}  {1,5} dir(s)   (see final delta)" -f $Label, $count) -Level $lvl
}

# ==============================================================================
#  CLEANUP START
# ==============================================================================
$freeAtStart = (Get-PSDrive C -ErrorAction Stop).Free

$headerDate = Get-Date -Format 'dddd dd-MMM-yyyy  HH:mm'

Write-Progress -Activity "Daily Cleanup" -Completed

$runtime = (Get-Date) - $Script:StartTime

Write-Host ""
Write-Host "================ CLEANUP SUMMARY ================" -ForegroundColor White
Write-Host ("Tracked Freed Space : {0:N1} MB" -f $trackedMB) -ForegroundColor Green
Write-Host ("Actual Disk Change  : {0:N1} MB" -f $actualDelta) -ForegroundColor Green
Write-Host ("Runtime             : {0:mm\:ss}" -f $runtime) -ForegroundColor Cyan
Write-Host ("Log File            : {0}" -f $Script:LogFile) -ForegroundColor Yellow
Write-Host "=================================================" -ForegroundColor White

Write-Log "======================================================================"
Write-Log ("  DAILY CLEANUP  |  " + $headerDate + "  |  " + $env:COMPUTERNAME)
Write-Log ("  C: free at start : " + ("{0:N0}" -f ($freeAtStart / 1MB)) + " MB")
Write-Log "======================================================================"

Show-Step 5 "Step 1/17 - Temp Folders"

# -- [01] TEMP FOLDERS ---------------------------------------------------------
Write-Log "--- [01] Temp Folders ---"
Remove-JunkFiles -Path $env:TEMP -Label "User Temp (%TEMP%)" -Recurse
Remove-JunkFiles -Path "C:\Windows\Temp" -Label "Windows System Temp" -Recurse
Remove-JunkFiles -Path "C:\Windows\System32\config\systemprofile\AppData\Local\Temp" `
                 -Label "SYSTEM Account Temp" -Recurse

Show-Step 10 "Step 2/17 - Windows Update Cache"

# -- [02] WINDOWS UPDATE DOWNLOAD CACHE ----------------------------------------
Write-Log "--- [02] Windows Update Cache ---"
$wuSvc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
$wuWasRunning = ($null -ne $wuSvc) -and ($wuSvc.Status -eq "Running")
if ($wuWasRunning) {
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Log "  wuauserv stopped for cache clear" -Level INFO
}
Remove-JunkDirs -Path "C:\Windows\SoftwareDistribution\Download" `
                -Label "Windows Update Download Cache"
if ($wuWasRunning) {
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
    Write-Log "  wuauserv restarted" -Level INFO
}

Show-Step 15 "Step 3/17 - Prefetch"

# -- [03] PREFETCH --------------------------------------------------------------
Write-Log "--- [03] Prefetch ---"
Remove-JunkFiles -Path "C:\Windows\Prefetch" -Label "Prefetch Files (.pf)" -Filter "*.pf"

Show-Step 20 "Step 4/17 - Windows Error Reporting"

# -- [04] WINDOWS ERROR REPORTING ----------------------------------------------
Write-Log "--- [04] Windows Error Reporting ---"
Remove-JunkDirs  -Path "C:\ProgramData\Microsoft\Windows\WER\ReportArchive" -Label "WER Report Archive"
Remove-JunkDirs  -Path "C:\ProgramData\Microsoft\Windows\WER\ReportQueue"   -Label "WER Report Queue"
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Windows\WER"            -Label "WER User Data" -Recurse

Show-Step 25 "Step 5/17 - Thumbnail & Icon Cache"

# -- [05] THUMBNAIL & ICON CACHE -----------------------------------------------
Write-Log "--- [05] Thumbnail & Icon Cache ---"
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" `
                 -Label "Thumbnail Cache (thumbcache_*.db)" -Filter "thumbcache_*.db"
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" `
                 -Label "Icon Cache (iconcache_*.db)" -Filter "iconcache_*.db"

Show-Step 30 "Step 6/17 - Recycle Bin"

# -- [06] RECYCLE BIN ----------------------------------------------------------
Write-Log "--- [06] Recycle Bin ---"
try {
    $rbItems = (New-Object -ComObject Shell.Application).Namespace(10).Items()
    [long]$rbBytes = ($rbItems | Measure-Object -Property Size -Sum).Sum
    if (-not $rbBytes) { $rbBytes = 0 }
    Clear-RecycleBin -Force -ErrorAction Stop
    $Script:TotalFreedBytes += $rbBytes
    Write-Log ("  {0,-50}        {1,8:N1} MB" -f "Recycle Bin", ($rbBytes / 1MB)) -Level CLEAN
} catch {
    Write-Log ("  Recycle Bin: " + $_.Exception.Message) -Level WARN
}

Show-Step 35 "Step 7/17 - Delivery Optimization Cache"

# -- [07] DELIVERY OPTIMIZATION ------------------------------------------------
Write-Log "--- [07] Delivery Optimization Cache ---"
$doPath = "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
Remove-JunkDirs -Path $doPath -Label "Delivery Optimization Cache"

Show-Step 50 "Step 8/17 - Browser Caches"

# -- [08] BROWSER CACHES -------------------------------------------------------
Write-Log "--- [08] Browser Caches ---"

# Microsoft Edge (Chromium)
foreach ($sub in "Cache\Cache_Data", "Code Cache", "GPUCache", "ShaderCache") {
    Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\$sub" `
                     -Label ("Edge   > " + $sub) -Recurse
}

# Google Chrome
foreach ($sub in "Cache\Cache_Data", "Code Cache", "GPUCache", "ShaderCache") {
    Remove-JunkFiles -Path "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\$sub" `
                     -Label ("Chrome > " + $sub) -Recurse
}

# Mozilla Firefox (all profiles)
$ffBase = "$env:APPDATA\Mozilla\Firefox\Profiles"
if (Test-Path $ffBase) {
    Get-ChildItem $ffBase -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-JunkFiles -Path ($_.FullName + "\cache2\entries") `
                         -Label ("Firefox> cache  (" + $_.Name + ")") -Recurse
        Remove-JunkFiles -Path ($_.FullName + "\thumbnails") `
                         -Label "Firefox> thumbnails" -Recurse
    }
}

# Brave Browser
foreach ($sub in "Cache\Cache_Data", "Code Cache", "GPUCache") {
    Remove-JunkFiles -Path "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\$sub" `
                     -Label ("Brave  > " + $sub) -Recurse
}

Show-Step 60 "Step 9/17 - Microsoft Office Cache"

# -- [09] MICROSOFT OFFICE CACHE ----------------------------------------------
Write-Log "--- [09] Microsoft Office Cache ---"
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache" `
                 -Label "Office 365 File Cache" -Recurse
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Microsoft\Office\UnsavedFiles" `
                 -Label ("Office Unsaved Files (>" + $Config.OfficeOrphanDays + "d)") `
                 -Recurse -OlderThan $Config.OfficeOrphanDays

Show-Step 65 "Step 10/17 - Microsoft Teams Cache"

# -- [10] MICROSOFT TEAMS CACHE -----------------------------------------------
Write-Log "--- [10] Microsoft Teams Cache ---"
foreach ($sub in "Cache", "blob_storage", "databases", "GPUCache", "IndexedDB", "Local Storage", "tmp") {
    Remove-JunkFiles -Path "$env:APPDATA\Microsoft\Teams\$sub" -Label ("Teams  > " + $sub) -Recurse
}

Show-Step 75 "Step 11/17 - Windows & CBS Logs"

# -- [11] WINDOWS & CBS LOGS --------------------------------------------------
Write-Log "--- [11] Windows & CBS Logs ---"
Remove-JunkFiles -Path "C:\Windows\Logs" `
                 -Label ("Windows Logs (>" + $Config.WinLogDays + "d)") `
                 -Filter "*.log" -Recurse -OlderThan $Config.WinLogDays
Remove-JunkFiles -Path "C:\Windows\Logs\CBS" `
                 -Label "CBS Component Logs" `
                 -Filter "CbsPersist_*.log" -OlderThan $Config.WinLogDays
Remove-JunkFiles -Path "C:\Windows\Panther" `
                 -Label "Windows Setup Logs (>30d)" -Filter "*.log" -OlderThan 30

Show-Step 85 "Step 12/17 - Crash & Memory Dumps"

# -- [12] CRASH & MEMORY DUMPS ------------------------------------------------
Write-Log "--- [12] Crash & Memory Dumps ---"
Remove-JunkFiles -Path "C:\Windows\Minidump"          -Label "Minidump Files (.dmp)"    -Filter "*.dmp"
Remove-JunkFiles -Path "C:\Windows"                   -Label "Root Crash Dumps (.dmp)"  -Filter "*.dmp"
Remove-JunkFiles -Path "$env:LOCALAPPDATA\CrashDumps" -Label "User Crash Dumps"         -Filter "*.dmp"

if (Test-Path "C:\Windows\MEMORY.DMP") {
    try {
        $memSz = (Get-Item "C:\Windows\MEMORY.DMP").Length
        Remove-Item "C:\Windows\MEMORY.DMP" -Force -ErrorAction Stop
        $Script:TotalFreedBytes += $memSz
        Write-Log ("  {0,-50}        {1,8:N1} MB" -f "Full Memory Dump (MEMORY.DMP)", ($memSz / 1MB)) -Level CLEAN
    } catch {
        Write-Log "  MEMORY.DMP is locked (in use) -- skipped" -Level WARN
    }
}

# -- [13] IIS LOGS (only if IIS is present) ------------------------------------
Show-Step 90 "Step 13/17 - IIS Logs"

if (Test-Path "C:\inetpub\logs\LogFiles") {
    Write-Log "--- [13] IIS Logs ---"
    Remove-JunkFiles -Path "C:\inetpub\logs\LogFiles" `
                     -Label ("IIS Logs (>" + $Config.IisLogDays + "d)") `
                     -Filter "*.log" -Recurse -OlderThan $Config.IisLogDays
}

Show-Step 93 "Step 14/17 - Java Cache"

# -- [14] JAVA CACHE -----------------------------------------------------------
Write-Log "--- [14] Java Cache ---"
Remove-JunkFiles -Path "$env:APPDATA\Sun\Java\Deployment\cache" -Label "Java Deployment Cache"   -Recurse
Remove-JunkFiles -Path "$env:LOCALAPPDATA\Temp\Low"              -Label "Java Low-Integrity Temp" -Recurse

Show-Step 96 "Step 15/17 - DNS Cache"

# -- [15] DNS CLIENT CACHE -----------------------------------------------------
Write-Log "--- [15] DNS Cache ---"
try {
    Clear-DnsClientCache -ErrorAction Stop
    Write-Log "  DNS Client Cache flushed" -Level CLEAN
} catch {
    Write-Log ("  DNS flush failed: " + $_.Exception.Message) -Level WARN
}

Show-Step 98 "Step 16/17 - Windows.old Check"

# -- [16] WINDOWS.OLD -- detect only, never auto-delete -----------------------
if (Test-Path "C:\Windows.old") {
    Write-Log "  [NOTICE] Windows.old detected -- safe to delete 30+ days after OS upgrade." -Level WARN
    Write-Log "           To remove: Remove-Item 'C:\Windows.old' -Recurse -Force  (as admin)" -Level WARN
}

Show-Step 99 "Step 17/17 - Cleanup Log Maintenance"

# -- [17] PURGE OLD CLEANUP LOGS -----------------------------------------------
Write-Log "--- [17] Old Cleanup Logs ---"
Remove-JunkFiles -Path $Config.LogDir `
                 -Label ("Cleanup Logs (>" + $Config.KeepLogsDays + "d)") `
                 -Filter "Cleanup_*.log" -OlderThan $Config.KeepLogsDays

# ==============================================================================
#  SUMMARY
# ==============================================================================
$freeAtEnd   = (Get-PSDrive C -ErrorAction SilentlyContinue).Free
$actualDelta = if ($freeAtEnd) { ($freeAtEnd - $freeAtStart) / 1MB } else { 0 }
$trackedMB   = $Script:TotalFreedBytes / 1MB

Write-Log "======================================================================"
Write-Log ("  Tracked freed  (files only) : " + ("{0:N1}" -f $trackedMB) + " MB")
Write-Log ("  C: actual delta             : " + ("{0:N1}" -f $actualDelta) + " MB   (free now: " + ("{0:N0}" -f ($freeAtEnd / 1MB)) + " MB)")
Write-Log "  Cleanup complete."
Write-Log "======================================================================"


Write-Host ""
Write-Host "Script by Yracy" -ForegroundColor Yellow
Write-Host ""
Write-Host "Closing in 5 seconds..." -ForegroundColor Yellow
Start-Sleep -Seconds 5
exit
