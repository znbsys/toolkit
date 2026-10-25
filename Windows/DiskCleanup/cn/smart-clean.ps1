<#
.SYNOPSIS
    Windows 智能清理脚本
.DESCRIPTION
    扫描可清理项并分类为 [安全] 与 [需判断]，交互确认后删除。
    [安全]   可再生缓存/临时文件/转储，删除无风险
    [需判断] 可能包含用户数据或正在使用，需用户确认
.PARAMETER List
    仅扫描并列出可清理项，不删除
.PARAMETER Yes
    直接删除所有 [安全] 项，[需判断] 项仍会询问
.EXAMPLE
    .\smart-clean.ps1            # 交互确认模式（默认）
    .\smart-clean.ps1 -List      # 仅列出
    .\smart-clean.ps1 -Yes       # 自动删安全项
#>
[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'

$MinSize = 10MB

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

function Get-DirSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { 0 } else { [long]$sum }
    } catch { 0 }
}

# ── 候选清理项定义 ───────────────────────────────────────────────────
$SafeItems   = @()   # PSCustomObject: Path, Desc, Size, Type(Dir/File), Cmd
$JudgedItems = @()

function Add-Item {
    param([string]$Category, [string]$Path, [string]$Desc, [string]$Cmd = '', [string]$Type = 'Dir')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $size = if ($Type -eq 'Dir') { Get-DirSizeBytes $Path } else { (Get-Item -LiteralPath $Path).Length }
    if ($size -lt $MinSize) { return }
    $item = [PSCustomObject]@{ Path = $Path; Desc = $Desc; Size = $size; Type = $Type; Cmd = $Cmd }
    if ($Category -eq 'safe') { $script:SafeItems += $item }
    else                       { $script:JudgedItems += $item }
}

Write-Color "扫描中..." 'DarkGray'

# ── [安全] 系统与应用缓存 ────────────────────────────────────────────
Add-Item safe "$env:LOCALAPPDATA\Temp"                 '系统临时文件 (Temp)'          'Remove-Item -LiteralPath "{0}" -Recurse -Force'
Add-Item safe 'C:\Windows\Temp'                         'Windows Temp'                'Remove-Item -LiteralPath "{0}\*" -Recurse -Force'
Add-Item safe "$env:LOCALAPPDATA\npm-cache"             'npm 缓存'                    'npm cache clean --force'
Add-Item safe "$env:LOCALAPPDATA\pip\Cache"             'pip 缓存'                    'pip cache purge'
Add-Item safe "$env:LOCALAPPDATA\Yarn\Cache"            'Yarn 缓存'                   'yarn cache clean'
Add-Item safe "$env:LOCALAPPDATA\pnpm-cache"            'pnpm 缓存'                   'pnpm store prune'
Add-Item safe "$env:LOCALAPPDATA\NuGet\v3-cache"        'NuGet 缓存'                  ''
Add-Item safe "$env:LOCALAPPDATA\Microsoft\Windows\INetCache" 'IE/系统缓存'           ''
Add-Item safe "$env:LOCALAPPDATA\CrashDumps"            '崩溃转储 (CrashDumps)'       ''
Add-Item safe "$env:LOCALAPPDATA\Minidump"              '蓝屏 Minidump'              ''

# ── [安全] 浏览器缓存 ────────────────────────────────────────────────
$browsers = @(
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",              'Chrome 缓存'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",         'Chrome 代码缓存'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Service Worker\CacheStorage", 'Chrome SW 缓存'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",             'Edge 缓存'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",        'Edge 代码缓存')
)
foreach ($b in $browsers) {
    Add-Item safe $b[0] $b[1] 'Remove-Item -LiteralPath "{0}\*" -Recurse -Force'
}

# ── [安全] 开发工具缓存 ──────────────────────────────────────────────
Add-Item safe "$env:LOCALAPPDATA\JetBrains"             'JetBrains IDE 缓存'          ''
Add-Item safe "$env:USERPROFILE\.gradle\caches"         'Gradle 缓存'                 ''
Add-Item safe "$env:USERPROFILE\.m2\repository"         'Maven 仓库 (可重新下载)'      ''
Add-Item safe "$env:USERPROFILE\.nuget\packages"        'NuGet 包缓存'                ''
Add-Item safe "$env:USERPROFILE\.cargo\registry"        'Cargo Rust 缓存'             ''
Add-Item safe "$env:USERPROFILE\.rustup\downloads"      'Rustup 下载缓存'             ''
Add-Item safe "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*" '缩略图缓存' ''

# ── [安全] 回收站 ────────────────────────────────────────────────────
$trashPaths = @('C:\$Recycle.Bin', "$env:LOCALAPPDATA\Microsoft\Windows\Explorer")
# 回收站用 Shell API 清空更安全，这里仅统计
$shell = New-Object -ComObject Shell.Application
$recycleBin = $shell.Namespace(0xA)  # 10 = Recycle Bin
$trashSize = 0
if ($recycleBin) {
    foreach ($item in $recycleBin.Items()) {
        $trashSize += $item.Size
    }
}
if ($trashSize -gt $MinSize) {
    $SafeItems += [PSCustomObject]@{
        Path = 'RecycleBin'; Desc = '回收站 (清空)'; Size = $trashSize; Type = 'Special'
        Cmd = 'Clear-RecycleBin -Force -ErrorAction SilentlyContinue'
    }
}

# ── [需判断] 项目依赖 ────────────────────────────────────────────────
$devRoots = @("$env:USERPROFILE\source", "$env:USERPROFILE\Projects", "$env:USERPROFILE\dev", "$env:USERPROFILE\Documents")
foreach ($root in $devRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $nodeModules = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'node_modules' }
    foreach ($nm in $nodeModules) {
        $size = Get-DirSizeBytes $nm.FullName
        if ($size -ge 500MB) {
            $rel = $nm.FullName.Replace($env:USERPROFILE, '~')
            Add-Item judged $nm.FullName "项目依赖: $rel (删除需重装)" 'Remove-Item -LiteralPath "{0}" -Recurse -Force'
        }
    }
}

# ── [需判断] 大文件 ──────────────────────────────────────────────────
$bigFileRoots = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents")
foreach ($root in $bigFileRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 200MB } |
        ForEach-Object {
            Add-Item judged $_.FullName "大文件: $($_.Name)" 'Remove-Item -LiteralPath "{0}" -Force' -Type 'File'
        }
}

# ── [需判断] AI 模型缓存 ────────────────────────────────────────────
Add-Item judged "$env:USERPROFILE\.ollama"       'Ollama 模型 (本地推理才用)'    ''
Add-Item judged "$env:USERPROFILE\.cache\huggingface" 'HuggingFace 模型缓存'      ''

# ── 打印列表 ─────────────────────────────────────────────────────────
function Show-List {
    Write-Host ''
    Write-Color "========== 扫描结果 ==========" 'Bold'

    $totalSafe = ($SafeItems | Measure-Object -Property Size -Sum).Sum
    Write-Host ''
    Write-Color ("■ [安全] 可直接删除 (可再生缓存/临时文件)  共 {0}" -f (Format-Size $totalSafe)) 'Green'
    if ($SafeItems.Count -eq 0) {
        Write-Color "  (无)" 'DarkGray'
    } else {
        $i = 1
        foreach ($item in ($SafeItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            Write-Color ("  {0}. {1}" -f $i, $item.Desc) 'Green' -NoNewline
            Write-Color ("  {0}  {1}" -f $disp, (Format-Size $item.Size)) 'DarkGray'
            $i++
        }
    }

    $totalJudged = ($JudgedItems | Measure-Object -Property Size -Sum).Sum
    Write-Host ''
    Write-Color ("■ [需判断] 请确认是否删除 (可能含数据或在使用)  共 {0}" -f (Format-Size $totalJudged)) 'Yellow'
    if ($JudgedItems.Count -eq 0) {
        Write-Color "  (无)" 'DarkGray'
    } else {
        foreach ($item in ($JudgedItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            Write-Color ("  - {0}" -f $item.Desc) 'Yellow' -NoNewline
            Write-Color ("  {0}  {1}" -f $disp, (Format-Size $item.Size)) 'DarkGray'
        }
    }

    Write-Host ''
    Write-Color "选项: -List(仅列出)  默认(交互确认)  -Yes(自动删安全项)" 'DarkGray'
}

# ── 执行清理 ─────────────────────────────────────────────────────────
function Invoke-CleanItem {
    param($Item)
    Write-Color "执行: $($Item.Desc)" 'DarkGray'
    if ($Item.Type -eq 'Special') {
        # 回收站
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Color "  ✓ 已清空" 'Green'
        return
    }
    if ($Item.Cmd) {
        $cmd = $Item.Cmd -f $Item.Path
        try { Invoke-Expression $cmd 2>$null } catch { }
    } else {
        if ($Item.Type -eq 'Dir') {
            Get-ChildItem -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Milliseconds 500
    # 校验
    if ($Item.Type -eq 'Dir' -and (Test-Path -LiteralPath $Item.Path)) {
        $remaining = (Get-ChildItem -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($remaining -gt 0) {
            Write-Color "  ⚠ 目录仍有 $remaining 项残留 (可能被占用)" 'Yellow'
        } else {
            Write-Color "  ✓ 已清理" 'Green'
        }
    } elseif ($Item.Type -eq 'File' -and (Test-Path -LiteralPath $Item.Path)) {
        Write-Color "  ⚠ 可能仍有残留 (文件被占用)" 'Yellow'
    } else {
        Write-Color "  ✓ 已清理" 'Green'
    }
}

function Invoke-Clean {
    Write-Host ''
    Write-Color "── 第 1 步: 处理 [安全] 项 ──" 'Bold'
    if ($SafeItems.Count -eq 0) {
        Write-Color "  (无安全项可清理)" 'DarkGray'
    } else {
        foreach ($item in ($SafeItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            if ($Yes) {
                Write-Color "--yes 自动确认: $($item.Desc)" 'DarkGray'
                Invoke-CleanItem $item
            } else {
                $ans = Read-Host ("删除 [安全] {0} {1} ({2})? [y/N]" -f $item.Desc, $disp, (Format-Size $item.Size))
                if ($ans -match '^[Yy]') { Invoke-CleanItem $item }
                else { Write-Color "  跳过" 'DarkGray' }
            }
        }
    }

    Write-Host ''
    Write-Color "── 第 2 步: 处理 [需判断] 项 ──" 'Bold'
    if ($JudgedItems.Count -eq 0) {
        Write-Color "  (无需判断项)" 'DarkGray'
    } else {
        foreach ($item in ($JudgedItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            $ans = Read-Host ("需判断: {0} {1} ({2}) 确认删除? [y/N]" -f $item.Desc, $disp, (Format-Size $item.Size))
            if ($ans -match '^[Yy]') { Invoke-CleanItem $item }
            else { Write-Color "  跳过" 'DarkGray' }
        }
    }

    Write-Host ''
    Write-Color "✅ 清理结束" 'Green'
}

# ── 主流程 ───────────────────────────────────────────────────────────
Show-List

if ($List) { exit 0 }

Write-Host ''
$confirm = Read-Host "是否开始清理? [y/N]"
if ($confirm -match '^[Yy]') {
    Invoke-Clean
} else {
    Write-Host '已取消，未删除任何内容。'
}
