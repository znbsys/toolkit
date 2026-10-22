<#
.SYNOPSIS
    Interactive cleanup script for Windows.
.DESCRIPTION
    Scans cleanable items and groups them into [SAFE] and [REVIEW]:
    [SAFE]   Regenerable caches / temp files / dumps, no risk
    [REVIEW] May contain user data or be in use, needs confirmation
.PARAMETER List
    Scan and list cleanable items only, delete nothing
.PARAMETER Yes
    Delete all [SAFE] items without prompts; [REVIEW] items still ask
.EXAMPLE
    .\smart-clean.ps1            # interactive mode (default)
    .\smart-clean.ps1 -List      # list only
    .\smart-clean.ps1 -Yes       # auto-delete safe items
#>
[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Yes
)

$ErrorActionPreference = 'SilentlyContinue'

$MinSize = 10MB

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

function Get-DirSizeBytes {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { 0 } else { [long]$sum }
    } catch { 0 }
}

# ---------- Candidate definitions ----------
$SafeItems   = @()   # PSCustomObject: Path, Desc, Size, Type(Dir/File/Special), Cmd
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

Write-Color "Scanning..." 'DarkGray'

# ---------- [SAFE] system & app caches ----------
Add-Item safe "$env:LOCALAPPDATA\Temp"                          'System temp files (Temp)' 'Remove-Item -LiteralPath "{0}" -Recurse -Force'
Add-Item safe 'C:\Windows\Temp'                                 'Windows Temp'             'Remove-Item -LiteralPath "{0}\*" -Recurse -Force'
Add-Item safe "$env:LOCALAPPDATA\npm-cache"                     'npm cache'                'npm cache clean --force'
Add-Item safe "$env:LOCALAPPDATA\pip\Cache"                     'pip cache'                'pip cache purge'
Add-Item safe "$env:LOCALAPPDATA\Yarn\Cache"                    'Yarn cache'               'yarn cache clean'
Add-Item safe "$env:LOCALAPPDATA\pnpm-cache"                    'pnpm cache'               'pnpm store prune'
Add-Item safe "$env:LOCALAPPDATA\NuGet\v3-cache"                'NuGet cache'              ''
Add-Item safe "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"   'IE/system cache'          ''
Add-Item safe "$env:LOCALAPPDATA\CrashDumps"                    'Crash dumps'              ''
Add-Item safe "$env:LOCALAPPDATA\Minidump"                      'BSOD minidumps'           ''

# ---------- [SAFE] browser caches ----------
$browsers = @(
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",                         'Chrome cache'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",                    'Chrome code cache'),
    @("$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Service Worker\CacheStorage",   'Chrome service worker cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",                        'Edge cache'),
    @("$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",                   'Edge code cache')
)
foreach ($b in $browsers) {
    Add-Item safe $b[0] $b[1] 'Remove-Item -LiteralPath "{0}\*" -Recurse -Force'
}

# ---------- [SAFE] dev tool caches ----------
Add-Item safe "$env:LOCALAPPDATA\JetBrains"             'JetBrains IDE caches'          ''
Add-Item safe "$env:USERPROFILE\.gradle\caches"         'Gradle caches'                 ''
Add-Item safe "$env:USERPROFILE\.m2\repository"         'Maven repository (redownloadable)' ''
Add-Item safe "$env:USERPROFILE\.nuget\packages"        'NuGet package cache'           ''
Add-Item safe "$env:USERPROFILE\.cargo\registry"        'Cargo (Rust) cache'            ''
Add-Item safe "$env:USERPROFILE\.rustup\downloads"      'Rustup download cache'         ''
Add-Item safe "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*" 'Thumbnail cache' ''

# ---------- [SAFE] Recycle Bin ----------
# The Shell API is used for accurate size; actual emptying uses Clear-RecycleBin
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
        Path = 'RecycleBin'; Desc = 'Recycle Bin (empty)'; Size = $trashSize; Type = 'Special'
        Cmd = 'Clear-RecycleBin -Force -ErrorAction SilentlyContinue'
    }
}

# ---------- [REVIEW] project dependencies ----------
$devRoots = @("$env:USERPROFILE\source", "$env:USERPROFILE\Projects", "$env:USERPROFILE\dev", "$env:USERPROFILE\Documents")
foreach ($root in $devRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $nodeModules = Get-ChildItem -LiteralPath $root -Directory -Recurse -Depth 3 -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'node_modules' }
    foreach ($nm in $nodeModules) {
        $size = Get-DirSizeBytes $nm.FullName
        if ($size -ge 500MB) {
            $rel = $nm.FullName.Replace($env:USERPROFILE, '~')
            Add-Item judged $nm.FullName "Project deps: $rel (needs reinstall after delete)" 'Remove-Item -LiteralPath "{0}" -Recurse -Force'
        }
    }
}

# ---------- [REVIEW] large files ----------
$bigFileRoots = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents")
foreach ($root in $bigFileRoots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -ge 200MB } |
        ForEach-Object {
            Add-Item judged $_.FullName "Large file: $($_.Name)" 'Remove-Item -LiteralPath "{0}" -Force' -Type 'File'
        }
}

# ---------- [REVIEW] AI model caches ----------
Add-Item judged "$env:USERPROFILE\.ollama"              'Ollama models (needed for local inference)' ''
Add-Item judged "$env:USERPROFILE\.cache\huggingface"   'HuggingFace model cache'                    ''

# ---------- Print the list ----------
function Show-List {
    Write-Host ''
    Write-Color "========== Scan Results ==========" 'Bold'

    $totalSafe = ($SafeItems | Measure-Object -Property Size -Sum).Sum
    Write-Host ''
    Write-Color ("■ [SAFE] Ready to delete (regenerable caches/temp files)  total {0}" -f (Format-Size $totalSafe)) 'Green'
    if ($SafeItems.Count -eq 0) {
        Write-Color "  (none)" 'DarkGray'
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
    Write-Color ("■ [REVIEW] Confirm before deleting (may hold data or be in use)  total {0}" -f (Format-Size $totalJudged)) 'Yellow'
    if ($JudgedItems.Count -eq 0) {
        Write-Color "  (none)" 'DarkGray'
    } else {
        foreach ($item in ($JudgedItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            Write-Color ("  - {0}" -f $item.Desc) 'Yellow' -NoNewline
            Write-Color ("  {0}  {1}" -f $disp, (Format-Size $item.Size)) 'DarkGray'
        }
    }

    Write-Host ''
    Write-Color "Options: -List(list only)  default(interactive)  -Yes(auto-delete SAFE items)" 'DarkGray'
}

# ---------- Run a deletion ----------
function Invoke-CleanItem {
    param($Item)
    Write-Color "Running: $($Item.Desc)" 'DarkGray'
    if ($Item.Type -eq 'Special') {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Color "  ✓ Emptied" 'Green'
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
    # Verify the result
    if ($Item.Type -eq 'Dir' -and (Test-Path -LiteralPath $Item.Path)) {
        $remaining = (Get-ChildItem -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        if ($remaining -gt 0) {
            Write-Color "  ⚠ $remaining item(s) remain (possibly in use)" 'Yellow'
        } else {
            Write-Color "  ✓ Cleaned" 'Green'
        }
    } elseif ($Item.Type -eq 'File' -and (Test-Path -LiteralPath $Item.Path)) {
        Write-Color "  ⚠ Possible residue (file in use)" 'Yellow'
    } else {
        Write-Color "  ✓ Cleaned" 'Green'
    }
}

function Invoke-Clean {
    Write-Host ''
    Write-Color "── Step 1: [SAFE] items ──" 'Bold'
    if ($SafeItems.Count -eq 0) {
        Write-Color "  (no safe items to clean)" 'DarkGray'
    } else {
        foreach ($item in ($SafeItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            if ($Yes) {
                Write-Color "--yes auto-confirmed: $($item.Desc)" 'DarkGray'
                Invoke-CleanItem $item
            } else {
                $ans = Read-Host ("Delete [SAFE] {0} {1} ({2})? [y/N]" -f $item.Desc, $disp, (Format-Size $item.Size))
                if ($ans -match '^[Yy]') { Invoke-CleanItem $item }
                else { Write-Color "  Skipped" 'DarkGray' }
            }
        }
    }

    Write-Host ''
    Write-Color "── Step 2: [REVIEW] items ──" 'Bold'
    if ($JudgedItems.Count -eq 0) {
        Write-Color "  (no review items)" 'DarkGray'
    } else {
        foreach ($item in ($JudgedItems | Sort-Object Size -Descending)) {
            $disp = $item.Path.Replace($env:USERPROFILE, '~')
            $ans = Read-Host ("Review: {0} {1} ({2}) confirm delete? [y/N]" -f $item.Desc, $disp, (Format-Size $item.Size))
            if ($ans -match '^[Yy]') { Invoke-CleanItem $item }
            else { Write-Color "  Skipped" 'DarkGray' }
        }
    }

    Write-Host ''
    Write-Color "✅ Cleanup finished" 'Green'
}

# ---------- Main ----------
Show-List

if ($List) { exit 0 }

Write-Host ''
$confirm = Read-Host "Start cleanup? [y/N]"
if ($confirm -match '^[Yy]') {
    Invoke-Clean
} else {
    Write-Host 'Cancelled, nothing was deleted.'
}
