#!/bin/bash
# disk-overview.sh - Quick disk usage overview for macOS
#
# Usage:
#   bash disk-overview.sh           # Volume usage + top home directories
#   bash disk-overview.sh --top     # Also scan top-level system directories
#   bash disk-overview.sh --deep    # Also show detail for large dev/cache dirs
#
# Read-only script. It does not delete anything.

set -u

TOP_N=10

# Colors (disabled when stdout is not a TTY)
if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_RESET=""
fi

MODE_TOP=0
MODE_DEEP=0
for arg in "$@"; do
    case "$arg" in
        --top) MODE_TOP=1 ;;
        --deep) MODE_DEEP=1 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^#/ /'; exit 0 ;;
        *) echo "Unknown argument: $arg (available: --top / --deep)" >&2; exit 1 ;;
    esac
done

# ---------- Helpers ----------

# Colorize a usage percentage
color_pct() {
    local pct="${1//%/}"
    if [ "$pct" -ge 90 ] 2>/dev/null; then
        echo "${C_RED}${1}${C_RESET}"
    elif [ "$pct" -ge 70 ] 2>/dev/null; then
        echo "${C_YELLOW}${1}${C_RESET}"
    else
        echo "${C_GREEN}${1}${C_RESET}"
    fi
}

section() { printf "\n${C_CYAN}── %s ──${C_RESET}\n" "$1"; }

# ---------- 1. Volume overview ----------

show_volumes() {
    section "Volume Usage Overview"
    if [ "$(uname -s)" = "Darwin" ]; then
        local line size used avail pct mount
        printf "  %-28s %8s %8s %8s %6s\n" "Volume" "Total" "Used" "Avail" "Use%"
        printf "  %-28s %8s %8s %8s %6s\n" "------" "-----" "----" "----" "----"
        for mount in / /System/Volumes/Data; do
            line=$(df -h "$mount" 2>/dev/null | awk 'NR==2')
            [ -z "$line" ] && continue
            size=$(echo "$line" | awk '{print $2}')
            used=$(echo "$line" | awk '{print $3}')
            avail=$(echo "$line" | awk '{print $4}')
            pct=$(echo "$line" | awk '{print $5}')
            printf "  %-28s %8s %8s %8s %6s\n" "$mount" "$size" "$used" "$avail" "$(color_pct "$pct")"
        done
        echo ""
        # Progress bar (based on the data volume)
        local raw_pct
        raw_pct=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
        if [ -n "${raw_pct:-}" ] && [ "$raw_pct" -ge 0 ] 2>/dev/null; then
            local filled=$((raw_pct / 5))  # 20 cells
            local bar=""
            for i in $(seq 1 20); do
                if [ "$i" -le "$filled" ]; then bar+="█"; else bar+="░"; fi
            done
            printf "  Total usage: %s %s\n" "$bar" "$(color_pct "${raw_pct}%")"
        fi
    else
        df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk '{printf "  %s\n", $0}'
    fi
}

# ---------- 2. Home directory usage ----------

show_home() {
    section "Top ${TOP_N} Directories in Home"
    du -sh "$HOME"/* "$HOME"/.[!.]* 2>/dev/null \
        | sort -rh \
        | head -"${TOP_N}" \
        | awk '{printf "  %-8s %s\n", $1, $2}'
}

# ---------- 3. Top-level system directories ----------

show_top() {
    section "Top-Level System Directory Usage (may be slow)"
    echo "  ${C_DIM}Scanning, this may take 10-30 seconds...${C_RESET}"
    local dirs=(/Applications /Library /Users /opt /usr/local /private/var/vm)
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        du -sh "$d" 2>/dev/null
    done | sort -rh | awk '{printf "  %-8s %s\n", $1, $2}'
}

# ---------- 4. Large directory detail ----------

show_deep() {
    section "Large Directory Detail"
    local targets=(
        "$HOME/Library/Caches"
        "$HOME/Library/Developer"
        "$HOME/Library/Application Support"
        "$HOME/.npm"
        "$HOME/.cache"
        "$HOME/.ollama/models"
        "$HOME/workspace"
        "/Applications"
    )
    printf "  %-55s %8s\n" "Path" "Size"
    printf "  %-55s %8s\n" "----" "----"
    for d in "${targets[@]}"; do
        [ -d "$d" ] || continue
        local sz
        sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        [ -n "${sz:-}" ] && printf "  %-55s %8s\n" "${d/#$HOME/~}" "$sz"
    done
}

# ---------- Main ----------

printf "${C_BOLD}══════════ Disk Usage Overview ($(date '+%Y-%m-%d %H:%M')) ══════════${C_RESET}\n"

show_volumes
show_home

[ "$MODE_TOP" -eq 1 ] && show_top
[ "$MODE_DEEP" -eq 1 ] && show_deep

echo ""
printf "${C_DIM}Tip: use --top for system directories, --deep for dev/cache detail${C_RESET}\n"
echo ""
