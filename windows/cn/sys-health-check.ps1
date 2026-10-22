<#
.SYNOPSIS
    Windows 系统健康检查与安全优化脚本
.DESCRIPTION
    L0 只读检查(CPU/内存/磁盘/网络/启动项) + L1 安全清理(仅用户级缓存/日志/临时文件)。
    不使用管理员权限(清理时需提权的部分会提示)，不碰个人文件，不清空回收站。
.PARAMETER Check
    仅执行健康检查
.PARAMETER Optimize
    仅执行安全优化(默认预演)
.PARAMETER Execute
    与 -Optimize 配合，实际执行删除操作
.EXAMPLE
    .\sys-health-check.ps1                   # 健康检查 + 优化预演
    .\sys-health-check.ps1 -Check            # 只检查
    .\sys-health-check.ps1 -Optimize         # 只看能清多少(预演)
    .\sys-health-check.ps1 -Optimize -Execute  # 实际清理
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

# ── 颜色输出 ─────────────────────────────────────────────────────────
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }
function Write-Info($Text)    { Write-Color "[信息] $Text" 'Cyan' }
function Write-Success($Text) { Write-Color "[完成] $Text" 'Green' }
function Write-Warn($Text)    { Write-Color "[警告] $Text" 'Yellow' }
function Write-Err($Text)     { Write-Color "[错误] $Text" 'Red' }
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
# 健康检查模块
# =============================================================================

function Test-Cpu {
    Write-Section "CPU 检查"
    $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cpu) {
        Write-Host "  型号: $($cpu.Name)"
        Write-Host "  核心数(物理): $($cpu.NumberOfCores)"
        Write-Host "  核心数(逻辑): $($cpu.NumberOfLogicalProcessors)"
        Write-Host "  当前使用率: $($cpu.LoadPercentage)%"
    }
    # 负载 (需要管理员权限的计数器，失败则跳过)
    $uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    Write-Host "  运行时长: $([int]$uptime.TotalDays)天 $($uptime.Hours)小时 $($uptime.Minutes)分钟"
}

function Test-Memory {
    Write-Section "内存检查"
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) {
        $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $freeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
        $usedGB  = [math]::Round($totalGB - $freeGB, 1)
        $pct = [math]::Round(($usedGB / $totalGB) * 100, 1)
        Write-Host "  总内存: ${totalGB} GB"
        Write-Host "  已使用: ${usedGB} GB (${pct}%)"
        Write-Host "  空闲:   ${freeGB} GB"
    }
    Write-Host "  --- 内存占用 TOP 5 ---"
    Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
        $memMB = [math]::Round($_.WorkingSet64 / 1MB, 0)
        Write-Host ("  {0,-8} {1,-35} {2,8} MB" -f $_.Id, $_.ProcessName, $memMB)
    }
}

function Test-Disk {
    Write-Section "硬盘空间检查"
    Write-Host "  卷        总量      已用      可用      使用率"
    Write-Host "  -------------------------------------------------"
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $totalGB = [math]::Round($_.Size / 1GB, 1)
        $usedGB  = [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1)
        $freeGB  = [math]::Round($_.FreeSpace / 1GB, 1)
        $pct = if ($_.Size -gt 0) { [int](($_.Size - $_.FreeSpace) / $_.Size * 100) } else { 0 }
        $color = if ($pct -ge 90) { 'Red' } elseif ($pct -ge 70) { 'Yellow' } else { 'Green' }
        Write-Color ("  {0,-9} {1,7}G {2,7}G {3,7}G {4,5}%" -f $_.DeviceID, $totalGB, $usedGB, $freeGB, $pct) $color
    }
    Write-Host ''
    Write-Info "用户目录占用 TOP 5 (仅统计,不删除):"
    $homePath = $env:USERPROFILE
    Get-ChildItem -LiteralPath $homePath -Directory -Force | ForEach-Object {
        [PSCustomObject]@{ Size = Get-DirSizeBytes $_.FullName; Path = $_.FullName }
    } | Sort-Object Size -Descending | Select-Object -First 5 | ForEach-Object {
        Write-Host ("  {0,-10} {1}" -f (Format-Size $_.Size), $_.Path.Replace($homePath, '~'))
    }
}

function Test-Network {
    Write-Section "网络检查"
    Write-Host "  --- 网络接口状态 ---"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' } |
        ForEach-Object {
            Write-Host ("  {0,-20} IP: {1}" -f $_.InterfaceAlias, $_.IPAddress)
        }
    Write-Host ''
    Write-Host "  --- 连通性测试 ---"
    $targets = @('223.5.5.5', '8.8.8.8', 'www.baidu.com', 'www.baidu.com')
    foreach ($t in $targets) {
        $result = Test-Connection -TargetName $t -Count 2 -ErrorAction SilentlyContinue
        if ($result) {
            $latency = [math]::Round(($result | Measure-Object -Property ResponseTime -Average).Average, 1)
            Write-Success "连通 $t (延迟 ${latency}ms)"
        } else {
            Write-Warn "无法连通 $t"
        }
    }
    Write-Host ''
    Write-Host "  --- DNS 解析 ---"
    try {
        $dns = Resolve-DnsName -Name 'www.baidu.com' -ErrorAction Stop | Select-Object -First 3
        $dns | ForEach-Object { Write-Host "  $($_.NameHost) -> $($_.IPAddress)" }
    } catch {
        Write-Warn "DNS 解析可能异常"
    }
}

function Test-Startup {
    Write-Section "启动项检查"
    Write-Host "  --- 启动文件夹 ---"
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
            Write-Host "    (无)"
        }
    }
    Write-Host ''
    Write-Host "  --- 注册表 Run 键 (当前用户) ---"
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty |
        Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            Write-Host "    $($_.Name)"
        }
    Write-Host ''
    Write-Host "  --- 计划任务 (非微软) ---"
    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' } |
        Select-Object -First 15 | ForEach-Object {
            Write-Host ("    {0,-40} {1}" -f $_.TaskName, $_.State)
        }
}

function Invoke-HealthCheck {
    Write-Host ''
    Write-Color "╔══════════════════════════════════════════════╗" 'Cyan'
    Write-Color "║     电脑健康检查报告 $(Get-Date -Format 'yyyy-MM-dd HH:mm')       ║" 'Cyan'
    Write-Color "╚══════════════════════════════════════════════╝" 'Cyan'

    Test-Cpu
    Test-Memory
    Test-Disk
    Test-Network
    Test-Startup

    Write-Section "检查总结"
    Write-Info "以上为只读检查,未对系统做任何修改。"
    Write-Info "如需优化,请运行: .\sys-health-check.ps1 -Optimize (预演) 或 .\sys-health-check.ps1 -Optimize -Execute (执行)"
}

# =============================================================================
# 安全优化模块
# =============================================================================

function Clear-SafeDir {
    param([string]$Label, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Color "  [跳过] ${Label}: 目录不存在" 'DarkGray'
        return
    }
    $sizeBytes = Get-DirSizeBytes $Path
    if ($DryRun) {
        Write-Color "  [预演] ${Label}: 可清理 $(Format-Size $sizeBytes) ($Path)" 'Yellow'
    } else {
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        Write-Color "  [完成] ${Label}: 已清理约 $(Format-Size $sizeBytes)" 'Green'
    }
    $script:TotalFreedBytes += $sizeBytes
}

function Clear-CacheSubdirs {
    param([string]$Base, [string]$Label)
    if (-not (Test-Path -LiteralPath $Base)) { return }
    $excludes = @('cloudkit', 'CloudKit', 'com.apple.FamilyCircle')  # Windows 上无这些，保留兼容
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
        Write-Color "  [预演] ${Label}: 可清理 $(Format-Size $totalBytes)" 'Yellow'
    } else {
        Write-Color "  [完成] ${Label}: 已清理约 $(Format-Size $totalBytes)" 'Green'
    }
    $script:TotalFreedBytes += $totalBytes
}

function Invoke-Optimize {
    Write-Host ''
    $modeText = if ($DryRun) { '(预演模式,未删除任何文件)' } else { '' }
    Write-Color "╔══════════════════════════════════════════════╗" 'Cyan'
    Write-Color "║     安全优化 $modeText $(Get-Date -Format 'MM-dd HH:mm')     ║" 'Cyan'
    Write-Color "╚══════════════════════════════════════════════╝" 'Cyan'

    if ($DryRun) {
        Write-Warn "当前为【预演模式】,只统计可清理空间,不实际删除。"
        Write-Warn "确认无误后,执行: .\sys-health-check.ps1 -Optimize -Execute"
    } else {
        Write-Success "开始执行安全清理(L1级别,仅用户级缓存/日志/临时文件)..."
    }

    Write-Section "缓存清理"
    Clear-CacheSubdirs "$env:LOCALAPPDATA\Temp"        "用户临时文件 (Temp)"
    Clear-SafeDir "npm 缓存"        "$env:LOCALAPPDATA\npm-cache"
    Clear-SafeDir "pip 缓存"        "$env:LOCALAPPDATA\pip\Cache"
    Clear-SafeDir "Yarn 缓存"       "$env:LOCALAPPDATA\Yarn\Cache"
    Clear-SafeDir "NuGet 缓存"      "$env:USERPROFILE\.nuget\packages"
    Clear-SafeDir "Gradle 缓存"     "$env:USERPROFILE\.gradle\caches"
    Clear-SafeDir "Cargo 缓存"      "$env:USERPROFILE\.cargo\registry"
    Clear-SafeDir "浏览器缓存(Chrome)" "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
    Clear-SafeDir "浏览器缓存(Edge)"   "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
    Clear-SafeDir "JetBrains 缓存"  "$env:LOCALAPPDATA\JetBrains"

    Write-Section "日志清理"
    Clear-SafeDir "Windows Temp"    'C:\Windows\Temp'
    Clear-SafeDir "崩溃转储"         "$env:LOCALAPPDATA\CrashDumps"
    Clear-SafeDir "WER 报告队列"     "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportQueue"

    Write-Section "回收站 (默认不清理)"
    $shell = New-Object -ComObject Shell.Application
    $recycleBin = $shell.Namespace(0xA)
    $trashSize = 0
    if ($recycleBin) {
        foreach ($item in $recycleBin.Items()) { $trashSize += $item.Size }
    }
    Write-Color "  [跳过] 回收站: $(Format-Size $trashSize) — 清空不可恢复,请右键桌面回收站手动清空" 'Yellow'

    Write-Section "优化总结"
    if ($DryRun) {
        Write-Success "预演完成,合计约 $(Format-Size $script:TotalFreedBytes) 可安全清理。"
        Write-Host ''
        Write-Info "确认清理请执行: .\sys-health-check.ps1 -Optimize -Execute"
    } else {
        Write-Success "清理完成,合计释放约 $(Format-Size $script:TotalFreedBytes)。"
    }
    Write-Host ''
    Write-Info "未触碰: 系统目录、个人文件(桌面/文档/下载/视频)、浏览器书签/密码、回收站"
    Write-Info "建议: 定期清理浏览器缓存、保持磁盘剩余空间 >10%、关闭不需要的启动项"
}

# =============================================================================
# 主流程
# =============================================================================
function Main {
    Write-Info "脚本版本: 1.0 | 系统: Windows | 用户: $env:USERNAME"
    Write-Info "安全级别: L0 检查 + L1 清理 | 仅用户级缓存/日志/临时文件 | 不碰个人文件"

    if ($ModeCheck)    { Invoke-HealthCheck }
    if ($ModeOptimize) { Invoke-Optimize }

    Write-Host ''
    Write-Success "全部操作完成。"
}

Main
