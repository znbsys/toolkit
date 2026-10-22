#!/bin/bash
# disk-timeline.sh - 按修改时间分析磁盘占用，定位最近磁盘增长原因
#
# 用法:
#   bash disk-timeline.sh              # 默认: 最近 3 天，>=50M 的大文件
#   bash disk-timeline.sh --days 7     # 时间窗口改为最近 7 天
#   bash disk-timeline.sh --min 10M    # 降低文件大小阈值
#   bash disk-timeline.sh --dirs       # 按目录聚合(看哪个目录最近写入多)
#   bash disk-timeline.sh --all        # 文件 + 目录一起看
#
# 原理: 磁盘被占用增长 = 文件被写入/修改。用 macOS Spotlight 索引
#       (mdfind) 秒级查询最近修改的大文件；无 Spotlight 时退回 find。
#
# 只读脚本，不做任何删除操作。

set -u

DAYS=3
MIN_BYTES=$((50 * 1024 * 1024))   # 50M
TOP_N=20
MODE_FILES=1
MODE_DIRS=0

# 颜色（无 TTY 时关闭）
if [ -t 1 ]; then
    C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
    C_BOLD=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_RESET=""
fi

usage() {
    sed -n '2,14p' "$0" | sed 's/^#/ /'
    cat <<EOF

选项:
  --days N    时间窗口(天)，默认 3
  --min SIZE  最小文件大小阈值，默认 50M (如 10M / 1G)
  --dirs      按目录聚合统计
  --all       文件与目录都统计
  -h, --help  显示帮助
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
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

section() { printf "\n${C_CYAN}══ %s ══${C_RESET}\n" "$1"; }
sub()     { printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

# Spotlight 是否可用（且已建索引）
HAVE_MDFIND=0
if command -v mdfind >/dev/null 2>&1; then
    # 快速探测：查最近 1 大文件能否返回（排除索引未建/被禁用）
    if mdfind -onlyin "$HOME" 'kMDItemFSSize >= 104857600' 2>/dev/null | head -1 | grep -q .; then
        HAVE_MDFIND=1
    fi
fi

# ---------------------------------------------------------------------------
# 核心查询: 输出 "size_bytes|mtime_epoch|path" 每行一条
#   $1 = 窗口起点天数(含)，$2 = 窗口终点天数(不含，可为 0 表示现在)
#   天数含义: 1=最近24h, 2=昨天, 7=最近7天
# ---------------------------------------------------------------------------
query_recent_files() {
    local days_from="$1" days_to="${2:-0}"
    local min_mb=$(( MIN_BYTES / 1024 / 1024 ))

    if [ "$HAVE_MDFIND" = 1 ]; then
        # mdfind 日期语法: $time.today(-N) = N 天前
        # 查询 [days_to 天前, days_from-1 天前] 区间
        local expr
        if [ "$days_to" -le 0 ]; then
            expr="kMDItemFSSize >= $((min_mb * 1024 * 1024)) && kMDItemContentModificationDate >= \$time.today(-$days_from)"
        else
            expr="kMDItemFSSize >= $((min_mb * 1024 * 1024)) && kMDItemContentModificationDate >= \$time.today(-$days_from) && kMDItemContentModificationDate < \$time.today(-$((days_to - 1)))"
        fi
        # 同时查用户目录和系统应用目录
        mdfind -onlyin "$HOME" "$expr" 2>/dev/null
        mdfind -onlyin /Applications "$expr" 2>/dev/null
        mdfind -onlyin /Library "$expr" 2>/dev/null
    else
        # find 兜底：只扫精简过的目录，避免全盘扫描卡死
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

# 把路径列表转成 "bytes|mtime|path"，并按大小排序取 Top N
format_and_sort() {
    # 读入路径（stdin），输出排序后的带大小行
    local path
    local lines=()
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        # 跳过目录（mdfind 有时会返回目录）
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
# 1. 按时间段扫描大文件
# ---------------------------------------------------------------------------
scan_files_by_time() {
    local label="$1" days_from="$2" days_to="${3:-0}"
    sub "$label"

    local tmp
    tmp=$(mktemp)
    query_recent_files "$days_from" "$days_to" | format_and_sort > "$tmp"

    if [ ! -s "$tmp" ]; then
        echo "  (无 >= $(human_kb $((MIN_BYTES / 1024))) 的文件)"
        rm -f "$tmp"; return
    fi

    print_file_rows < "$tmp"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 2. 目录聚合
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
        # 用制表符分隔，避免路径中空格被 awk 拆开
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
        echo "  (无)"
        rm -f "$tmp"; return
    fi

    printf "  %-10s %6s  %s\n" "累计大小" "文件数" "目录"
    printf "  %-10s %6s  %s\n" "--------" "------" "----"
    local kb cnt path human disp
    while IFS=$'\t' read -r kb cnt path; do
        human=$(human_kb $((kb / 1024)))
        disp="${path/#$HOME/~}"
        printf "  ${C_RED}%-10s${C_RESET} %6s  %s\n" "$human" "$cnt" "$disp"
    done < "$tmp"

    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# 3. 快速嫌疑目录提示
# ---------------------------------------------------------------------------
show_suspects() {
    section "常见增长源快速体检"
    local suspects=(
        "$HOME/Library/Caches|应用缓存"
        "$HOME/Library/Logs|应用日志"
        "$HOME/Library/Containers/com.docker.docker|Docker 虚拟机磁盘"
        "$HOME/.ollama/models|Ollama 模型"
        "$HOME/.cache|通用缓存"
        "$HOME/Downloads|下载目录"
        "$HOME/Library/Developer/Xcode/DerivedData|Xcode 构建缓存"
        "$HOME/Library/Application Support|应用数据"
        "/Applications|应用程序"
        "$HOME/.local|本地安装(.local)"
        "$HOME/.omlx|omlx 数据"
    )
    printf "  %-12s  %s\n" "大小" "目录 (含说明)"
    printf "  %-12s  %s\n" "----" "----"
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
# 主流程
# ---------------------------------------------------------------------------
printf "${C_BOLD}════════ 磁盘占用时间线分析 (窗口: 最近 ${DAYS} 天) ════════${C_RESET}\n"
if [ "$HAVE_MDFIND" = 1 ]; then
    printf "${C_DIM}使用 Spotlight 索引查询，速度较快；阈值 >= %s。${C_RESET}\n" "$(human_kb $((MIN_BYTES / 1024)))"
else
    printf "${C_DIM}未检测到 Spotlight，使用 find 兜底(较慢)；阈值 >= %s。${C_RESET}\n" "$(human_kb $((MIN_BYTES / 1024)))"
fi

show_suspects

if [ "$MODE_FILES" -eq 1 ]; then
    section "最近 24 小时内修改的大文件 (最可能的新增占用)"
    scan_files_by_time "" 1 0

    if [ "$DAYS" -gt 1 ]; then
        # 第2天到第DAYS天
        local_label="最近 2 ~ ${DAYS} 天内修改的大文件"
        section "$local_label"
        # days_from=1 表示起点是1天前，但我们要 [2, DAYS] 区间：
        # mdfind 区间用 today(-1) <= t < today(-(DAYS-1)) 对应 [1, DAYS-1]...
        # 简化：days_from = DAYS+1, days_to = 2 → [today(-(DAYS+1)), today(-1))
        # 实际想要: t >= today(-DAYS) 且 t < today(-1)
        # 即 days_from=DAYS, days_to=1 (days_to=1 表示 < today(-0) 即今天，但我们要 < 昨天)
        # 直接用参数: query 区间 [days_to, days_from)
        scan_files_by_time "" "$DAYS" 1
    fi
fi

if [ "$MODE_DIRS" -eq 1 ]; then
    section "目录聚合: 最近 24 小时写入量 Top ${TOP_N}"
    scan_dirs_by_time "" 1 0

    if [ "$DAYS" -gt 1 ]; then
        section "目录聚合: 最近 2 ~ ${DAYS} 天写入量 Top ${TOP_N}"
        scan_dirs_by_time "" "$DAYS" 1
    fi
fi

echo ""
printf "${C_BOLD}── 解读建议 ──${C_RESET}\n"
cat <<'EOF'
  • Docker.raw / Docker 虚拟机变大     → docker system df 查看，必要时 prune
  • Ollama / HuggingFace 模型          → AI 模型下载，按需 ollama rm
  • ~/Library/Logs 增长               → 应用日志，可安全清理
  • ~/Library/Caches 增长             → 应用缓存，可安全清理
  • Xcode/DerivedData                  → 构建缓存，可安全删除
  • ~/Downloads 新增大文件             → 手动确认后归档/删除
  • .local / .omlx / .cache 增长      → 开发工具缓存，逐个检查
EOF
echo ""
printf "${C_DIM}提示: 加 --all 同时看目录聚合；加 --days 7 扩大窗口；--min 10M 看更小的文件。${C_RESET}\n"
echo ""
