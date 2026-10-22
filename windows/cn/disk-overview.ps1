<#
.SYNOPSIS
    Windows 磁盘占用快速显示脚本
.DESCRIPTION
    显示各卷使用率、家目录一级子目录占用 Top N，可选系统目录与大目录明细。
    只读脚本，不做任何删除操作。
.PARAMETER Top
    追加显示系统顶层目录占用
.PARAMETER Deep
    追加显示开发/缓存大目录明细
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

# ── 颜色输出 ─────────────────────────────────────────────────────────
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }

# ── 工具函数 ─────────────────────────────────────────────────────────
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

# ── 1. 卷使用概览 ────────────────────────────────────────────────────
function Show-Volumes {
    Write-Color "`n── 卷使用概览 ──" 'Cyan'
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
    if (-not $drives) {
        # 回退到 PSDrive
        Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
            $total = $_.Used + $_.Free
            $pct = if ($total -gt 0) { [int](($_.Used / $total) * 100) } else { 0 }
            $color = Get-ColorByPercent $pct
            Write-Color ("  {0,-8} 总量 {1,-8} 已用 {2,-8} 可用 {3,-8} {4}%" -f `
                $_.Name, (Format-Size $total), (Format-Size $_.Used), (Format-Size $_.Free), $pct) $color
        }
        return
    }

    Write-Host ("  {0,-10} {1,8} {2,8} {3,8} {4,6}" -f '卷', '总量', '已用', '可用', '使用率')
    Write-Host ("  {0,-10} {1,8} {2,8} {3,8} {4,6}" -f '----', '----', '----', '----', '----')
    foreach ($d in $drives) {
        $totalGB  = [math]::Round($d.Size / 1GB, 1)
        $usedGB   = [math]::Round($d.FreeSpace / 1GB, 1)   # placeholder, recalc below
        $usedBytes = $d.Size - $d.FreeSpace
        $freeBytes = $d.FreeSpace
        $usedGB   = [math]::Round($usedBytes / 1GB, 1)
        $freeGB   = [math]::Round($freeBytes / 1GB, 1)
        $pct = if ($d.Size -gt 0) { [int](($usedBytes / $d.Size) * 100) } else { 0 }
        $color = Get-ColorByPercent $pct
        Write-Color ("  {0,-10} {1,7}G {2,7}G {3,7}G {4,5}%" -f $d.DeviceID, $totalGB, $usedGB, $freeGB, $pct) $color

        # 进度条
        $filled = [int]($pct / 5)
        $bar = ('█' * $filled) + ('░' * (20 - $filled))
        Write-Color ("           [$bar] {0}%" -f $pct) $color
    }
}

# ── 2. 家目录占用 ────────────────────────────────────────────────────
function Show-HomeTop {
    param([int]$N = 10)
    Write-Color "`n── 家目录一级子目录占用 Top $N ──" 'Cyan'
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

# ── 3. 系统顶层目录 ──────────────────────────────────────────────────
function Show-SystemTop {
    Write-Color "`n── 系统顶层目录占用 (可能较慢) ──" 'Cyan'
    Write-Color "  扫描中..." 'DarkGray'
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

# ── 4. 大目录明细 ────────────────────────────────────────────────────
function Show-Deep {
    Write-Color "`n── 大目录明细 ──" 'Cyan'
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
    Write-Host ("  {0,-60} {1,8}" -f '路径', '大小')
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

# ── 主流程 ───────────────────────────────────────────────────────────
Write-Color "══════════ 磁盘占用概览 ($(Get-Date -Format 'yyyy-MM-dd HH:mm')) ══════════" 'Bold'

Show-Volumes
Show-HomeTop -N 10

if ($Top)   { Show-SystemTop }
if ($Deep)  { Show-Deep }

Write-Color "`n提示: -Top 查看系统顶层目录，-Deep 查看开发大目录明细" 'DarkGray'
Write-Host ''
