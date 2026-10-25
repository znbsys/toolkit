# macOS Disk & System Maintenance Scripts

English-language macOS disk analysis and system maintenance scripts (Bash).
Everything is read-only or confirm-before-delete, never uses sudo, and never
touches personal files.

## Scripts

| Script | Purpose | Safety level |
|--------|---------|--------------|
| `disk-overview.sh` | Quick disk usage overview (volumes + home top 10) | Read-only |
| `disk-full-report.sh` | Full disk scan → Markdown report | Read-only |
| `disk-timeline.sh` | Find what grew the disk recently, by modification time | Read-only |
| `smart-clean.sh` | Interactive cleanup (safe / review groups) | Confirm before delete |
| `sys-health-check.sh` | Health checks + L1 safe cleanup (Linux compatible) | Dry run by default |

---

## disk-overview.sh

Quick look at current disk usage.

```bash
bash disk-overview.sh           # volume usage + top home directories
bash disk-overview.sh --top     # also scan top-level system directories (/Applications, /Library, ...)
bash disk-overview.sh --deep    # also show large dev/cache directories
bash disk-overview.sh -h        # show help
```

- Colored usage percentages / progress bar (green / yellow / red; ≥70% yellow, ≥90% red)
- `--deep` covers `~/Library/Caches`, `~/Library/Developer`, `~/.npm`, `~/.cache`,
  `~/.ollama/models`, `~/workspace`, `/Applications`, and more
- Read-only, deletes nothing

---

## disk-full-report.sh

Generates a full disk scan report (Markdown file). Large directories are
measured with parallel `du` calls to keep the scan fast.

```bash
bash disk-full-report.sh                    # writes disk-report-YYYY-MM-DD.md next to the script's parent dir
bash disk-full-report.sh /path/to/out.md    # custom output path
```

The report contains 10 sections:

1. **Overview** — usage of `/` and `/System/Volumes/Data`
2. **User Library** — Application Support, Caches, Developer, Logs, Docker data + Top 15 ranking
3. **Hidden dev / AI directories** — `.cache`, `.ollama/models`, `.npm`, `.lingma`,
   Podman, `.android`, `.vscode`, `.cursor`, `.cargo`, `.gradle`, `.go`, ...
4. **Dev environments & apps** — `/Applications` Top 10, Xcode DerivedData/Archives/
   iOS DeviceSupport, `~/workspace`, `~/projects`
5. **Large files** — files >200MB in Downloads/Desktop/Documents/Movies/Music/Pictures (Top 20)
6. **Docker / Podman** — `docker system df` output + data directory size
7. **Ollama models** — `ollama list` + total model size (if installed)
8. **Cache detail** — uv, npm, `~/.cache` subdirectories
9. **Cleanup suggestions** — reclaimable-space estimates per item (Docker / uv /
   Ollama / npm / Xcode simulators / heap dumps)
10. **Cleanup commands** — copy-paste ready commands

- Read-only; only writes the report file, deletes nothing

---

## disk-timeline.sh

Analyzes disk usage by file modification time to answer "what filled my disk
recently?".

```bash
bash disk-timeline.sh              # default: last 3 days, files >= 50M
bash disk-timeline.sh --days 7     # widen the window to 7 days
bash disk-timeline.sh --min 10M    # lower the size threshold (K/M/G accepted)
bash disk-timeline.sh --dirs       # aggregate by directory
bash disk-timeline.sh --all        # files + directories
bash disk-timeline.sh -h           # show help
```

- Uses the macOS Spotlight index (`mdfind`) for second-level queries; falls
  back to `find` (curated directories only) when Spotlight is unavailable
- Starts with a quick check of common growth sources (Docker / Ollama / caches /
  logs / Downloads / Xcode, ...)
- Files are grouped into "last 24 hours" and "last 2 ~ N days"; directory
  aggregation shows total size and file count
- Ends with interpretation tips for each growth source
- Read-only, deletes nothing

---

## smart-clean.sh

Interactive cleanup. Scan results are grouped into:

- **[SAFE]** regenerable caches / temp files / dumps — no risk
- **[REVIEW]** may contain user data or be in use — needs confirmation

```bash
bash smart-clean.sh --list    # list only, delete nothing
bash smart-clean.sh --clean   # interactive confirmation (recommended, default)
bash smart-clean.sh --yes     # auto-delete all [SAFE] items; [REVIEW] still asks per item
```

Only items ≥10MB are listed; items ≥200MB get a highlighted warning.

| Category | Covered items |
|----------|---------------|
| [SAFE] | `~/Library/Caches`, `~/Library/Logs` |
| [SAFE] | npm / node-gyp / pip / Homebrew caches |
| [SAFE] | Xcode DerivedData, simulator caches |
| [SAFE] | JVM/IDE heap dumps (`*.hprof`), `/cores` (if writable) |
| [SAFE] | Trash (asked interactively; auto-emptied under `--yes` via Finder AppleScript) |
| [REVIEW] | Codex runtimes, HuggingFace model cache |
| [REVIEW] | Global npm packages (single package >200MB) |
| [REVIEW] | Project `node_modules` (>500MB) |
| [REVIEW] | Large files in Downloads (>200MB) and home directory (>1GB, Library etc. excluded) |

- Every deletion is verified afterwards; leftovers (e.g. files in use) are reported

---

## sys-health-check.sh

System health check + L1 safe cleanup, compatible with macOS and Linux (systemd).

```bash
bash sys-health-check.sh                  # health check + cleanup dry run (default)
bash sys-health-check.sh --check          # checks only
bash sys-health-check.sh --optimize       # cleanup preview only
bash sys-health-check.sh --optimize --execute  # actually delete
bash sys-health-check.sh --help           # show help
```

**Checks (L0, read-only):** CPU / memory / disk / network (connectivity + DNS) / startup items

- macOS: LaunchAgents, LaunchDaemons, login items
- Linux: enabled systemd units, `~/.config/autostart`, shell rc files

**L1 cleanup scope:**

- macOS: `~/Library/Caches` subdirectories (system-critical caches such as
  CloudKit are skipped), Xcode DerivedData, CrashReporter, `~/Library/Logs`,
  Chrome/Safari/Firefox caches
- Linux: `~/.cache` subdirectories, thumbnails / pip / npm / Yarn / Docker buildx
  caches, `/tmp` files older than 7 days, user logs

**Safety promises:**

- Never uses sudo, never touches system directories (/System, /Library, /usr, ...)
- Never touches personal files (Desktop / Documents / Downloads / Pictures / Videos)
- Never empties the Trash / Recycle Bin (irreversible — only reported, left to the user)
- Only deletes regenerable user-level caches, logs and temporary files
- Dry run by default; `--optimize --execute` is required to actually delete

---

## Which script should I use?

| Situation | Recommended script |
|-----------|--------------------|
| Quick look at free space | `disk-overview.sh` |
| Monthly full health report | `disk-full-report.sh` |
| Disk suddenly full, find the cause | `disk-timeline.sh` |
| Routine cache cleanup | `smart-clean.sh` |
| System feels slow, full check-up | `sys-health-check.sh` |

## Windows version

The matching PowerShell scripts live in [DiskCleanup](../../Windows/DiskCleanup/en/).
