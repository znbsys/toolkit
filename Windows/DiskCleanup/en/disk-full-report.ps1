<#
.SYNOPSIS
    Full disk space scan report generator for Windows.
.DESCRIPTION
    Scans disk usage and generates a Markdown report with per-directory sizes,
    large files, browser caches and cleanup suggestions.
    Read-only: it does not delete anything.
.PARAMETER OutputPath
    Report output path; defaults to disk-report-YYYY-MM-DD.md next to the script.
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

# ---------- Helpers ----------
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

# ---------- Report header ----------
$reportHeader = @"
# Windows Disk Space Scan Report

> Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
> Script: ``disk-full-report.ps1``

"@
Set-Content -LiteralPath $OutputPath -Value $reportHeader -Encoding UTF8
Write-Host "Scanning..." -NoNewline

# ---------- 1. Overview ----------
Write-Section "1. Overview"
$drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue
$reportTable = @('| Volume | Total | Used | Free | Use% |', '|--------|-------|------|------|------|')
foreach ($d in $drives) {
    $totalGB = [math]::Round($d.Size / 1GB, 1)
    $usedGB  = [math]::Round(($d.Size - $d.FreeSpace) / 1GB, 1)
    $freeGB  = [math]::Round($d.FreeSpace / 1GB, 1)
    $pct = if ($d.Size -gt 0) { [int](($d.Size - $d.FreeSpace) / $d.Size * 100) } else { 0 }
    $reportTable += "| $($d.DeviceID) | ${totalGB}G | ${usedGB}G | ${freeGB}G | ${pct}% |"
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ---------- 2. User directory usage ----------
Write-Section "2. Top 15 Home Directory Sizes"
$homePath = $env:USERPROFILE
$dirs = Get-ChildItem -LiteralPath $homePath -Directory -Force -ErrorAction SilentlyContinue
$topDirs = foreach ($d in $dirs) {
    $size = Get-DirSizeBytes $d.FullName
    [PSCustomObject]@{ Size = $size; Path = $d.FullName }
} | Sort-Object Size -Descending | Select-Object -First 15

$reportTable = @('| Directory | Size |', '|-----------|------|')
foreach ($t in $topDirs) {
    if ($t.Size -gt 0) {
        $disp = $t.Path.Replace($homePath, '~')
        $reportTable += "| ``$disp`` | $(Format-Size $t.Size) |"
    }
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ---------- 3. Dev & cache directories ----------
Write-Section "3. Development & Cache Directories"
$cacheDirs = @(
    @("$env:LOCALAPPDATA\Temp",            'System temporary files'),
    @("$env:LOCALAPPDATA\npm-cache",       'npm cache'),
    @("$env:LOCALAPPDATA\pip\Cache",       'pip cache'),
    @("$env:LOCALAPPDATA\Docker",          'Docker data'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data", 'Chrome data'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data", 'Edge data'),
    @("$env:LOCALAPPDATA\JetBrains",       'JetBrains IDE data'),
    @("$env:USERPROFILE\.ollama",          'Ollama models'),
    @("$env:USERPROFILE\.docker",          'Docker CLI config'),
    @("$env:USERPROFILE\.cache",           'General cache'),
    @("$env:USERPROFILE\Downloads",        'Downloads folder'),
    @("$env:LOCALAPPDATA\Packages",        'UWP app data'),
    @("$env:LOCALAPPDATA\Microsoft\WindowsApps", 'Windows app cache')
)
$reportTable = @('| Directory | Notes | Size |', '|-----------|-------|------|')
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

# ---------- 4. Large files ----------
Write-Section "4. Large Files (>200MB, Top 20)"
$scanDirs = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Videos")
$bigFiles = foreach ($sd in $scanDirs) {
    if (Test-Path -LiteralPath $sd) {
        Get-ChildItem -LiteralPath $sd -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 200MB }
    }
}
$topFiles = $bigFiles | Sort-Object Length -Descending | Select-Object -First 20
if ($topFiles) {
    $reportTable = @('| File | Size | Modified |', '|------|------|----------|')
    foreach ($f in $topFiles) {
        $disp = $f.FullName.Replace($homePath, '~')
        $reportTable += "| ``$disp`` | $(Format-Size $f.Length) | $($f.LastWriteTime.ToString('MM-dd HH:mm')) |"
    }
    Write-Report ($reportTable -join "`n")
} else {
    Write-Report "No files larger than 200MB found in the directories above."
}
Write-Report ""

# ---------- 5. Browser caches ----------
Write-Section "5. Browser Caches"
$browsers = @(
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",       'Chrome Cache'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",  'Chrome Code Cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",      'Edge Cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache", 'Edge Code Cache')
)
$reportTable = @('| Browser Cache | Size |', '|---------------|------|')
foreach ($b in $browsers) {
    if (Test-Path -LiteralPath $b[0]) {
        $size = Get-DirSizeBytes $b[0]
        $reportTable += "| $($b[1]) | $(Format-Size $size) |"
    }
}
Write-Report ($reportTable -join "`n")
Write-Report ""

# ---------- 6. Cleanup suggestions ----------
Write-Section "6. Cleanup Suggestions"
Write-Report @"
| Item | Suggested Action |
|------|------------------|
| System temp files | Delete the contents of ``$env:LOCALAPPDATA\Temp`` |
| npm cache | ``npm cache clean --force`` |
| pip cache | ``pip cache purge`` |
| Docker | ``docker system prune -a --volumes -f`` |
| Ollama models | ``ollama rm <model>`` (as needed) |
| Chrome/Edge caches | Clear in browser settings, or delete the Cache directories |
| Recycle Bin | Right-click the Recycle Bin on the desktop -> Empty |

> ⚠️ Verify the data is not needed before cleanup, especially Docker data and Ollama models.
"@

Write-Report ""
Write-Report "---"
Write-Report ""
Write-Report "*Report generated by ``disk-full-report.ps1`` | Verify data importance before cleanup*"

Write-Host "`rScan complete."
Write-Host ''
Write-Color "Report generated: $OutputPath" 'Green'
Write-Host "Lines: $((Get-Content -LiteralPath $OutputPath | Measure-Object -Line).Lines)"
Write-Host ''
