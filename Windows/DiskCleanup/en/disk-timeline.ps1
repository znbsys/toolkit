<#
.SYNOPSIS
    Analyze disk usage by modification time on Windows to find what has been
    occupying the disk recently.
.DESCRIPTION
    Filters large files by LastWriteTime within a time window, helping to
    answer "what caused my disk to fill up recently?".
    Read-only: it does not delete anything.
.PARAMETER Days
    Time window in days, default 3
.PARAMETER MinSize
    Minimum file size threshold, default 50MB
.PARAMETER Dirs
    Aggregate by directory
.PARAMETER All
    Show both files and directories
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

$ModeFiles = $true
$ModeDirs  = $false
if ($All) { $ModeFiles = $true; $ModeDirs = $true }
elseif ($Dirs) { $ModeFiles = $false; $ModeDirs = $true }

$MinBytes = switch -Regex ($MinSize) {
    '^\s*(\d+(?:\.\d+)?)\s*[Gg]' { [long]([double]$Matches[1] * 1GB); break }
    '^\s*(\d+(?:\.\d+)?)\s*[Mm]' { [long]([double]$Matches[1] * 1MB); break }
    '^\s*(\d+(?:\.\d+)?)\s*[Kk]' { [long]([double]$Matches[1] * 1KB); break }
    default { [long]$MinSize }
}
$TopN = 20

# ---------- Colors ----------
function Write-Color($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { '{0:N1}T' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N1}G' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1}M' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0}K' -f ($Bytes / 1KB) }
    else { "${Bytes}B" }
}

# ---------- Search roots (curated, to avoid a full-disk crawl) ----------
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

# ---------- 1. Common growth sources quick check ----------
function Show-Suspects {
    Write-Color "`n══ Common Growth Sources - Quick Check ══" 'Cyan'
    $suspects = @(
        @("$env:LOCALAPPDATA\Temp",                       'System temp files'),
        @("$env:LOCALAPPDATA\npm-cache",                   'npm cache'),
        @("$env:LOCALAPPDATA\pip\Cache",                   'pip cache'),
        @("$env:LOCALAPPDATA\Docker",                      'Docker data'),
        @("$env:LOCALAPPDATA\Google\Chrome\User Data",     'Chrome data'),
        @("$env:LOCALAPPDATA\Microsoft\Edge\User Data",    'Edge data'),
        @("$env:LOCALAPPDATA\JetBrains",                   'JetBrains IDE'),
        @("$env:USERPROFILE\.ollama",                      'Ollama models'),
        @("$env:USERPROFILE\.docker",                      'Docker config'),
        @("$env:USERPROFILE\Downloads",                    'Downloads folder'),
        @("$env:USERPROFILE\.cache",                       'General cache'),
        @("$env:LOCALAPPDATA\Packages",                    'UWP app data'),
        @('C:\Windows\Temp',                               'System Temp')
    )
    Write-Host ("  {0,-12}  {1}" -f 'Size', 'Directory')
    Write-Host ("  {0,-12}  {1}" -f '----', '---------')
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

# ---------- 2. Large files by time window ----------
function Show-FilesByTime {
    param([string]$Label, [int]$FromDays, [int]$ToDays = 0)
    Write-Color "`n$Label" 'Bold'
    $files = Get-RecentLargeFiles -DaysAgoFrom $FromDays -DaysAgoTo $ToDays
    if (-not $files) {
        Write-Color "  (no files >= $(Format-Size $MinBytes))" 'DarkGray'
        return
    }
    foreach ($f in $files) {
        $disp = $f.FullName.Replace($env:USERPROFILE, '~')
        $mt = $f.LastWriteTime.ToString('MM-dd HH:mm')
        Write-Color ("  {0,-8} {1}  {2}" -f (Format-Size $f.Length), $mt, $disp) 'Red'
    }
}

# ---------- 3. Aggregate by directory ----------
function Show-DirsByTime {
    param([string]$Label, [int]$FromDays, [int]$ToDays = 0)
    Write-Color "`n$Label" 'Bold'
    $files = Get-RecentLargeFiles -DaysAgoFrom $FromDays -DaysAgoTo $ToDays
    if (-not $files) {
        Write-Color "  (none)" 'DarkGray'
        return
    }
    $grouped = $files | Group-Object { Split-Path $_.FullName -Parent } | ForEach-Object {
        [PSCustomObject]@{
            Dir   = $_.Name
            Total = ($_.Group | Measure-Object -Property Length -Sum).Sum
            Count = $_.Count
        }
    } | Sort-Object Total -Descending | Select-Object -First $TopN

    Write-Host ("  {0,-10} {1,6}  {2}" -f 'Size', 'Files', 'Directory')
    Write-Host ("  {0,-10} {1,6}  {2}" -f '----', '-----', '---------')
    foreach ($g in $grouped) {
        $disp = $g.Dir.Replace($env:USERPROFILE, '~')
        Write-Color ("  {0,-10} {1,6}  {2}" -f (Format-Size $g.Total), $g.Count, $disp) 'Red'
    }
}

# ---------- Main ----------
Write-Color "════════ Disk Usage Timeline (window: last $Days days) ════════" 'Bold'
Write-Color "Threshold >= $(Format-Size $MinBytes); scanning common directories." 'DarkGray'

Show-Suspects

if ($ModeFiles) {
    Show-FilesByTime -Label "`n══ Large files modified in the last 24 hours (most likely new usage) ══" -FromDays 1
    if ($Days -gt 1) {
        Show-FilesByTime -Label "`n══ Large files modified in the last 2 ~ $Days days ══" -FromDays $Days -ToDays 1
    }
}

if ($ModeDirs) {
    Show-DirsByTime -Label "`n══ Directory aggregation: writes in the last 24 hours (Top $TopN) ══" -FromDays 1
    if ($Days -gt 1) {
        Show-DirsByTime -Label "`n══ Directory aggregation: writes in the last 2 ~ $Days days (Top $TopN) ══" -FromDays $Days -ToDays 1
    }
}

Write-Color "`n── How to read this ──" 'Bold'
$advice = @'
  • Docker data directory growing       → run `docker system df`, prune if needed
  • Ollama / HuggingFace models         → AI model downloads, `ollama rm <model>`
  • AppData\Local\Temp growing          → system temp files, safe to clean
  • npm-cache / pip\Cache growing       → package manager caches, safe to clean
  • Chrome/Edge Cache growing           → browser caches, safe to clean
  • New large files in Downloads        → archive or delete manually after review
  • JetBrains directory growing         → IDE indexes/caches, clear inside the IDE
'@
Write-Host $advice
Write-Color "Tip: -Dirs for directory aggregation, -Days 7 to widen the window, -MinSize 10MB for smaller files." 'DarkGray'
Write-Host ''
