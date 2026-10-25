#!/bin/bash
# disk-full-report.sh - Full disk space scan report generator for macOS
# Usage: bash disk-full-report.sh [output-path]
# Default output: ./disk-report-$(date +%F).md
#
# Strategy: collect data with a small number of batched du calls instead of
# per-directory du. All du commands run in the background in parallel, then
# the results are aggregated.

set -u

OUTPUT="${1:-$(dirname "$0")/../disk-report-$(date +%F).md}"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Helpers ─────────────────────────────────────────────────────────
section() { printf "\n## %s\n\n" "$1" >> "$OUTPUT"; }
w() { echo "$@" >> "$OUTPUT"; }

# Run du in the background, wait later, and capture its output.
# $1 = variable name used to store the result
# $2 = path to measure
bgdu() {
  local var=$1 path=$2
  du -sh "$path" 2>/dev/null > "$TMPDIR/$var" &
  echo $! >> "$TMPDIR/pids"
}

# Wait until all background jobs are done
wait_du() {
  [ ! -f "$TMPDIR/pids" ] && return
  while IFS= read -r pid; do
    wait "$pid" 2>/dev/null || true
  done < "$TMPDIR/pids"
}

# Read the size from a previously stored result
getsize() {
  local var=$1
  [ -f "$TMPDIR/$var" ] && awk '{print $1}' "$TMPDIR/$var" || echo "?"
}

start_spinner() {
  printf "  ⏳ Scanning..."
}
stop_spinner() {
  printf "\r  ✅ Scan complete\n"
}

# ── Start report ───────────────────────────────────────────────────
cat > "$OUTPUT" <<- HEADER
	# Mac Disk Space Scan Report

	> Generated: $(date '+%Y-%m-%d %H:%M:%S')
	> Script: \`scripts/disk-full-report.sh\`

HEADER

start_spinner

# ── PHASE 1: batched du scan (all large directories in parallel) ───
# Key Library subdirectories
bgdu lib_AdSupport   "$HOME/Library/Application Support"
bgdu lib_AdGoogle    "$HOME/Library/Application Support/Google"
bgdu lib_AdJetBrains "$HOME/Library/Application Support/JetBrains"
bgdu lib_AdClaude    "$HOME/Library/Application Support/Claude"
bgdu lib_AdCode      "$HOME/Library/Application Support/Code"
bgdu lib_Caches      "$HOME/Library/Caches"
bgdu lib_Developer   "$HOME/Library/Developer"
bgdu lib_Logs        "$HOME/Library/Logs"
bgdu lib_DockerData  "$HOME/Library/Containers/com.docker.docker/Data"

# Hidden directories
bgdu dot_cache      "$HOME/.cache"
bgdu dot_uv         "$HOME/.cache/uv"
bgdu dot_ollama     "$HOME/.ollama/models"
bgdu dot_npm        "$HOME/.npm"
bgdu dot_lingma     "$HOME/.lingma"
bgdu dot_podman     "$HOME/.local/share/containers"
bgdu dot_android    "$HOME/.android"
bgdu dot_vscode     "$HOME/.vscode"
bgdu dot_cursor     "$HOME/.cursor"
bgdu dot_cargo      "$HOME/.cargo"
bgdu dot_gradle     "$HOME/.gradle"
bgdu dot_pubcache   "$HOME/.pub-cache"
bgdu dot_go         "$HOME/.go"
bgdu dot_docker     "$HOME/.docker"

# Development environment
bgdu apps           "/Applications"
du -sh /Applications/*/ 2>/dev/null | sort -rh > "$TMPDIR/apps_sub" &
echo $! >> "$TMPDIR/pids"
bgdu lib_dev        "/Library/Developer"
bgdu coresim        "/Library/Developer/CoreSimulator"
bgdu xc_derived     "$HOME/Library/Developer/Xcode/DerivedData"
bgdu xc_archives    "$HOME/Library/Developer/Xcode/Archives"
bgdu xc_iosdevsp    "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
bgdu workspace      "$HOME/workspace"
bgdu projects       "$HOME/projects"

# Library total (also in the background, for progress reporting)
bgdu lib_total       "$HOME/Library"

# Large files
bgdu hprof          "$HOME/java_error_in_idea.hprof"

# Wait for all du jobs to finish
wait_du
stop_spinner

# ── 1. Overview ─────────────────────────────────────────────────────
section "1. Overview"
{
  df -h /
  echo ""
  df -h /System/Volumes/Data 2>/dev/null
} >> "$OUTPUT" 2>/dev/null
echo "" >> "$OUTPUT"

DATA_USED=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $3}')
DATA_TOTAL=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $2}')
DATA_AVAIL=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
w "**Data volume (\`/System/Volumes/Data\`): $DATA_USED used / $DATA_TOTAL total, $DATA_AVAIL available**"

# ── 2. Library ──────────────────────────────────────────────────────
section "2. User Library Directory"

LIB_TOTAL=$(getsize lib_total)
w "**\`~/Library\` total size: $LIB_TOTAL**"
w ""
w "| Subdirectory | Size |"
w "|--------------|------|"

run_row() { local sz=$(getsize "$1"); [ -n "$sz" ] && [ "$sz" != "?" ] && w "| \`$2\` | $sz |"; }

run_row lib_AdSupport   "~/Library/Application Support"
run_row lib_AdGoogle    "~/Library/Application Support/Google"
run_row lib_AdJetBrains "~/Library/Application Support/JetBrains"
run_row lib_AdClaude    "~/Library/Application Support/Claude"
run_row lib_AdCode      "~/Library/Application Support/Code"
run_row lib_Caches      "~/Library/Caches"
run_row lib_Developer   "~/Library/Developer"
run_row lib_Logs        "~/Library/Logs"
run_row lib_DockerData  "~/Library/Containers/com.docker.docker/Data"

w ""
w "**Library subdirectories (Top 15):**"
w ""
{ du -sh "$HOME"/Library/*/ 2>/dev/null | sort -rh | head -15; } >> "$OUTPUT"

# ── 3. Hidden dev/AI directories ────────────────────────────────────
section "3. Hidden Dev / AI Directories"

w "| Directory | Size | Notes |"
w "|-----------|------|-------|"

while IFS='|' read -r key dir desc; do
  # Trim whitespace
  key="${key// /}"
  dir="${dir// /}"
  sz=$(getsize "$key")
  [ -n "$sz" ] && [ "$sz" != "?" ] && w "| \`~/$dir\` | $sz | $desc |"
done <<- DIRS
	dot_cache     |.cache                 |General cache
	dot_uv        |.cache/uv              |uv (Python) cache
	dot_ollama    |.ollama/models         |Ollama AI models
	dot_npm       |.npm                   |npm cache
	dot_lingma    |.lingma                |Lingma AI assistant
	dot_podman    |.local/share/containers|Podman container data
	dot_android   |.android               |Android SDK/AVD
	dot_vscode    |.vscode                |VS Code data
	dot_cursor    |.cursor                |Cursor IDE data
	dot_cargo     |.cargo                 |Cargo (Rust) cache
	dot_gradle    |.gradle                |Gradle cache
	dot_pubcache  |.pub-cache             |Flutter/Dart package cache
	dot_go        |.go                    |Go module cache
	dot_docker    |.docker                |Docker CLI config
DIRS

w ""
w "**All \`~/.xx\` directories (Top 15):**"
w ""
{ du -sh "$HOME"/.[!.]* 2>/dev/null | sort -rh | head -15; } >> "$OUTPUT"

# ── 4. Dev environment & applications ───────────────────────────────
section "4. Dev Environment & Applications"

w "| Directory | Size |"
w "|-----------|------|"

run_row apps       "/Applications"
run_row lib_dev    "/Library/Developer"
run_row coresim    "/Library/Developer/CoreSimulator"
run_row xc_derived "~/Library/Developer/Xcode/DerivedData"
run_row xc_archives "~/Library/Developer/Xcode/Archives"
run_row xc_iosdevsp "~/Library/Developer/Xcode/iOS DeviceSupport"
run_row workspace  "~/workspace"
run_row projects   "~/projects"

w ""
w "**Largest Applications (Top 10):**"
w ""
{ [ -f "$TMPDIR/apps_sub" ] && sort -rh "$TMPDIR/apps_sub" | head -10; } >> "$OUTPUT"

# ── 5. Large files ──────────────────────────────────────────────────
section "5. Large Files"

w "**Quick scan of known large directories (> 200MB, Top 20):**"
w ""
BIGFILE_TMP=$(mktemp)
for scan_dir in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "$HOME/Movies" "$HOME/Music" "$HOME/Pictures"; do
  if [ -d "$scan_dir" ]; then
    find "$scan_dir" -type f -size +200M -exec ls -lh {} \; 2>/dev/null
  fi
done | sort -rh -k5 | head -20 > "$BIGFILE_TMP"
if [ -s "$BIGFILE_TMP" ]; then
  cat "$BIGFILE_TMP" >> "$OUTPUT"
else
  w "No files larger than 200MB found in the directories above."
fi
rm -f "$BIGFILE_TMP"

# ── 6. Docker / Podman ──────────────────────────────────────────────
section "6. Docker / Podman"

if command -v docker &>/dev/null; then
  echo '```' >> "$OUTPUT"
  docker system df 2>/dev/null >> "$OUTPUT" || w "Docker daemon not running"
  echo '```' >> "$OUTPUT"
fi
w ""

if command -v podman &>/dev/null; then
  w "**Podman usage:**"
  w ""
  { du -sh "$HOME/.local/share/containers" 2>/dev/null; } >> "$OUTPUT"
fi
w ""

DOCKER_DATA_SIZE=$(getsize lib_DockerData)
w "**Docker data directory: $DOCKER_DATA_SIZE**"
w ""
RAW_FILE="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
if [ -f "$RAW_FILE" ]; then
  du -h "$RAW_FILE" >> "$OUTPUT"
fi

# ── 7. Ollama ───────────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
  section "7. Ollama Models"
  echo '```' >> "$OUTPUT"
  ollama list 2>/dev/null >> "$OUTPUT" || w "Ollama not running"
  echo '```' >> "$OUTPUT"
  w ""
  OLLAMA_SIZE=$(getsize dot_ollama)
  w "**Total model file usage: $OLLAMA_SIZE**"
fi

# ── 8. Cache detail ─────────────────────────────────────────────────
section "8. Cache Detail"

w "**uv cache:**"
w ""
getsize dot_uv >> "$OUTPUT"
w ""
w "**npm cache:**"
w ""
getsize dot_npm >> "$OUTPUT"
w ""
w "**~/.cache subdirectories:**"
w ""
{ du -sh "$HOME/.cache"/*/ 2>/dev/null | sort -rh | head -20; } >> "$OUTPUT"

# ── 9. Reclaimable estimate ─────────────────────────────────────────
section "9. Cleanup Suggestions"

# Convert sizes to KB for calculation
to_kb() {
  local sz=$1
  case "$sz" in
    *G) awk "BEGIN{printf \"%d\", ${sz%G} * 1024 * 1024}" ;;
    *M) awk "BEGIN{printf \"%d\", ${sz%M} * 1024}" ;;
    *K) awk "BEGIN{printf \"%d\", ${sz%K}}" ;;
    *) echo 0 ;;
  esac 2>/dev/null
}

fmt_kb() {
  local kb=$1; [ -z "$kb" ] && echo "0" && return
  [ "$kb" -lt 1024 ] && echo "${kb}K" && return
  [ "$kb" -lt $((1024*1024)) ] && awk "BEGIN{printf \"%.1fM\", $kb/1024}" && return
  awk "BEGIN{printf \"%.1fG\", $kb/1024/1024}"
}

DOCKER_KB=$(to_kb "$(getsize lib_DockerData)")
UV_KB=$(to_kb "$(getsize dot_uv)")
OLLAMA_KB=$(to_kb "$(getsize dot_ollama)")
NPM_KB=$(to_kb "$(getsize dot_npm)")
CORESIM_KB=$(to_kb "$(getsize coresim)")
HPROF_KB=$(to_kb "$(getsize hprof)")

w "| Item | Suggested Action | Reclaimable |"
w "|------|------------------|-------------|"

[ "$DOCKER_KB" -gt 0 ] 2>/dev/null && w "| Docker data | \`docker system prune -a --volumes -f\` | $(fmt_kb "$DOCKER_KB") |"
[ "$UV_KB" -gt 0 ] 2>/dev/null && w "| uv cache | \`uv cache clean\` | $(fmt_kb "$UV_KB") |"
[ "$OLLAMA_KB" -gt 0 ] 2>/dev/null && w "| Ollama models | \`ollama rm <model>\` (as needed) | $(fmt_kb "$OLLAMA_KB") |"
[ "$NPM_KB" -gt 0 ] 2>/dev/null && w "| npm cache | \`npm cache clean --force\` | $(fmt_kb "$NPM_KB") |"
[ "$CORESIM_KB" -gt 0 ] 2>/dev/null && w "| Xcode simulators | \`xcrun simctl delete unavailable\` | $(fmt_kb "$CORESIM_KB") |"
[ "$HPROF_KB" -gt 0 ] 2>/dev/null && w "| IntelliJ heap dump | \`rm ~/java_error_in_idea.hprof\` | $(fmt_kb "$HPROF_KB") |"
w "| Other caches | Review individually (JetBrains / Google / ~/Library/Caches etc.) | — |"

TOTAL=$(( (DOCKER_KB + UV_KB + OLLAMA_KB + NPM_KB + CORESIM_KB + HPROF_KB) ))
w ""
w "> **Estimated total reclaimable: $(fmt_kb $TOTAL)+**"
w ""
w "> ⚠️ Verify the data is not needed before cleanup, especially Ollama models and Docker data."

# ── 10. Cleanup commands ────────────────────────────────────────────
section "10. Cleanup Command Reference"
cat >> "$OUTPUT" <<- 'CMDS'
	```bash
	# ===== Docker =====
	# docker system prune -a --volumes -f

	# ===== uv =====
	# uv cache clean

	# ===== npm =====
	# npm cache clean --force

	# ===== Ollama =====
	# ollama list
	# ollama rm <model>

	# ===== Xcode simulators =====
	# xcrun simctl delete unavailable

	# ===== Large files =====
	# rm ~/java_error_in_idea.hprof

	# ===== Generic caches =====
	# rm -rf ~/Library/Caches/*
	# rm -rf ~/.cache/uv/*
	```

CMDS

w ""
w "---"
w ""
w "*Report generated by \`disk-full-report.sh\` | Verify data importance before cleanup*"

echo ""
echo "✅ Report generated: $OUTPUT"
echo "Total lines: $(wc -l < "$OUTPUT")"
echo ""
echo "View: less \"$OUTPUT\""
echo "Preview: open \"$OUTPUT\""
