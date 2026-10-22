<#
.SYNOPSIS
    Windows 磁盘空间扫描报告生成脚本
.DESCRIPTION
    扫描磁盘占用并生成 Markdown 报告，包含各目录占用、大文件、清理建议。
    只读脚本，不做任何删除操作。
.PARAMETER OutputPath
    报告输出路径，默认为脚本同级目录 disk-report-YYYY-MM-DD.md
.EXAMPLE
    .\disk-full-report.ps1
    .\disk-full-report.ps1 -OutputPath C:\reports\disk.md
#>
[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot ("disk-report-{0}.md" -f (Get-Date -Format 'yyyy-MM-dd'))
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

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

function Write-Report($Text) { Add-Content -LiteralPath $OutputPath -Value $Text -Encoding UTF8 }
function Write-Section($Title) { Write-Report "`n## $Title`n" }

# ── 报告头 ───────────────────────────────────────────────────────────
$reportHeader = @"
# Windows 磁盘空间扫描报告

> 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
> 扫描脚本：`disk-full-report.ps1`

"@
Set-Content -LiteralPath $OutputPath -Value $reportHeader -Encoding UTF8
Write-Host "扫描中..." -NoNewline

# ── 1. 总体概览 ──────────────────────────────────────────────────────
Write-Section "1. 总体概览"
$drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
$reportTable = @('| 卷 | 总量 | 已用 | 可用 | 使用率 |', '|------|------|------|------|--------|')
foreach ($d in $drives) {
    $totalGB = [math]::Round($d.Size / 1GB, 1)
    $usedGB  = [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 1)
    $freeGB  = [math]::Round($d.FreeSpace / 1GB, 1)
    $pct = if ($d.Size -gt 0) { [int](($d.Size - $d.FreeSpace) / $d.Size * 100) } else { 0 }
    $reportTable += "| $($d.DeviceID) | ${totalGB}G | ${usedGB}G | ${freeGB}G | ${pct}% |"
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ── 2. 用户目录占用 ──────────────────────────────────────────────────
Write-Section "2. 用户目录一级子目录占用 Top 15"
$homePath = $env:USERPROFILE
$dirs = Get-ChildItem -LiteralPath $homePath -Directory -Force -ErrorAction SilentlyContinue
$topDirs = foreach ($d in $dirs) {
    $size = Get-DirSizeBytes $d.FullName
    [PSCustomObject]@{ Size = $size; Path = $d.FullName }
} | Sort-Object Size -Descending | Select-Object -First 15

$reportTable = @('| 目录 | 大小 |', '|------|------|')
foreach ($t in $topDirs) {
    if ($t.Size -gt 0) {
        $disp = $t.Path.Replace($homePath, '~')
        $reportTable += "| ``$disp`` | $(Format-Size $t.Size) |"
    }
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ── 3. 开发/缓存大目录 ──────────────────────────────────────────────
Write-Section "3. 开发与缓存目录"
$cacheDirs = @(
    @("$env:LOCALAPPDATA\Temp",        '系统临时文件'),
    @("$env:LOCALAPPDATA\npm-cache",   'npm 缓存'),
    @("$env:LOCALAPPDATA\pip\Cache",   'pip 缓存'),
    @("$env:LOCALAPPDATA\Docker",      'Docker 数据'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data", 'Chrome 数据'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data", 'Edge 数据'),
    @("$env:LOCALAPPDATA\JetBrains",   'JetBrains IDE 数据'),
    @("$env:USERPROFILE\.ollama",      'Ollama 模型'),
    @("$env:USERPROFILE\.docker",      'Docker CLI 配置'),
    @("$env:USERPROFILE\.cache",       '通用缓存'),
    @("$env:USERPROFILE\Downloads",    '下载目录'),
    @("$env:LOCALAPPDATA\Packages",    'UWP 应用数据'),
    @("$env:LOCALAPPDATA\Microsoft\WindowsApps", 'Windows 应用缓存')
)
$reportTable = @('| 目录 | 说明 | 大小 |', '|------|------|------|')
foreach ($item in $cacheDirs) {
    $p = $item[0]; $desc = $item[1]
    if (Test-Path -LiteralPath $p) {
        $size = Get-DirSizeBytes $p
        $disp = $p.Replace($homePath, '~')
        $reportTable += "| ``$disp`` | $desc | $(Format-Size $size) |"
    }
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ── 4. 大文件扫描 ────────────────────────────────────────────────────
Write-Section "4. 大型文件 (>200MB, Top 20)"
$scanDirs = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Videos")
$bigFiles = foreach ($sd in $scanDirs) {
    if (Test-Path -LiteralPath $sd) {
        Get-ChildItem -LiteralPath $sd -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 200MB }
    }
}
$topFiles = $bigFiles | Sort-Object Length -Descending | Select-Object -First 20
if ($topFiles) {
    $reportTable = @('| 文件 | 大小 | 修改时间 |', '|------|------|----------|')
    foreach ($f in $topFiles) {
        $disp = $f.FullName.Replace($homePath, '~')
        $reportTable += "| ``$disp`` | $(Format-Size $f.Length) | $($f.LastWriteTime.ToString('MM-dd HH:mm')) |"
    }
    Write-Report ($reportTable -join "`n")
} else {
    Write-Report "上述目录中未找到大于 200MB 的文件。"
}
Write-Report ""

# ── 5. 浏览器缓存 ────────────────────────────────────────────────────
Write-Section "5. 浏览器缓存"
$browsers = @(
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",           'Chrome Cache'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",      'Chrome Code Cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",          'Edge Cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",     'Edge Code Cache')
)
$reportTable = @('| 浏览器缓存 | 大小 |', '|------------|------|')
foreach ($b in $browsers) {
    if (Test-Path -LiteralPath $b[0]) {
        $size = Get-DirSizeBytes $b[0]
        $reportTable += "| $($b[1]) | $(Format-Size $size) |"
    }
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ── 6. 清理建议 ──────────────────────────────────────────────────────
Write-Section "6. 清理建议"
Write-Report @"
| 项目 | 建议操作 |
|------|---------|
| 系统临时文件 | 删除 ``$env:LOCALAPPDATA\Temp\*`` |
| npm 缓存 | ``npm cache clean --force`` |
| pip 缓存 | ``pip cache purge`` |
| Docker | ``docker system prune -a --volumes -f`` |
| Ollama 模型 | ``ollama rm <model>``（按需删） |
| Chrome/Edge 缓存 | 浏览器设置内清除，或删 Cache 目录 |
| 回收站 | 右键桌面回收站 → 清空 |

> ⚠️ 清理前请确认数据是否仍需使用，尤其是 Docker 数据和 Ollama 模型。
"@

Write-Report ""
Write-Report "---"
Write-Report ""
Write-Report "*报告由 ``disk-full-report.ps1`` 自动生成 | 清理前请确认数据重要性*"

Write-Host "`r扫描完成。"
Write-Host ''
Write-Color "报告已生成：$OutputPath" 'Green'
Write-Host "行数：$((Get-Content -LiteralPath $OutputPath | Measure-Object -Line).Lines)"
Write-Host ''
