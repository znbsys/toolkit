# Windows Disk & System Maintenance Scripts (PowerShell)

English-language Windows disk analysis and system maintenance scripts,
counterparts of [../../mac/en/](../../mac/en/). Every deletion is confirmed or
dry-run by default, and personal files are never touched.

> If an execution policy blocks the scripts, first run:
> `Set-ExecutionPolicy -Scope Process Bypass`

## Scripts

| Script | Purpose | Safety level |
|--------|---------|--------------|
| `disk-overview.ps1` | Quick disk usage overview (volumes + home top 10) | Read-only |
| `disk-full-report.ps1` | Full disk scan → Markdown report | Read-only |
| `disk-timeline.ps1` | Find what grew the disk recently, by modification time | Read-only |
| `smart-clean.ps1` | Interactive cleanup (safe / review groups) | Confirm before delete |
| `sys-health-check.ps1` | Health checks + L1 safe cleanup | Dry run by default |

---

## disk-overview.ps1

Quick look at current disk usage.

```powershell
.\disk-overview.ps1           # volume usage + top home directories
.\disk-overview.ps1 -Top      # also scan top-level system directories (Program Files, AppData, Temp, ...)
.\disk-overview.ps1 -Deep     # also show detail for large dev/cache directories
```

- Colored usage percentages / progress bar (green / yellow / red; ≥70% yellow, ≥90% red)
- `-Deep` covers `Temp`, `npm-cache`, `pip\Cache`, `Docker`, Chrome/Edge user data,
  `JetBrains`, `.ollama`, `.docker`, `Downloads`, `.cache`, UWP `Packages`, and more
- Read-only, deletes nothing

---

## disk-full-report.ps1

Generates a full disk scan report (Markdown file).

```powershell
.\disk-full-report.ps1                              # writes disk-report-YYYY-MM-DD.md next to the script
.\disk-full-report.ps1 -OutputPath C:\reports\d.md  # custom output path
```

The report contains 6 sections:

1. **Overview** — total / used / free / usage percent per fixed volume
2. **Top 15 home directory subdirectories**
3. **Dev & cache directories** — Temp, npm, pip, Docker, Chrome/Edge user data,
   JetBrains, Ollama, `.docker`, `.cache`, Downloads, UWP `Packages`, WindowsApps
4. **Large files (>200MB, Top 20)** — Downloads / Desktop / Documents / Videos
5. **Browser caches** — Chrome / Edge Cache and Code Cache
6. **Cleanup suggestions** — matching commands for temp files, npm/pip caches,
   Docker, Ollama, browser caches, Recycle Bin, ...

- Read-only; only writes the report file, deletes nothing

---

## disk-timeline.ps1

Analyzes disk usage by file modification time (LastWriteTime) to answer "what
filled my disk recently?".

```powershell
.\disk-timeline.ps1                 # default: last 3 days, files >= 50MB
.\disk-timeline.ps1 -Days 7         # widen the window to 7 days
.\disk-timeline.ps1 -MinSize 10MB   # lower the size threshold (K/M/G accepted)
.\disk-timeline.ps1 -Dirs           # aggregate by directory
.\disk-timeline.ps1 -All            # files + directories
```

- Walks curated roots (AppData Local/Roaming, Downloads, Documents, Desktop,
  `.ollama`, `.docker`, `.cache`, Program Files) so it never stalls on a full-disk scan
- Starts with a quick check of common growth sources (Temp, npm/pip, Docker,
  Chrome/Edge, JetBrains, Ollama, Downloads, UWP packages, Windows Temp, ...)
- Files are grouped into "last 24 hours" and "last 2 ~ N days"; directory
  aggregation shows total size and file count
- Ends with interpretation tips for each growth source
- Read-only, deletes nothing

---

## smart-clean.ps1

Interactive cleanup. Scan results are grouped into:

- **[SAFE]** regenerable caches / temp files / dumps — no risk
- **[REVIEW]** may contain user data or be in use — needs confirmation

```powershell
.\smart-clean.ps1 -List   # list only, delete nothing
.\smart-clean.ps1         # interactive confirmation (recommended, default)
.\smart-clean.ps1 -Yes    # auto-delete all [SAFE] items; [REVIEW] still asks per item
```

Only items ≥10MB are listed.

| Category | Covered items |
|----------|---------------|
| [SAFE] | User `Temp`, `C:\Windows\Temp` |
| [SAFE] | npm / pip / Yarn / pnpm / NuGet caches, IE/system cache |
| [SAFE] | Crash dumps (CrashDumps), blue-screen Minidumps |
| [SAFE] | Chrome / Edge Cache, Code Cache, Service Worker cache |
| [SAFE] | JetBrains, Gradle, Maven, NuGet packages, Cargo, Rustup, thumbnail cache |
| [SAFE] | Recycle Bin (size via Shell API; cleared with `Clear-RecycleBin` after confirmation) |
| [REVIEW] | Project `node_modules` (>500MB; scans `source`/`Projects`/`dev`/`Documents`) |
| [REVIEW] | Files ≥200MB in Downloads / Desktop / Documents |
| [REVIEW] | Ollama models, HuggingFace model cache |

- Every deletion is verified afterwards; leftovers (files in use) are reported

---

## sys-health-check.ps1

System health check + L1 safe cleanup.

```powershell
.\sys-health-check.ps1                     # health check + cleanup dry run (default)
.\sys-health-check.ps1 -Check              # checks only
.\sys-health-check.ps1 -Optimize           # cleanup preview only
.\sys-health-check.ps1 -Optimize -Execute  # actually delete
```

**Checks (L0, read-only):** CPU / memory / disk / network (interfaces +
connectivity + DNS) / startup items

Startup items covered: Startup folders (user + common), registry Run keys
(current user), non-Microsoft scheduled tasks

**L1 cleanup scope:**

- Caches: user `Temp`, npm / pip / Yarn / NuGet / Gradle / Cargo, Chrome / Edge, JetBrains
- Logs: `C:\Windows\Temp`, crash dumps, WER report queue
- Recycle Bin: skipped by default — only sized and reported for manual emptying

**Safety promises:**

- Never touches system directories (`C:\Windows`, `C:\Program Files`, ...)
- Never touches personal files (Desktop / Documents / Downloads / Videos)
- Never empties the Recycle Bin (irreversible — only reported, left to the user)
- Only deletes regenerable user-level caches, logs and temporary files
- Dry run by default; `-Optimize -Execute` is required to actually delete

---

## macOS counterpart

| macOS | Windows | Description |
|-------|---------|-------------|
| `disk-overview.sh` | `disk-overview.ps1` | Disk overview |
| `disk-full-report.sh` | `disk-full-report.ps1` | Full report |
| `disk-timeline.sh` | `disk-timeline.ps1` | Timeline analysis |
| `smart-clean.sh` | `smart-clean.ps1` | Interactive cleanup |
| `sys-health-check.sh` | `sys-health-check.ps1` | Health check |

## Which script should I use?

| Situation | Recommended script |
|-----------|--------------------|
| Quick look at free space | `disk-overview.ps1` |
| Monthly full health report | `disk-full-report.ps1` |
| Disk suddenly full, find the cause | `disk-timeline.ps1` |
| Routine cache cleanup | `smart-clean.ps1` |
| System feels slow, full check-up | `sys-health-check.ps1` |
