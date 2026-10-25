<#
.SYNOPSIS
    Windows 按修改时间分析磁盘占用，定位最近磁盘增长原因
.DESCRIPTION
    通过 LastWriteTime 按时间段筛选大文件，帮助定位"最近磁盘是因为什么被占用的"。
    只读脚本，不做任何删除操作。
.PARAMETER Days
    时间窗口(天)，默认 3
.PARAMETER MinSize
    最小文件大小阈值，默认 50MB
.PARAMETER Dirs
    按目录聚合统计
.PARAMETER All
    文件与目录都统计
.EXAMPLE
    .\disk-timeline.ps1
    .\disk-timeline.ps1 -Days 7
    .\disk-timeline.ps1 -Days 7 -MinSize 10MB -All
#>
[CmdletBinding()]
param(
    [int]$Days = 3,
    [string]$MinSize = '50MB',
    [switch]$Dirs,
    [switch]$All
)

$ErrorActionPreference = 'SilentlyContinue'

$ModeFiles = -not $Dirs -or $All
$ModeDirs  = $Dirs -or $All
if (-not $Dirs -and -not $All) { $ModeFiles = $true; $ModeDirs = $false }
if ($All) { $ModeFiles = $true; $ModeDirs = $true }

$MinBytes = switch -Regex ($MinSize) {
    '^\s*(\d+(?:\.\d+)?)\s*[Gg]' { [long]([double]$Matches[1] * 1GB); break }
    '^\s*(\d+(?:\.\d+)?)\s*[Mm]' { [long]([double]$Matches[1] * 1MB); break }
    '^\s*(\d+(?:\.\d+)?)\s*[Kk]' { [long]([double]$Matches[1] * 1KB); break }
    default { [long]$MinSize }
}
$TopN = 20

# ── 颜色 ─────────────────────────────────────────────────────────────
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { '{0:N1}T' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N1}G' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1}M' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0}K' -f ($Bytes / 1KB) }
    else { "${Bytes}B" }
}

# ── 搜索根目录（精选，避免全盘扫描卡死）─────────────────────────────
$SearchRoots = @(
    "$env:LOCALAPPDATA",
    "$env:APPDATA",
    "$env:USERPROFILE\Downloads",
    "$env:USERPROFILE\Documents",
    "$env:USERPROFILE\Desktop",
    "$env:USERPROFILE\.ollama",
    "$env:USERPROFILE\.docker",
    "$env:USERPROFILE\.cache",
    "$env:ProgramFiles",
    "${env:ProgramFiles(x86)}"
)

function Get-RecentLargeFiles {
    param([int]$DaysAgoFrom, [int]$DaysAgoTo = 0)
    $cutFrom = (Get-Date).AddDays(-$DaysAgoFrom)
    $cutTo   = if ($DaysAgoTo -le 0) { Get-Date } else { (Get-Date).AddDays(-($DaysAgoTo - 1)) }

    $all = foreach ($root in $SearchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Length -ge $MinBytes -and
                $_.LastWriteTime -ge $cutFrom -and
                $_.LastWriteTime -lt $cutTo
            }
    }
    $all | Sort-Object Length -Descending | Select-Object -First $TopN
}

# ── 1. 常见增长源体检 ────────────────────────────────────────────────
function Show-Suspects {
    Write-Color "`n══ 常见增长源快速体检 ══" 'Cyan'
    $suspects = @(
        @("$env:LOCALAPPDATA\Temp",                              '系统临时文件'),
        @("$env:LOCALAPPDATA\npm-cache",                          'npm 缓存'),
        @("$env:LOCALAPPDATA\pip\Cache",                          'pip 缓存'),
        @("$env:LOCALAPPDATA\Docker",                             'Docker 数据'),
        @("$env:LOCALAPPDATA\Google\Chrome\User Data",            'Chrome 数据'),
        @("$env:LOCALAPPDATA\Microsoft\Edge\User Data",           'Edge 数据'),
        @("$env:LOCALAPPDATA\JetBrains",                          'JetBrains IDE'),
        @("$env:USERPROFILE\.ollama",                             'Ollama 模型'),
        @("$env:USERPROFILE\.docker",                             'Docker 配置'),
        @("$env:USERPROFILE\Downloads",                           '下载目录'),
        @("$env:USERPROFILE\.cache",                              '通用缓存'),
        @("$env:LOCALAPPDATA\Packages",                           'UWP 应用数据'),
        @('C:\Windows\Temp',                                       '系统 Temp')
    )
    Write-Host ("  {0,-12}  {1}" -f '大小', '目录 (含说明)')
    Write-Host ("  {0,-12}  {1}" -f '----', '----')
    foreach ($s in $suspects) {
        if (Test-Path -LiteralPath $s[0]) {
            $size = (Get-ChildItem -LiteralPath $s[0] -Recurse -File -Force -ErrorAction SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
            if ($null -ne $size -and $size -gt 0) {
                $disp = $s[0].Replace($env:USERPROFILE, '~')
                Write-Color ("  {0,-12}  {1}  {2}" -f (Format-Size $size), $disp, $s[1]) 'Yellow'
            }
        }
    }
}

# ── 2. 按时间段扫描大文件 ───────────────────────────────────────────
function Show-FilesByTime {
    param([string]$Label, [int]$FromDays, [int]$ToDays = 0)
    Write-Color "`n$Label" 'Bold'
    $files = Get-RecentLargeFiles -DaysAgoFrom $FromDays -DaysAgoTo $ToDays
    if (-not $files) {
        Write-Color "  (无 >= $(Format-Size $MinBytes) 的文件)" 'DarkGray'
        return
    }
    foreach ($f in $files) {
        $disp = $f.FullName.Replace($env:USERPROFILE, '~')
        $mt = $f.LastWriteTime.ToString('MM-dd HH:mm')
        Write-Color ("  {0,-8} {1}  {2}" -f (Format-Size $f.Length), $mt, $disp) 'Red'
    }
}

# ── 3. 目录聚合 ──────────────────────────────────────────────────────
function Show-DirsByTime {
    param([string]$Label, [int]$FromDays, [int]$ToDays = 0)
    Write-Color "`n$Label" 'Bold'
    $files = Get-RecentLargeFiles -DaysAgoFrom $FromDays -DaysAgoTo $ToDays
    if (-not $files) {
        Write-Color "  (无)" 'DarkGray'
        return
    }
    $grouped = $files | Group-Object { Split-Path $_.FullName -Parent } | ForEach-Object {
        [PSCustomObject]@{
            Dir   = $_.Name
            Total = ($_.Group | Measure-Object -Property Length -Sum).Sum
            Count = $_.Count
        }
    } | Sort-Object Total -Descending | Select-Object -First $TopN

    Write-Host ("  {0,-10} {1,6}  {2}" -f '累计大小', '文件数', '目录')
    Write-Host ("  {0,-10} {1,6}  {2}" -f '--------', '------', '----')
    foreach ($g in $grouped) {
        $disp = $g.Dir.Replace($env:USERPROFILE, '~')
        Write-Color ("  {0,-10} {1,6}  {2}" -f (Format-Size $g.Total), $g.Count, $disp) 'Red'
    }
}

# ── 主流程 ───────────────────────────────────────────────────────────
Write-Color "════════ 磁盘占用时间线分析 (窗口: 最近 $Days 天) ════════" 'Bold'
Write-Color "阈值 >= $(Format-Size $MinBytes)；扫描常见目录。" 'DarkGray'

Show-Suspects

if ($ModeFiles) {
    Show-FilesByTime -Label "`n══ 最近 24 小时内修改的大文件 (最可能的新增占用) ══" -FromDays 1
    if ($Days -gt 1) {
        Show-FilesByTime -Label "`n══ 最近 2 ~ $Days 天内修改的大文件 ══" -FromDays $Days -ToDays 1
    }
}

if ($ModeDirs) {
    Show-DirsByTime -Label "`n══ 目录聚合: 最近 24 小时写入量 Top $TopN ══" -FromDays 1
    if ($Days -gt 1) {
        Show-DirsByTime -Label "`n══ 目录聚合: 最近 2 ~ $Days 天写入量 Top $TopN ══" -FromDays $Days -ToDays 1
    }
}

Write-Color "`n── 解读建议 ──" 'Bold'
$advice = @'
  • Docker 数据目录变大              → docker system df 查看，必要时 prune
  • Ollama / HuggingFace 模型        → AI 模型下载，按需 ollama rm
  • AppData\Local\Temp 增长          → 系统临时文件，可安全清理
  • npm-cache / pip\Cache 增长       → 包管理器缓存，可安全清理
  • Chrome/Edge Cache 增长           → 浏览器缓存，可安全清理
  • Downloads 新增大文件             → 手动确认后归档/删除
  • JetBrains 目录增长               → IDE 索引/缓存，可在 IDE 内清理
'@
Write-Host $advice
Write-Color "提示: -Dirs 看目录聚合；-Days 7 扩大窗口；-MinSize 10MB 看更小文件。" 'DarkGray'
Write-Host ''
