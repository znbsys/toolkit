#!/bin/bash
# disk-timeline.sh - Analyze disk usage by modification time to find out
# what has been occupying the disk recently.
#
# Usage:
#   bash disk-timeline.sh              # default: last 3 days, files >= 50M
#   bash disk-timeline.sh --days 7     # time window of the last 7 days
#   bash disk-timeline.sh --min 10M    # lower the file size threshold
#   bash disk-timeline.sh --dirs       # aggregate by directory
#   bash disk-timeline.sh --all        # both files and directories
#
# How it works: disk growth = files being written/modified. Uses the macOS
# Spotlight index (mdfind) for second-level queries; falls back to find
# when Spotlight is unavailable.
#
# Read-only script. It does not delete anything.

set -u

DAYS=3
MIN_BYTES=$((50 * 1024 * 1024))   # 50M
TOP_N=20
MODE_FILES=1
MODE_DIRS=0

# Colors (disabled when stdout is not a TTY)
if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_RESET=""
fi

usage() {
    sed -n '2,14p' "$0" | sed 's/^#/ /'
    cat <<EOF

Options:
  --days N    Time window in days, default 3
  --min SIZE  Minimum file size threshold, default 50M (e.g. 10M / 1G)
  --dirs      Aggregate by directory
  --all       Show both files and directories
  -h, --help  Show this help
EOF
}

parse_size() {
    local s="$1"
    case "$s" in
        *[Gg]) echo $(( ${s%[Gg]} * 1024 * 1024 * 1024 )) ;;
        *[Mm]) echo $(( ${s%[Mm]} * 1024 * 1024 )) ;;
        *[Kk]) echo $(( ${s%[Kk]} * 1024 )) ;;
        *)     echo "$s" ;;
    esac
}

human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if (k>=1048576) printf "%.1fG", k/1048576;
        else if (k>=1024) printf "%.1fM", k/1024;
        else printf "%dK", k
    }'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --days) DAYS="${2:-3}"; shift 2 ;;
        --min)  MIN_BYTES=$(parse_size "${2:-50M}"); shift 2 ;;
        --dirs) MODE_DIRS=1; MODE_FILES=0; shift ;;
        --all)  MODE_DIRS=1; MODE_FILES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

section() { printf "\n${C_CYAN}══ %s ══${C_RESET}\n" "$1"; }
sub()     { printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

# Is Spotlight available (and indexed)?
HAVE_MDFIND=0
if command -v mdfind >/dev/null 2>&1; then
    # Quick probe: see whether large-file queries return anything
    if mdfind -onlyin "$HOME" 'kMDItemFSSize >= 104857600' 2>/dev/null | head -1 | grep -q .; then
        HAVE_MDFIND=1
    fi
fi

# ---------------------------------------------------------------------------
# Core query: print one "path" per line, restricted to a time window.
#   $1 = window start (days ago, inclusive)
#   $2 = window end (days ago, exclusive; 0 = now)
#   Day semantics: 1 = last 24h, 2 = yesterday, 7 = last 7 days
# ---------------------------------------------------------------------------
query_recent_files() {
    local days_from="$1" days_to="${2:-0}"
    local min_mb=$(( MIN_BYTES / 1024 / 1024 ))

    if [ "$HAVE_MDFIND" = 1 ]; then
        # mdfind date syntax: $time.today(-N) = N days ago
        local expr
        if [ "$days_to" -le 0 ]; then
            expr="kMDItemFSSize >= $((min_mb * 1024 * 1024)) && kMDItemContentModificationDate >= \$time.today(-$days_from)"
        else
            expr="kMDItemFSSize >= $((min_mb * 1024 * 1024)) && kMDItemContentModificationDate >= \$time.today(-$days_from) && kMDItemContentModificationDate < \$time.today(-$((days_to - 1)))"
        fi
        mdfind -onlyin "$HOME" "$expr" 2>/dev/null
        mdfind -onlyin /Applications "$expr" 2>/dev/null
        mdfind -onlyin /Library "$expr" 2>/dev/null
    else
        # find fallback: scan a curated list of roots to avoid a full-disk crawl
        local roots=(
            "$HOME/Library/Caches"
            "$HOME/Library/Logs"
            "$HOME/Library/Containers"
            "$HOME/Library/Application Support"
            "$HOME/Library/Developer"
            "$HOME/Downloads"
            "$HOME/.cache"
            "$HOME/.npm"
            "$HOME/.ollama"
            "$HOME/workspace"
            "$HOME/projects"
            "/Applications"
            "/Library"
        )
        local expr1="+$((days_from - 1))"
        local expr2=""
        [ "$days_to" -gt 1 ] && expr2="-mtime -$days_to"
        local r
        for r in "${roots[@]}"; do
            [ -d "$r" ] || continue
            find "$r" \
                -path "*/node_modules/.cache" -prune -o \
                -path "*/.git" -prune -o \
                -type f -size "+${MIN_BYTES}c" -mtime "$expr1" $expr2 -print 2>/dev/null
        done
    fi
}

# Convert a path list to "bytes|mtime|path" lines, sorted by size, Top N
format_and_sort() {
    local path
    local lines=()
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        [ -f "$path" ] || continue
        local bytes mtime
        bytes=$(stat -f%z "$path" 2>/dev/null) || continue
        [ -n "${bytes:-}" ] && [ "$bytes" -ge "$MIN_BYTES" ] 2>/dev/null || continue
        mtime=$(stat -f%m "$path" 2>/dev/null || echo 0)
        lines+=("$bytes|$mtime|$path")
    done

    if [ "${#lines[@]}" -eq 0 ]; then
        return 1
    fi

    printf '%s\n' "${lines[@]}" | sort -t'|' -k1 -rn | head -"$TOP_N"
}

print_file_rows() {
    # stdin: bytes|mtime|path
    local bytes mtime path
    while IFS='|' read -r bytes mtime path; do
        local human mt
        human=$(human_kb $((bytes / 1024)))
        mt=$(date -r "$mtime" '+%m-%d %H:%M' 2>/dev/null)
        local disp="${path/#$HOME/~}"
        printf "  ${C_RED}%-8s${C_RESET} %s  ${C_DIM}%s${C_RESET}\n" "$human" "${mt:-?}" "$disp"
    done
}

# ---------------------------------------------------------------------------
# 1. Large files by time window
# ---------------------------------------------------------------------------
scan_files_by_time() {
    local label="$1" days_from="$2" days_to="${3:-0}"
    sub "$label"

    local tmp
    tmp=$(mktemp)
    query_recent_files "$days_from" "$days_to" | format_and_sort > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "  (no files >= $(human_kb $((MIN_BYTES / 1024))))"
        rm -f "$tmp"; return
    fi

    print_file_rows < "$tmp"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 2. Aggregate by directory
# ---------------------------------------------------------------------------
scan_dirs_by_time() {
    local label="$1" days_from="$2" days_to="${3:-0}"
    sub "$label"

    local tmp
    tmp=$(mktemp)
    query_recent_files "$days_from" "$days_to" \
    | while IFS= read -r f; do
        [ -f "$f" ] || continue
        local bytes dir
        bytes=$(stat -f%z "$f" 2>/dev/null) || continue
        [ -n "${bytes:-}" ] && [ "$bytes" -ge "$MIN_BYTES" ] 2>/dev/null || continue
        dir=$(dirname "$f")
        # Tab-separated so paths containing spaces are not split by awk
        printf '%s\t%s\n' "$bytes" "$dir"
    done \
    | awk -F'\t' '{
        sum[$2]+=$1
        cnt[$2]++
    } END {
        for (p in sum) printf "%d\t%d\t%s\n", sum[p], cnt[p], p
    }' \
    | sort -t$'\t' -k1 -rn | head -"$TOP_N" > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "  (none)"
        rm -f "$tmp"; return
    fi

    printf "  %-10s %6s  %s\n" "Size" "Files" "Directory"
    printf "  %-10s %6s  %s\n" "----" "-----" "---------"
    local kb cnt path human disp
    while IFS=$'\t' read -r kb cnt path; do
        human=$(human_kb $((kb / 1024)))
        disp="${path/#$HOME/~}"
        printf "  ${C_RED}%-10s${C_RESET} %6s  %s\n" "$human" "$cnt" "$disp"
    done < "$tmp"

    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 3. Quick health check of common growth sources
# ---------------------------------------------------------------------------
show_suspects() {
    section "Common Growth Sources - Quick Check"
    local suspects=(
        "$HOME/Library/Caches|Application caches"
        "$HOME/Library/Logs|Application logs"
        "$HOME/Library/Containers/com.docker.docker|Docker VM disk"
        "$HOME/.ollama/models|Ollama models"
        "$HOME/.cache|General cache"
        "$HOME/Downloads|Downloads folder"
        "$HOME/Library/Developer/Xcode/DerivedData|Xcode build cache"
        "$HOME/Library/Application Support|Application data"
        "/Applications|Applications"
        "$HOME/.local|Local installs (.local)"
        "$HOME/.omlx|omlx data"
    )
    printf "  %-12s  %s\n" "Size" "Directory"
    printf "  %-12s  %s\n" "----" "---------"
    local entry path desc
    for entry in "${suspects[@]}"; do
        path="${entry%%|*}"
        desc="${entry##*|}"
        [ -d "$path" ] || continue
        local sz
        sz=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        [ -n "${sz:-}" ] && printf "  ${C_YELLOW}%-12s${C_RESET} %s  ${C_DIM}%s${C_RESET}\n" \
            "$sz" "${path/#$HOME/~}" "$desc"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
printf "${C_BOLD}════════ Disk Usage Timeline (window: last ${DAYS} days) ════════${C_RESET}\n"
if [ "$HAVE_MDFIND" = 1 ]; then
    printf "${C_DIM}Using the Spotlight index for fast queries; threshold >= %s.${C_RESET}\n" "$(human_kb $((MIN_BYTES / 1024)))"
else
    printf "${C_DIM}Spotlight not detected, using find fallback (slower); threshold >= %s.${C_RESET}\n" "$(human_kb $((MIN_BYTES / 1024)))"
fi

show_suspects

if [ "$MODE_FILES" -eq 1 ]; then
    section "Large files modified in the last 24 hours (most likely new usage)"
    scan_files_by_time "" 1 0

    if [ "$DAYS" -gt 1 ]; then
        section "Large files modified in the last 2 ~ ${DAYS} days"
        scan_files_by_time "" "$DAYS" 1
    fi
fi

if [ "$MODE_DIRS" -eq 1 ]; then
    section "Directory aggregation: writes in the last 24 hours (Top ${TOP_N})"
    scan_dirs_by_time "" 1 0

    if [ "$DAYS" -gt 1 ]; then
        section "Directory aggregation: writes in the last 2 ~ ${DAYS} days (Top ${TOP_N})"
        scan_dirs_by_time "" "$DAYS" 1
    fi
fi

echo ""
printf "${C_BOLD}── How to read this ──${C_RESET}\n"
cat <<'EOF'
  • Docker.raw / Docker VM growing   → run `docker system df`, prune if needed
  • Ollama / HuggingFace models      → AI model downloads, `ollama rm <model>`
  • ~/Library/Logs growing           → app logs, safe to clean
  • ~/Library/Caches growing         → app caches, safe to clean
  • Xcode/DerivedData                → build cache, safe to delete
  • New large files in ~/Downloads   → archive or delete manually after review
  • .local / .omlx / .cache growing  → dev tool caches, inspect one by one
EOF
echo ""
printf "${C_DIM}Tip: add --dirs for directory aggregation, --days 7 to widen the window, --min 10M for smaller files.${C_RESET}\n"
echo ""
