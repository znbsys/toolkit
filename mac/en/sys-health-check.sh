#!/bin/bash
# =============================================================================
# sys-health-check.sh — System health check & safe optimization script (v1.1)
# Compatible with: Linux (systemd) / macOS
# Level: L0 read-only checks + L1 safe cleanup (user-level caches/logs/tmp only)
#
# Usage:
#   bash sys-health-check.sh              # default: health check + optimization dry run
#   bash sys-health-check.sh --check      # health check only
#   bash sys-health-check.sh --optimize   # optimization dry run only
#   bash sys-health-check.sh --execute    # actually delete (combine with --optimize)
#   bash sys-health-check.sh --help       # help
#
# Safety promises:
#   - Never uses sudo, never touches system directories (/System /Library /usr /etc /var)
#   - Never touches personal files (Desktop/Documents/Downloads/Pictures/Videos)
#   - Never empties the Trash/Recycle Bin (irreversible; left to the user)
#   - Only deletes regenerable caches, logs and temporary files
#   - Dry run by default; prints reclaimable space before deleting
# =============================================================================

set -u

# ---------- Global variables ----------
MODE_CHECK=1
MODE_OPTIMIZE=1
DRY_RUN=1
TOTAL_FREED_KB=0
OS_TYPE=""

# ---------- Colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[FAIL]${NC} $*"; }
section() { echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ---------- Argument parsing ----------
usage() {
  cat <<EOF
Usage: bash $0 [options]

Options:
  --check      Health check only (CPU/memory/disk/network/startup items)
  --optimize   Safe optimization only (dry run by default, deletes nothing)
  --execute    Actually delete; must be combined with --optimize
  --help       Show this help

Examples:
  bash $0                       # health check + optimization dry run
  bash $0 --check               # checks only
  bash $0 --optimize            # preview reclaimable space (dry run)
  bash $0 --optimize --execute  # actually clean
EOF
}

check_only=0
opt_only=0
for arg in "$@"; do
  case "$arg" in
    --check)    check_only=1 ;;
    --optimize) opt_only=1 ;;
    --execute)  DRY_RUN=0 ;;
    --help|-h)  usage; exit 0 ;;
    *) error "Unknown argument: $arg"; usage; exit 2 ;;
  esac
done

if [ "$check_only" = "1" ] && [ "$opt_only" = "1" ]; then
  MODE_CHECK=1; MODE_OPTIMIZE=1
elif [ "$check_only" = "1" ]; then
  MODE_CHECK=1; MODE_OPTIMIZE=0
elif [ "$opt_only" = "1" ]; then
  MODE_CHECK=0; MODE_OPTIMIZE=1
fi

# ---------- OS detection ----------
detect_os() {
  case "$(uname -s)" in
    Darwin) OS_TYPE="macos" ;;
    Linux)  OS_TYPE="linux" ;;
    *)      error "Unsupported operating system: $(uname -s)"; exit 1 ;;
  esac
  info "Detected OS: $OS_TYPE ($(uname -r))"
}

# ---------- Utility functions ----------
# Directory size in KB; always returns a number (0 when missing or failed)
dir_size_kb() {
  local path="${1:-}"
  if [ -n "$path" ] && [ -d "$path" ]; then
    local s
    s=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    if echo "$s" | grep -qE '^[0-9]+$'; then
      echo "$s"
    else
      echo 0
    fi
  else
    echo 0
  fi
}

# Convert KB to human readable (BSD awk compatible: -v + single-quoted program)
kb_to_human() {
  local kb="${1:-0}"
  if ! echo "$kb" | grep -qE '^[0-9]+$'; then
    kb=0
  fi
  if [ "$kb" -ge 1048576 ]; then
    awk -v k="$kb" 'BEGIN {printf "%.2f GB", k/1048576}'
  elif [ "$kb" -ge 1024 ]; then
    awk -v k="$kb" 'BEGIN {printf "%.2f MB", k/1024}'
  else
    echo "${kb} KB"
  fi
}

# Safe addition (avoids arithmetic errors on empty values)
safe_add() {
  local a="${1:-0}" b="${2:-0}"
  echo "$((a + b))"
}

# =============================================================================
# Health check module
# =============================================================================

check_cpu() {
  section "CPU Check"
  if [ "$OS_TYPE" = "macos" ]; then
    echo "  Model: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'unknown')"
    echo "  Physical cores: $(sysctl -n hw.physicalcpu 2>/dev/null || echo '?')"
    echo "  Logical cores: $(sysctl -n hw.logicalcpu 2>/dev/null || echo '?')"
    local cpu_usage
    cpu_usage=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $3+$5}' | sed 's/%//')
    [ -z "$cpu_usage" ] && cpu_usage=$(ps -A -o %cpu | awk 'NR>1 {s+=$1} END {printf "%.1f", s}')
    echo "  Current usage: ${cpu_usage:-?}%"
    if command -v osx-cpu-temp >/dev/null 2>&1; then
      echo "  CPU temperature: $(osx-cpu-temp 2>/dev/null || echo 'unavailable')"
    else
      echo "  CPU temperature: osx-cpu-temp not installed (brew install osx-cpu-temp)"
    fi
  else
    echo "  Model: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo 'unknown')"
    echo "  Logical cores: $(nproc 2>/dev/null || echo '?')"
    echo "  Load average (1/5/15 min): $(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs)"
    local cpu_usage
    cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print 100-$8}' || echo "?")
    echo "  Current usage: ${cpu_usage}%"
    if command -v sensors >/dev/null 2>&1; then
      echo "  CPU temperature: $(sensors 2>/dev/null | grep -i 'core 0' | head -1 | awk '{print $3}' || echo 'unavailable')"
    else
      echo "  CPU temperature: lm-sensors not installed"
    fi
  fi
}

check_memory() {
  section "Memory Check"
  if [ "$OS_TYPE" = "macos" ]; then
    local total_mem
    total_mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
    echo "  Total memory: ${total_mem:-?} GB"
    local vm_info page_size free_pages active_pages wired_pages
    vm_info=$(vm_stat 2>/dev/null)
    page_size=$(echo "$vm_info" | grep "page size" | awk '{print $8}' | tr -d '.')
    [ -z "$page_size" ] && page_size=4096
    free_pages=$(echo "$vm_info" | grep "Pages free" | awk '{print $3}' | tr -d '.')
    active_pages=$(echo "$vm_info" | grep "Pages active" | awk '{print $3}' | tr -d '.')
    wired_pages=$(echo "$vm_info" | grep "Pages wired" | awk '{print $4}' | tr -d '.')
    [ -z "$free_pages" ] && free_pages=0
    [ -z "$active_pages" ] && active_pages=0
    [ -z "$wired_pages" ] && wired_pages=0
    local used_mb=$(( (active_pages + wired_pages) * page_size / 1048576 ))
    local free_mb=$(( free_pages * page_size / 1048576 ))
    echo "  In use: ~${used_mb} MB (active + wired)"
    echo "  Free: ~${free_mb} MB"
  else
    if command -v free >/dev/null 2>&1; then
      free -h | head -2
    else
      echo "  Total memory: $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
      echo "  Available memory: $(awk '/MemAvailable/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
    fi
    local swap_total swap_free
    swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    swap_free=$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "${swap_total:-}" ] && [ "$swap_total" -gt 0 ] 2>/dev/null; then
      local swap_used_kb=$((swap_total - swap_free))
      echo "  Swap: $(kb_to_human $swap_used_kb) used / $(kb_to_human $swap_total) total"
    fi
  fi
  echo "  --- Top 5 memory consumers ---"
  if [ "$OS_TYPE" = "macos" ]; then
    ps -Ao pid,comm,%mem -r 2>/dev/null | head -6 | awk 'NR>1 {printf "  %-8s %-30s %s%%\n", $1, $2, $3}'
  else
    ps aux --sort=-%mem 2>/dev/null | head -6 | awk 'NR>1 {printf "  %-8s %-30s %s%%\n", $2, $11, $4}'
  fi
}

check_disk() {
  section "Disk Space Check"
  echo "  Mount Point             Total   Used    Avail   Use%"
  echo "  ----------------------------------------------------------------"
  if [ "$OS_TYPE" = "macos" ]; then
    df -h / /System/Volumes/Data 2>/dev/null | awk 'NR>1 {printf "  %-20s %-7s %-7s %-7s %s\n", $9, $2, $3, $4, $5}'
  else
    df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {printf "  %-20s %-7s %-7s %-7s %s\n", $6, $2, $3, $4, $5}'
  fi
  echo ""
  info "Top 5 user directories by size (statistics only, nothing deleted):"
  du -sh "$HOME"/* 2>/dev/null | sort -rh | head -5 | awk '{printf "  %-8s %s\n", $1, $2}'
}

check_network() {
  section "Network Check"
  echo "  --- Interface status ---"
  if [ "$OS_TYPE" = "macos" ]; then
    ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | grep -v "127.0.0.1" | grep -v "inet6" | \
      awk '/^[a-z]/ {iface=$1} /inet / {printf "  %-12s IP: %s\n", iface, $2}'
  else
    ip -4 addr show 2>/dev/null | grep -v "127.0.0.1" | \
      awk '/^[0-9]/ {iface=$2} /inet / {printf "  %-12s IP: %s\n", iface, $2}'
  fi
  echo ""
  echo "  --- Connectivity test ---"
  local targets=("223.5.5.5" "8.8.8.8" "baidu.com" "google.com")
  for target in "${targets[@]}"; do
    if ping -c 2 -W 2 "$target" >/dev/null 2>&1; then
      local latency
      latency=$(ping -c 2 -W 2 "$target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | awk '{printf "%.1f", $1}')
      success "Reachable $target (latency ${latency:-?}ms)"
    else
      warn "Cannot reach $target"
    fi
  done
  echo ""
  echo "  --- DNS resolution ---"
  if command -v nslookup >/dev/null 2>&1; then
    nslookup baidu.com 2>/dev/null | grep -A2 "Name:" | head -3 || warn "DNS resolution may be broken"
  elif command -v dig >/dev/null 2>&1; then
    dig +short baidu.com 2>/dev/null | head -3 || warn "DNS resolution may be broken"
  else
    echo "  nslookup/dig not installed, skipping detailed DNS test"
  fi
}

check_startup() {
  section "Startup Items Check"
  if [ "$OS_TYPE" = "macos" ]; then
    echo "  --- User login items (LaunchAgents) ---"
    ls -1 "$HOME/Library/LaunchAgents/" 2>/dev/null | head -20 || echo "  (none)"
    echo ""
    echo "  --- System LaunchDaemons (read-only view) ---"
    ls -1 /Library/LaunchDaemons/ 2>/dev/null | head -20 || echo "  (none)"
    echo ""
    echo "  --- Current user login items ---"
    osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || echo "  (unavailable; check System Settings -> General -> Login Items)"
  else
    echo "  --- Boot services (systemd) ---"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-unit-files --type=service --state=enabled 2>/dev/null | head -25 || echo "  (unavailable)"
    else
      echo "  systemd not detected"
    fi
    echo ""
    echo "  --- User autostart ~/.config/autostart ---"
    ls -1 "$HOME/.config/autostart/" 2>/dev/null || echo "  (none)"
    echo ""
    echo "  --- Shell config files ---"
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
      [ -f "$rcfile" ] && echo "  $rcfile: $(wc -l < "$rcfile") lines"
    done
  fi
}

run_health_check() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     Computer Health Check $(date '+%Y-%m-%d %H:%M')            ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

  check_cpu
  check_memory
  check_disk
  check_network
  check_startup

  section "Check Summary"
  info "All of the above are read-only checks; nothing on the system was modified."
  info "To optimize, run: bash $0 --optimize (dry run) or bash $0 --optimize --execute (execute)"
}

# =============================================================================
# Safe optimization module (L1: user-level caches/logs/tmp only)
# =============================================================================

# Clean a single directory (delete contents, keep the directory itself)
clean_dir() {
  local label="$1" path="$2"
  [ -d "$path" ] || { echo "  [skip] $label: directory not found ($path)"; return; }
  local size_kb
  size_kb=$(dir_size_kb "$path")
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $label: reclaimable $(kb_to_human "$size_kb") ($path)"
  else
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    echo "  [done] $label: freed approximately $(kb_to_human "$size_kb")"
  fi
  TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$size_kb")
}

# Clean subdirectory contents (keep subdirs, skip critical items)
clean_caches_subdirs() {
  local base="$1" label="$2"
  [ -d "$base" ] || return
  local excludes="com.apple.cloudkit CloudKit com.apple.FamilyCircle com.apple.akd com.apple.homed com.apple.Safari.SafeBrowsing"
  local total_kb=0
  for d in "$base"/*; do
    [ -e "$d" ] || continue
    local name
    name=$(basename "$d")
    local skip=0
    for ex in $excludes; do
      [ "$name" = "$ex" ] && skip=1 && break
    done
    if [ "$skip" = "1" ]; then
      echo "  [skip] critical system cache: $name"
      continue
    fi
    local s
    s=$(dir_size_kb "$d")
    total_kb=$(safe_add "$total_kb" "$s")
    if [ "$DRY_RUN" != "1" ]; then
      if [ -d "$d" ]; then
        find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
      else
        rm -f "$d" 2>/dev/null
      fi
    fi
  done
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] $label: reclaimable $(kb_to_human "$total_kb") (critical items excluded)"
  else
    echo "  [done] $label: freed approximately $(kb_to_human "$total_kb")"
  fi
  TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$total_kb")
}

run_optimize() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  Safe Optimization $([ $DRY_RUN = 1 ] && echo '(dry run, no files deleted)') $(date '+%Y-%m-%d %H:%M')  ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

  if [ "$DRY_RUN" = "1" ]; then
    warn "Current mode is DRY RUN: reclaimable space is measured, nothing is deleted."
    warn "To proceed, run: bash $0 --optimize --execute"
  else
    success "Starting safe cleanup (L1: user-level caches/logs/tmp only)..."
  fi

  section "Cache Cleanup"

  if [ "$OS_TYPE" = "macos" ]; then
    clean_caches_subdirs "$HOME/Library/Caches" "User app caches"
    clean_dir "Xcode build cache" "$HOME/Library/Developer/Xcode/DerivedData"
    clean_dir "iOS device logs" "$HOME/Library/Logs/CrashReporter"
  else
    clean_caches_subdirs "$HOME/.cache" "User app caches (~/.cache)"
    clean_dir "Thumbnail cache" "$HOME/.cache/thumbnails"
    clean_dir "pip cache" "$HOME/.cache/pip"
    clean_dir "npm cache" "$HOME/.npm/_cacache"
    clean_dir "Yarn cache" "$HOME/.cache/yarn"
    clean_dir "Docker build cache" "$HOME/.docker/buildx"
    # /tmp files older than 7 days
    if [ -d /tmp ]; then
      local tmp_old_kb=0
      tmp_old_kb=$(find /tmp -type f -atime +7 -not -path '/tmp/.X*' -not -path '/tmp/.ICE*' 2>/dev/null | xargs du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
      [ -z "$tmp_old_kb" ] && tmp_old_kb=0
      if [ "$DRY_RUN" = "1" ]; then
        echo "  [dry-run] /tmp files older than 7 days: reclaimable $(kb_to_human "$tmp_old_kb")"
      else
        find /tmp -type f -atime +7 -not -path '/tmp/.X*' -not -path '/tmp/.ICE*' -delete 2>/dev/null
        echo "  [done] /tmp files older than 7 days: freed approximately $(kb_to_human "$tmp_old_kb")"
      fi
      TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$tmp_old_kb")
    fi
  fi

  section "Log Cleanup"
  if [ "$OS_TYPE" = "macos" ]; then
    clean_dir "User logs" "$HOME/Library/Logs"
  else
    clean_dir "Recent documents" "$HOME/.local/share/RecentDocuments"
    if command -v journalctl >/dev/null 2>&1; then
      local journal_size
      journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "unknown")
      echo "  [info] systemd journal usage: ${journal_size} (clean with sudo journalctl --vacuum-time=7d, requires admin)"
    fi
  fi

  section "Browser Caches"
  if [ "$OS_TYPE" = "macos" ]; then
    clean_dir "Chrome cache" "$HOME/Library/Caches/Google/Chrome/Default/Cache"
    clean_dir "Chrome code cache" "$HOME/Library/Caches/Google/Chrome/Default/Code Cache"
    clean_dir "Chrome cache (alt path)" "$HOME/Library/Application Support/Google/Chrome/Default/Cache"
    clean_dir "Safari cache" "$HOME/Library/Caches/com.apple.Safari"
    clean_dir "Firefox cache" "$HOME/Library/Caches/Firefox"
  else
    clean_dir "Chrome cache" "$HOME/.cache/google-chrome/Default/Cache"
    clean_dir "Chrome code cache" "$HOME/.cache/google-chrome/Default/Code Cache"
    clean_dir "Firefox cache" "$HOME/.cache/mozilla/firefox"
  fi

  section "Package Manager Caches"
  if [ "$OS_TYPE" = "linux" ]; then
    if command -v apt >/dev/null 2>&1; then
      local apt_cache
      apt_cache=$(dir_size_kb "/var/cache/apt/archives")
      echo "  [info] apt download cache: $(kb_to_human "$apt_cache") (clean with sudo apt clean)"
    fi
    command -v dnf >/dev/null 2>&1 && echo "  [info] dnf cache can be cleaned with sudo dnf clean all"
    command -v pacman >/dev/null 2>&1 && echo "  [info] pacman cache can be cleaned with sudo pacman -Sc"
  elif [ "$OS_TYPE" = "macos" ]; then
    if command -v brew >/dev/null 2>&1; then
      local brew_cache
      brew_cache=$(dir_size_kb "$HOME/Library/Caches/Homebrew")
      echo "  [info] Homebrew cache: $(kb_to_human "$brew_cache") (clean with brew cleanup)"
    fi
  fi

  section "Trash / Recycle Bin (not cleaned by default)"
  if [ "$OS_TYPE" = "macos" ]; then
    local trash_kb
    trash_kb=$(dir_size_kb "$HOME/.Trash")
    echo "  [skip] Trash: $(kb_to_human "$trash_kb") — emptying is irreversible, do it manually in Finder"
  else
    local trash_kb
    trash_kb=$(dir_size_kb "$HOME/.local/share/Trash")
    echo "  [skip] Recycle Bin: $(kb_to_human "$trash_kb") — emptying is irreversible, do it manually in your file manager"
  fi

  section "Optimization Summary"
  if [ "$DRY_RUN" = "1" ]; then
    success "Dry run complete: about $(kb_to_human "$TOTAL_FREED_KB") can be safely reclaimed."
    echo ""
    info "To actually clean, run: bash $0 --optimize --execute"
  else
    success "Cleanup complete: approximately $(kb_to_human "$TOTAL_FREED_KB") freed."
  fi
  echo ""
  info "Untouched: system directories, personal files (Desktop/Documents/Downloads/Pictures/Videos), browser bookmarks/passwords, keychain, Trash"
  info "Recommendation: clean browser caches regularly, keep free disk space > 10%, disable unneeded startup items"
}

# =============================================================================
# Main flow
# =============================================================================
main() {
  detect_os
  echo ""
  info "Script version: 1.1 | OS: $OS_TYPE | User: $USER"
  info "Safety level: L0 checks + L1 cleanup | No sudo | Personal files untouched"

  if [ "$MODE_CHECK" = "1" ]; then
    run_health_check
  fi

  if [ "$MODE_OPTIMIZE" = "1" ]; then
    run_optimize
  fi

  echo ""
  success "All operations finished."
}

main
