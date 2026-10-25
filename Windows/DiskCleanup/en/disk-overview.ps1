<#
.SYNOPSIS
    Quick disk usage overview for Windows.
.DESCRIPTION
    Shows volume usage, top-level home directory sizes, and optional system
    or large-directory detail. Read-only: it does not delete anything.
.PARAMETER Top
    Also scan top-level system directories
.PARAMETER Deep
    Also show detail for large dev/cache directories
.EXAMPLE
    .\disk-overview.ps1
    .\disk-overview.ps1 -Top
    .\disk-overview.ps1 -Deep
#>
[CmdletBinding()]
param(
    [switch]$Top,
    [switch]$Deep
)

$ErrorActionPreference = 'SilentlyContinue'

# ---------- Helpers ----------
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }

function Get-DirSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { 0 } else { [long]$sum }
    } catch { 0 }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { '{0:N1}T' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N1}G' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1}M' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0}K' -f ($Bytes / 1KB) }
    else { "${Bytes}B" }
}

function Get-ColorByPercent {
    param([int]$Pct)
    if ($Pct -ge 90) { 'Red' }
    elseif ($Pct -ge 70) { 'Yellow' }
    else { 'Green' }
}

# ---------- 1. Volume overview ----------
function Show-Volumes {
    Write-Color "`n── Volume Usage Overview ──" 'Cyan'
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
    if (-not $drives) {
        Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
            $total = $_.Used + $_.Free
            $pct = if ($total -gt 0) { [int](($_.Used / $total) * 100) } else { 0 }
            $color = Get-ColorByPercent $pct
            Write-Color ("  {0,-8} Total {1,-8} Used {2,-8} Free {3,-8} {4}%" -f `
                $_.Name, (Format-Size $total), (Format-Size $_.Used), (Format-Size $_.Free), $pct) $color
        }
        return
    }

    Write-Host ("  {0,-10} {1,8} {2,8} {3,8} {4,6}" -f 'Volume', 'Total', 'Used', 'Free', 'Use%')
    Write-Host ("  {0,-10} {1,8} {2,8} {3,8} {4,6}" -f '------', '-----', '----', '----', '----')
    foreach ($d in $drives) {
        $totalGB  = [math]::Round($d.Size / 1GB, 1)
        $usedBytes = $d.Size - $d.FreeSpace
        $usedGB   = [math]::Round($usedBytes / 1GB, 1)
        $freeGB   = [math]::Round($d.FreeSpace / 1GB, 1)
        $pct = if ($d.Size -gt 0) { [int](($usedBytes / $d.Size) * 100) } else { 0 }
        $color = Get-ColorByPercent $pct
        Write-Color ("  {0,-10} {1,7}G {2,7}G {3,7}G {4,5}%" -f $d.DeviceID, $totalGB, $usedGB, $freeGB, $pct) $color

        # Progress bar
        $filled = [int]($pct / 5)
        $bar = ('█' * $filled) + ('░' * (20 - $filled))
        Write-Color ("           [$bar] {0}%" -f $pct) $color
    }
}

# ---------- 2. Home directory usage ----------
function Show-HomeTop {
    param([int]$N = 10)
    Write-Color "`n── Top $N Directories in Home ──" 'Cyan'
    $homePath = $env:USERPROFILE
    $dirs = Get-ChildItem -LiteralPath $homePath -Directory -Force -ErrorAction SilentlyContinue
    $results = foreach ($d in $dirs) {
        $size = Get-DirSizeBytes $d.FullName
        [PSCustomObject]@{ Size = $size; Path = $d.FullName }
    }
    $results | Sort-Object Size -Descending | Select-Object -First $N | ForEach-Object {
        Write-Color ("  {0,-10} {1}" -f (Format-Size $_.Size), $_.Path.Replace($homePath, '~')) 'White'
    }
}

# ---------- 3. Top-level system directories ----------
function Show-SystemTop {
    Write-Color "`n── Top-Level System Directory Usage (may be slow) ──" 'Cyan'
    Write-Color "  Scanning..." 'DarkGray'
    $targets = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:LOCALAPPDATA",
        "$env:APPDATA",
        'C:\Windows\Temp',
        "$env:TEMP"
    )
    $results = foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            $size = Get-DirSizeBytes $t
            [PSCustomObject]@{ Size = $size; Path = $t }
        }
    }
    $results | Sort-Object Size -Descending | ForEach-Object {
        Write-Color ("  {0,-10} {1}" -f (Format-Size $_.Size), $_.Path) 'White'
    }
}

# ---------- 4. Large directory detail ----------
function Show-Deep {
    Write-Color "`n── Large Directory Detail ──" 'Cyan'
    $targets = @(
        "$env:LOCALAPPDATA\Temp",
        "$env:LOCALAPPDATA\npm-cache",
        "$env:LOCALAPPDATA\pip\Cache",
        "$env:LOCALAPPDATA\Docker",
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\JetBrains",
        "$env:USERPROFILE\.ollama",
        "$env:USERPROFILE\.docker",
        "$env:USERPROFILE\Downloads",
        "$env:USERPROFILE\.cache",
        "$env:LOCALAPPDATA\Packages"
    )
    Write-Host ("  {0,-60} {1,8}" -f 'Path', 'Size')
    Write-Host ("  {0,-60} {1,8}" -f '----', '----')
    foreach ($t in $targets) {
        if (Test-Path -LiteralPath $t) {
            $size = Get-DirSizeBytes $t
            if ($size -gt 0) {
                $disp = $t.Replace($env:USERPROFILE, '~')
                Write-Color ("  {0,-60} {1,8}" -f $disp, (Format-Size $size)) 'White'
            }
        }
    }
}

# ---------- Main ----------
Write-Color "══════════ Disk Usage Overview ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ══════════" 'Bold'

Show-Volumes
Show-HomeTop -N 10

if ($Top)   { Show-SystemTop }
if ($Deep)  { Show-Deep }

Write-Color "`nTip: use -Top for system directories, -Deep for dev/cache detail" 'DarkGray'
Write-Host ''
