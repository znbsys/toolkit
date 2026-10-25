#!/bin/bash
# smart-clean.sh - Interactive cleanup for macOS
#
# Usage:
#   smart-clean.sh [--list] [--clean] [--yes]
#
#   --list   Scan and list cleanable items only, delete nothing
#   --clean  Interactive confirmation mode (recommended, default)
#   --yes    Delete all [SAFE] items without per-item prompts
#            ([REVIEW] items still ask)
#
# Scan results are grouped into two categories:
#   [SAFE]   Regenerable caches / temp files / dumps, no risk
#   [REVIEW] May contain user data or be in use, needs confirmation

set -uo pipefail

# ===== Threshold: only items larger than this (bytes) are listed =====
MIN_SIZE=$((10 * 1024 * 1024))   # 10MB
WARN_SIZE=$((200 * 1024 * 1024)) # 200MB, highlight items above this

# Colors (disabled when not a TTY)
if [ -t 1 ]; then
    C_SAFE=$'\033[32m'; C_REV=$'\033[33m'; C_RED=$'\033[31m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_SAFE=""; C_REV=""; C_RED=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

MODE_LIST=0; MODE_CLEAN=0; MODE_YES=0
for arg in "$@"; do
    case "$arg" in
        --list) MODE_LIST=1 ;;
        --clean) MODE_CLEAN=1 ;;
        --yes) MODE_YES=1 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^#/ /'; exit 0 ;;
        *) echo "Unknown argument: $arg (available: --list / --clean / --yes)" >&2; exit 1 ;;
    esac
done

# Default to interactive mode
if [ "$MODE_LIST" -eq 0 ] && [ "$MODE_CLEAN" -eq 0 ] && [ "$MODE_YES" -eq 0 ]; then
    MODE_CLEAN=1
fi

# Result arrays
declare -a SAFE_PATHS SAFE_DESC
declare -a REV_PATHS REV_DESC
TOTAL_SAFE=0; TOTAL_REV=0

# ---------------------------------------------------------------
# size_h bytes -> human readable
# ---------------------------------------------------------------
size_h() {
    local b=$1
    if [ "$b" -ge $((1024*1024*1024)) ]; then
        awk -v x="$b" 'BEGIN{printf "%.1fG", x/1024/1024/1024}'
    elif [ "$b" -ge $((1024*1024)) ]; then
        awk -v x="$b" 'BEGIN{printf "%.1fM", x/1024/1024}'
    elif [ "$b" -ge 1024 ]; then
        awk -v x="$b" 'BEGIN{printf "%.0fK", x/1024}'
    else
        echo "${b}B"
    fi
}

# ---------------------------------------------------------------
# du_bytes returns the size in bytes of a path (0 if missing/no access)
# ---------------------------------------------------------------
du_bytes() {
    local path="$1"
    [ -e "$path" ] || { echo 0; return; }
    if [ -d "$path" ]; then
        du -sk "$path" 2>/dev/null | awk '{print $1*1024}'
    else
        stat -f%z "$path" 2>/dev/null || echo 0
    fi
}

# ---------------------------------------------------------------
# add_item register an item under its category
#   add_item <safe|rev> <path> <desc> <command>
#   command: the actual deletion command (rm -rf etc.)
# ---------------------------------------------------------------
add_item() {
    local cat="$1"; local path="$2"; local desc="$3"; local cmd="$4"
    [ -n "$path" ] || return
    local bytes; bytes=$(du_bytes "$path")
    if [ "$bytes" -ge "$MIN_SIZE" ]; then
        if [ "$cat" = safe ]; then
            SAFE_PATHS+=("$path"); SAFE_DESC+=("$desc|$bytes|$cmd")
            TOTAL_SAFE=$((TOTAL_SAFE + bytes))
        else
            REV_PATHS+=("$path"); REV_DESC+=("$desc|$bytes|$cmd")
            TOTAL_REV=$((TOTAL_REV + bytes))
        fi
    fi
}

# ===============================================================
# Scan candidates
# ===============================================================

# ---- [SAFE] User caches / logs ----
add_item safe "$HOME/Library/Caches" "User app caches (Caches)" \
    "rm -rf \"$HOME/Library/Caches\"/*"
add_item safe "$HOME/Library/Logs" "User logs (Logs)" \
    "rm -rf \"$HOME/Library/Logs\"/*"

# ---- [SAFE] npm / yarn / pnpm / node-gyp / pip caches (regenerable) ----
add_item safe "$HOME/.npm" "npm cache" \
    "npm cache clean --force 2>/dev/null; rm -rf \"$HOME/.npm\"/*"
add_item safe "$HOME/.cache/node-gyp" "node-gyp cache" \
    "rm -rf \"$HOME/.cache/node-gyp\"/*"
add_item safe "$HOME/Library/Caches/pip" "pip cache" \
    "pip3 cache purge 2>/dev/null; rm -rf \"$HOME/Library/Caches/pip\"/*"

# ---- [SAFE] Homebrew cache & old versions ----
add_item safe "$(brew --cache 2>/dev/null)" "Homebrew download cache" \
    "rm -rf \"$(brew --cache 2>/dev/null)\"/*"

# ---- [SAFE] Xcode DerivedData / simulator caches ----
add_item safe "$HOME/Library/Developer/Xcode/DerivedData" "Xcode DerivedData (build cache)" \
    "rm -rf \"$HOME/Library/Developer/Xcode/DerivedData\"/*"
add_item safe "$HOME/Library/Developer/CoreSimulator/Caches" "Simulator caches" \
    "rm -rf \"$HOME/Library/Developer/CoreSimulator/Caches\"/*"

# ---- [SAFE] Crash dumps ----
add_item safe "$(find "$HOME" -maxdepth 2 -type f -name '*.hprof' 2>/dev/null | head -1)" \
    "JVM/IDE crash dumps (*.hprof)" \
    "find \"$HOME\" -maxdepth 2 -type f -name '*.hprof' -delete 2>/dev/null"

# ---- [SAFE] Core dumps in /System (need sudo, detected separately) ----
# /cores usually requires sudo; only list it if writable
if [ -w /cores ] 2>/dev/null; then
    add_item safe "/cores" "Core dumps (/cores)" \
        "rm -rf /cores/*"
fi

# ---- [REVIEW] Codex runtimes (delete if you don't use Codex) ----
add_item rev "$HOME/.cache/codex-runtimes" "Codex runtime cache (delete if unused)" \
    "rm -rf \"$HOME/.cache/codex-runtimes\""

# ---- [REVIEW] HuggingFace model cache ----
add_item rev "$HOME/.cache/huggingface" "HuggingFace model cache (needed for local inference)" \
    "rm -rf \"$HOME/.cache/huggingface\""

# ---- [REVIEW] Oversized global npm packages ----
if [ -d "$HOME/.npm-global/lib/node_modules" ] || [ -d "$HOME/lib/node_modules" ]; then
    global_root="$HOME/.npm-global/lib/node_modules"
    [ -d "$global_root" ] || global_root="$HOME/lib/node_modules"
    for pkg in "$global_root"/*; do
        [ -e "$pkg" ] || continue
        b=$(du -sk "$pkg" 2>/dev/null | awk '{print $1*1024}')
        if [ "$b" -ge "$WARN_SIZE" ]; then
            add_item rev "$pkg" "Global npm package: $(basename "$pkg") (uninstall with npm uninstall -g if unused)" \
                "npm uninstall -g --silent \"$(basename "$pkg")\" 2>/dev/null || rm -rf \"$pkg\""
        fi
    done
fi

# ---- [REVIEW] Project node_modules > 500MB ----
if command -v find >/dev/null; then
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        b=$(du -sk "$nm" 2>/dev/null | awk '{print $1*1024}')
        if [ "$b" -ge $((500*1024*1024)) ]; then
            add_item rev "$nm" "Project deps: ${nm#$HOME/} (needs reinstall after delete)" \
                "rm -rf \"$nm\""
        fi
    done < <(find "$HOME" -maxdepth 3 -type d -name node_modules 2>/dev/null)
fi

# ---- [SAFE] Trash (includes hidden files, no size floor) ----
if [ -d "$HOME/.Trash" ]; then
    tbytes=$(du -sk "$HOME/.Trash" 2>/dev/null | awk '{print $1*1024}')
    SAFE_PATHS+=("$HOME/.Trash")
    SAFE_DESC+=("Trash (Empty Trash)|${tbytes:-0}|osascript -e 'tell application \"Finder\" to empty trash'")
    TOTAL_SAFE=$((TOTAL_SAFE + ${tbytes:-0}))
fi

# ---- [REVIEW] Large files in Downloads (>200MB) ----
while IFS= read -r f; do
    [ -n "$f" ] || continue
    add_item rev "$f" "Large download: $(basename "$f")" \
        "rm -rf \"$f\""
done < <(find "$HOME/Downloads" -type f -size +200M 2>/dev/null)

# ---- [REVIEW] Large files in home (>1GB) ----
while IFS= read -r f; do
    [ -n "$f" ] || continue
    add_item rev "$f" "Large file (>1GB): ${f#$HOME/}" \
        "rm -rf \"$f\""
done < <(find "$HOME" -maxdepth 3 -type f -size +1G 2>/dev/null \
    -not -path '*/Library/*' -not -path '*/.hermes/*' -not -path '*/.npm/*' \
    -not -name '*.hprof')

# ===============================================================
# Print the list
# ===============================================================
print_list() {
    echo ""
    echo "${C_BOLD}========== Scan Results ==========${C_RESET}"

    echo ""
    echo "${C_SAFE}■ [SAFE] Ready to delete (regenerable caches/temp files)${C_RESET}  total ${TOTAL_SAFE:+$(size_h "$TOTAL_SAFE")}"
    if [ "${#SAFE_PATHS[@]}" -eq 0 ]; then
        echo "  (none)"
    else
        i=1
        for idx in "${!SAFE_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${SAFE_DESC[$idx]}"
            printf "${C_SAFE}  %d.%s${C_RESET}${C_DIM} %s${C_RESET}  ${C_RED}%s${C_RESET}\n" \
                "$i" "$desc" "${SAFE_PATHS[$idx]}" "$(size_h "$bytes")"
            i=$((i+1))
        done
    fi

    echo ""
    echo "${C_REV}■ [REVIEW] Confirm before deleting (may hold data or be in use)${C_RESET}  total ${TOTAL_REV:+$(size_h "$TOTAL_REV")}"
    if [ "${#REV_PATHS[@]}" -eq 0 ]; then
        echo "  (none)"
    else
        for idx in "${!REV_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${REV_DESC[$idx]}"
            printf "${C_REV}  - %s${C_RESET}${C_DIM} %s${C_RESET}  ${C_RED}%s${C_RESET}\n" \
                "$desc" "${REV_PATHS[$idx]}" "$(size_h "$bytes")"
        done
    fi

    echo ""
    echo "Options: --list(list only)  --clean(interactive)  --yes(auto-delete SAFE items, REVIEW still asks)"
}

# ---------------------------------------------------------------
# exec_cmd run a deletion command
# ---------------------------------------------------------------
exec_cmd() {
    local cmd="$1"; local p="$2"
    echo "${C_DIM}Running: $cmd${C_RESET}"
    eval "$cmd" 2>/dev/null
    # Verify the item was actually removed
    sleep 1
    if [ -f "$p" ]; then
        echo "  ${C_REV}⚠ Possible residue: $p${C_RESET}"
    elif [ -d "$p" ]; then
        if [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
            echo "  ${C_REV}⚠ Directory still has content: $p${C_RESET}"
        else
            echo "  ${C_SAFE}✓ Cleaned${C_RESET}"
        fi
    else
        echo "  ${C_SAFE}✓ Cleaned${C_RESET}"
    fi
}

# ---------------------------------------------------------------
# Interactive confirmation & deletion
# ---------------------------------------------------------------
do_clean() {
    # Stage 1: [SAFE] items
    echo ""
    echo "${C_BOLD}── Step 1: [SAFE] items ──${C_RESET}"
    if [ "${#SAFE_PATHS[@]}" -eq 0 ]; then
        echo "  (no safe items to clean)"
    else
        for idx in "${!SAFE_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${SAFE_DESC[$idx]}"
            local q="${C_SAFE}[${desc}]${C_RESET} ${SAFE_PATHS[$idx]} ($(size_h "$bytes")) delete? [y/N] "
            if [ "$MODE_YES" -eq 1 ]; then
                echo "${C_DIM}--yes auto-confirmed: ${desc}${C_RESET}"
                ans="y"
            else
                read -r -p "${C_RESET}$q" ans
            fi
            case "$ans" in
                y|Y|yes|YES) exec_cmd "$cmd" "${SAFE_PATHS[$idx]}" ;;
                *) echo "  Skipped" ;;
            esac
        done
    fi

    # Stage 2: [REVIEW] items
    echo ""
    echo "${C_BOLD}── Step 2: [REVIEW] items ──${C_RESET}"
    if [ "${#REV_PATHS[@]}" -eq 0 ]; then
        echo "  (no review items)"
    else
        for idx in "${!REV_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${REV_DESC[$idx]}"
            read -r -p "${C_RESET}${C_REV}Review: ${desc}${C_RESET} ${REV_PATHS[$idx]} ($(size_h "$bytes")) confirm delete? [y/N] " ans
            case "$ans" in
                y|Y|yes|YES) exec_cmd "$cmd" "${REV_PATHS[$idx]}" ;;
                *) echo "  Skipped" ;;
            esac
        done
    fi
    echo ""
    echo "${C_SAFE}✅ Cleanup finished${C_RESET}"
}

# ===============================================================
# Main flow
# ===============================================================
if [ "$MODE_LIST" -eq 1 ]; then
    print_list
    exit 0
fi

print_list

if [ "$MODE_CLEAN" -eq 1 ] || [ "$MODE_YES" -eq 1 ]; then
    echo ""
    read -r -p "${C_REV}Start cleanup? [y/N] ${C_RESET}" confirm
    case "$confirm" in
        y|Y|yes|YES) do_clean ;;
        *) echo "Cancelled, nothing was deleted." ;;
    esac
fi
