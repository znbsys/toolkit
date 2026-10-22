#!/bin/bash
# disk-overview.sh - Mac 磁盘占用快速显示脚本
#
# 用法:
#   bash disk-overview.sh           # 显示整体占用 + 各卷使用率
#   bash disk-overview.sh --top     # 追加显示顶层目录占用 Top N
#   bash disk-overview.sh --deep    # 追加显示 ~/Library 等大目录明细
#
# 只读脚本，不做任何删除操作。

set -u

TOP_N=10

# 颜色（无 TTY 时关闭）
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
        *) echo "未知参数: $arg (可用 --top / --deep)" >&2; exit 1 ;;
    esac
done

# ---------- 工具函数 ----------

# 根据使用率着色
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

# ---------- 1. 卷使用概览 ----------

show_volumes() {
    section "卷使用概览"
    # macOS 主数据卷
    if [ "$(uname -s)" = "Darwin" ]; then
        local line device size used avail pct mount
        printf "  %-28s %8s %8s %8s %6s\n" "卷" "总量" "已用" "可用" "使用率"
        printf "  %-28s %8s %8s %8s %6s\n" "----" "----" "----" "----" "----"
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
        # 进度条
        local raw_pct
        raw_pct=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}')
        if [ -n "${raw_pct:-}" ] && [ "$raw_pct" -ge 0 ] 2>/dev/null; then
            local filled=$((raw_pct / 5))  # 20 格
            local bar=""
            for i in $(seq 1 20); do
                if [ "$i" -le "$filled" ]; then bar+="█"; else bar+="░"; fi
            done
            printf "  总使用率: %s %s\n" "$bar" "$(color_pct "${raw_pct}%")"
        fi
    else
        df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR==1 || NR>1 {printf "  %s\n", $0}'
    fi
}

# ---------- 2. 家目录占用 ----------

show_home() {
    section "家目录一级子目录占用 Top ${TOP_N}"
    du -sh "$HOME"/* "$HOME"/.[!.]* 2>/dev/null \
        | sort -rh \
        | head -"${TOP_N}" \
        | awk '{printf "  %-8s %s\n", $1, $2}'
}

# ---------- 3. 顶层目录 ----------

show_top() {
    section "系统顶层目录占用 (可能较慢)"
    echo "  ${C_DIM}扫描中，约需 10-30 秒...${C_RESET}"
    # 仅扫描常见大目录，避免扫 /System 造成误报
    local dirs=(/Applications /Library /Users /opt /usr/local /private/var/vm)
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        du -sh "$d" 2>/dev/null
    done | sort -rh | awk '{printf "  %-8s %s\n", $1, $2}'
}

# ---------- 4. 大目录明细 ----------

show_deep() {
    section "大目录明细"
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
    printf "  %-55s %8s\n" "路径" "大小"
    printf "  %-55s %8s\n" "----" "----"
    for d in "${targets[@]}"; do
        [ -d "$d" ] || continue
        local sz
        sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        [ -n "${sz:-}" ] && printf "  %-55s %8s\n" "${d/#$HOME/~}" "$sz"
    done
}

# ---------- 主流程 ----------

printf "${C_BOLD}══════════ 磁盘占用概览 (%s) ══════════${C_RESET}\n" "$(date '+%Y-%m-%d %H:%M')"

show_volumes
show_home

[ "$MODE_TOP" -eq 1 ] && show_top
[ "$MODE_DEEP" -eq 1 ] && show_deep

echo ""
printf "${C_DIM}提示: 加 --top 查看系统顶层目录，加 --deep 查看开发大目录明细${C_RESET}\n"
echo ""
