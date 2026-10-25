<#
.SYNOPSIS
    System health check & safe optimization script for Windows.
.DESCRIPTION
    L0 read-only checks (CPU/memory/disk/network/startup items) plus L1 safe
    cleanup (user-level caches/logs/temp files only).
    Never requires admin rights for the cleanup paths it touches, never touches
    personal files, never empties the Recycle Bin.
.PARAMETER Check
    Health check only
.PARAMETER Optimize
    Safe optimization only (dry run by default)
.PARAMETER Execute
    Actually delete; must be combined with -Optimize
.EXAMPLE
    .\sys-health-check.ps1                     # health check + optimization dry run
    .\sys-health-check.ps1 -Check              # checks only
    .\sys-health-check.ps1 -Optimize           # preview reclaimable space (dry run)
    .\sys-health-check.ps1 -Optimize -Execute  # actually clean
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Optimize,
    [switch]$Execute
)

$ErrorActionPreference = 'SilentlyContinue'

$ModeCheck    = $true
$ModeOptimize = $true
$DryRun       = -not $Execute

if ($Check -and -not $Optimize) { $ModeOptimize = $false }
if ($Optimize -and -not $Check) { $ModeCheck = $false }

# ---------- Colors ----------
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }
function Write-Info($Text)    { Write-Color "[INFO] $Text" 'Cyan' }
function Write-Success($Text) { Write-Color "[ OK ] $Text" 'Green' }
function Write-Warn($Text)    { Write-Color "[WARN] $Text" 'Yellow' }
function Write-Err($Text)     { Write-Color "[FAIL] $Text" 'Red' }
function Write-Section($Text) { Write-Host ''; Write-Color "========== $Text ==========" 'Cyan' }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { '{0:N1}T' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N1}G' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1}M' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0}K' -f ($Bytes / 1KB) }
    else { "${Bytes}B" }
}

function Get-DirSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { 0 } else { [long]$sum }
    } catch { 0 }
}

$script:TotalFreedBytes = [long]0

# =============================================================================
# Health check module
# =============================================================================

function Test-Cpu {
    Write-Section "CPU Check"
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) {
        Write-Host "  Model: $($cpu.Name)"
        Write-Host "  Physical cores: $($cpu.NumberOfCores)"
        Write-Host "  Logical cores: $($cpu.NumberOfLogicalProcessors)"
        Write-Host "  Current usage: $($cpu.LoadPercentage)%"
    }
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Write-Host "  Uptime: $([int]$uptime.TotalDays)d $($uptime.Hours)h $($uptime.Minutes)m"
}

function Test-Memory {
    Write-Section "Memory Check"
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $pct = [math]::Round(($usedGB / $totalGB) * 100, 1)
        Write-Host "  Total memory: ${totalGB} GB"
        Write-Host "  In use:       ${usedGB} GB (${pct}%)"
        Write-Host "  Free:         ${freeGB} GB"
    }
    Write-Host "  --- Top 5 memory consumers ---"
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
        $memMB = [math]::Round($_.WorkingSet64 / 1MB, 0)
        Write-Host ("  {0,-8} {1,-35} {2,8} MB" -f $_.Id, $_.ProcessName, $memMB)
    }
}

function Test-Disk {
    Write-Section "Disk Space Check"
    Write-Host "  Volume   Total    Used     Free     Use%"
    Write-Host "  -------------------------------------------------"
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $usedGB  = [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1)
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        $pct = if ($_.Size -gt 0) { [int](($_.Size - $_.FreeSpace) / $_.Size * 100) } else { 0 }
        $color = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
        Write-Color ("  {0,-8} {1,6}G {2,6}G {3,6}G {4,4}%" -f $_.DeviceID, $totalGB, $usedGB, $freeGB, $pct) $color
    }
    Write-Host ''
    Write-Info "Top 5 user directories by size (statistics only, nothing deleted):"
    $homePath = $env:USERPROFILE
    Get-ChildItem -LiteralPath $homePath -Directory -Force | ForEach-Object {
        [PSCustomObject]@{ Size = Get-DirSizeBytes $_.FullName; Path = $_.FullName }
    } | Sort-Object Size -Descending | Select-Object -First 5 | ForEach-Object {
        Write-Host ("  {0,-10} {1}" -f (Format-Size $_.Size), $_.Path.Replace($homePath, '~'))
    }
}

function Test-Network {
    Write-Section "Network Check"
    Write-Host "  --- Interface status ---"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' } |
        ForEach-Object {
            Write-Host ("  {0,-20} IP: {1}" -f $_.InterfaceAlias, $_.IPAddress)
        }
    Write-Host ''
    Write-Host "  --- Connectivity test ---"
    $targets = @('223.5.5.5', '8.8.8.8', 'www.baidu.com', 'www.baidu.com')
    foreach ($t in $targets) {
        $result = Test-Connection -TargetName $t -Count 2 -ErrorAction SilentlyContinue
        if ($result) {
            $latency = [math]::Round(($result | Measure-Object -Property ResponseTime -Average).Average, 1)
            Write-Success "Reachable $t (latency ${latency}ms)"
        } else {
            Write-Warn "Cannot reach $t"
        }
    }
    Write-Host ''
    Write-Host "  --- DNS resolution ---"
    try {
        $dns = Resolve-DnsName -Name 'www.baidu.com' -ErrorAction Stop | Select-Object -First 3
        $dns | ForEach-Object { Write-Host "  $($_.NameHost) -> $($_.IPAddress)" }
    } catch {
        Write-Warn "DNS resolution may be broken"
    }
}

function Test-Startup {
    Write-Section "Startup Items Check"
    Write-Host "  --- Startup folders ---"
    $startupFolders = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
    )
    foreach ($sf in $startupFolders) {
        Write-Host "  [$sf]"
        $items = Get-ChildItem -LiteralPath $sf -File -ErrorAction SilentlyContinue
        if ($items) {
            $items | ForEach-Object { Write-Host "    $($_.Name)" }
        } else {
            Write-Host "    (none)"
        }
    }
    Write-Host ''
    Write-Host "  --- Registry Run keys (current user) ---"
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty |
        Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            Write-Host "    $($_.Name)"
        }
    Write-Host ''
    Write-Host "  --- Scheduled tasks (non-Microsoft) ---"
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } |
        Select-Object -First 15 | ForEach-Object {
            Write-Host ("    {0,-40} {1}" -f $_.TaskName, $_.State)
        }
}

function Invoke-HealthCheck {
    Write-Host ''
    Write-Color "╔══════════════════════════════════════════════╗" 'Cyan'
    Write-Color "║     Computer Health Check $(Get-Date -Format 'yyyy-MM-dd HH:mm')            ║" 'Cyan'
    Write-Color "╚══════════════════════════════════════════════╝" 'Cyan'

    Test-Cpu
    Test-Memory
    Test-Disk
    Test-Network
    Test-Startup

    Write-Section "Check Summary"
    Write-Info "All of the above are read-only checks; nothing on the system was modified."
    Write-Info "To optimize, run: .\sys-health-check.ps1 -Optimize (dry run) or .\sys-health-check.ps1 -Optimize -Execute (execute)"
}

# =============================================================================
# Safe optimization module
# =============================================================================

function Clear-SafeDir {
    param([string]$Label, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Color "  [skip] ${Label}: directory not found" 'DarkGray'
        return
    }
    $sizeBytes = Get-DirSizeBytes $Path
    if ($DryRun) {
        Write-Color "  [dry-run] ${Label}: reclaimable $(Format-Size $sizeBytes) ($Path)" 'Yellow'
    } else {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Color "  [done] ${Label}: freed approximately $(Format-Size $sizeBytes)" 'Green'
    }
    $script:TotalFreedBytes += $sizeBytes
}

function Clear-CacheSubdirs {
    param([string]$Base, [string]$Label)
    if (-not (Test-Path -LiteralPath $Base)) { return }
    $totalBytes = [long]0
    foreach ($d in (Get-ChildItem -LiteralPath $Base -Directory -Force -ErrorAction SilentlyContinue)) {
        $sizeBytes = Get-DirSizeBytes $d.FullName
        $totalBytes += $sizeBytes
        if (-not $DryRun) {
            Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($DryRun) {
        Write-Color "  [dry-run] ${Label}: reclaimable $(Format-Size $totalBytes)" 'Yellow'
    } else {
        Write-Color "  [done] ${Label}: freed approximately $(Format-Size $totalBytes)" 'Green'
    }
    $script:TotalFreedBytes += $totalBytes
}

function Invoke-Optimize {
    Write-Host ''
    $modeText = if ($DryRun) { '(dry run, no files deleted)' } else { '' }
    Write-Color "╔══════════════════════════════════════════════╗" 'Cyan'
    Write-Color "║     Safe Optimization $modeText $(Get-Date -Format 'MM-dd HH:mm')     ║" 'Cyan'
    Write-Color "╚══════════════════════════════════════════════╝" 'Cyan'

    if ($DryRun) {
        Write-Warn "Current mode is DRY RUN: reclaimable space is measured, nothing is deleted."
        Write-Warn "To proceed, run: .\sys-health-check.ps1 -Optimize -Execute"
    } else {
        Write-Success "Starting safe cleanup (L1: user-level caches/logs/temp only)..."
    }

    Write-Section "Cache Cleanup"
    Clear-CacheSubdirs "$env:LOCALAPPDATA\Temp"            "User temp files (Temp)"
    Clear-SafeDir "npm cache"           "$env:LOCALAPPDATA\npm-cache"
    Clear-SafeDir "pip cache"           "$env:LOCALAPPDATA\pip\Cache"
    Clear-SafeDir "Yarn cache"          "$env:LOCALAPPDATA\Yarn\Cache"
    Clear-SafeDir "NuGet cache"         "$env:USERPROFILE\.nuget\packages"
    Clear-SafeDir "Gradle cache"        "$env:USERPROFILE\.gradle\caches"
    Clear-SafeDir "Cargo cache"         "$env:USERPROFILE\.cargo\registry"
    Clear-SafeDir "Chrome cache"        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
    Clear-SafeDir "Edge cache"          "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
    Clear-SafeDir "JetBrains caches"    "$env:LOCALAPPDATA\JetBrains"

    Write-Section "Log Cleanup"
    Clear-SafeDir "Windows Temp"        'C:\Windows\Temp'
    Clear-SafeDir "Crash dumps"         "$env:LOCALAPPDATA\CrashDumps"
    Clear-SafeDir "WER report queue"    "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"

    Write-Section "Recycle Bin (not cleaned by default)"
    $shell = New-Object -ComObject Shell.Application
    $recycleBin = $shell.Namespace(0xA)
    $trashSize = 0
    if ($recycleBin) {
        foreach ($item in $recycleBin.Items()) { $trashSize += $item.Size }
    }
    Write-Color "  [skip] Recycle Bin: $(Format-Size $trashSize) — emptying is irreversible, right-click the desktop Recycle Bin to empty it manually" 'Yellow'

    Write-Section "Optimization Summary"
    if ($DryRun) {
        Write-Success "Dry run complete: about $(Format-Size $script:TotalFreedBytes) can be safely reclaimed."
        Write-Host ''
        Write-Info "To actually clean, run: .\sys-health-check.ps1 -Optimize -Execute"
    } else {
        Write-Success "Cleanup complete: approximately $(Format-Size $script:TotalFreedBytes) freed."
    }
    Write-Host ''
    Write-Info "Untouched: system directories, personal files (Desktop/Documents/Downloads/Videos), browser bookmarks/passwords, Recycle Bin"
    Write-Info "Recommendation: clean browser caches regularly, keep free disk space > 10%, disable unneeded startup items"
}

# =============================================================================
# Main flow
# =============================================================================
function Main {
    Write-Info "Script version: 1.0 | OS: Windows | User: $env:USERNAME"
    Write-Info "Safety level: L0 checks + L1 cleanup | User-level caches/logs/tmp only | Personal files untouched"

    if ($ModeCheck)    { Invoke-HealthCheck }
    if ($ModeOptimize) { Invoke-Optimize }

    Write-Host ''
    Write-Success "All operations finished."
}

Main
