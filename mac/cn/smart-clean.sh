#!/bin/bash
# Mac 智能清理脚本
#
# 用法:
#   smart-clean.sh [--list] [--clean] [--yes]
#
#   --list   仅扫描并列出可清理项，不删除
#   --clean  进入交互确认模式（推荐，默认）
#   --yes    直接删除所有 [安全] 项，无需逐项确认（[需判断] 项仍会询问）
#
# 扫描结果分为两类:
#   [安全]   可再生缓存/临时文件/转储，删除无风险
#   [需判断] 可能包含用户数据或正在使用，需用户确认

set -uo pipefail

# ===== 阈值：只有占用超过该值(字节)的项才列出 =====
MIN_SIZE=$((10 * 1024 * 1024))   # 10MB
WARN_SIZE=$((200 * 1024 * 1024)) # 200MB，超过显示醒目提示

HUMAN_THRESH=$((10 * 1024 * 1024))

# 颜色（无 TTY 时关闭）
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
        *) echo "未知参数: $arg (可用 --list / --clean / --yes)" >&2; exit 1 ;;
    esac
done

# 默认进入交互模式
if [ "$MODE_LIST" -eq 0 ] && [ "$MODE_CLEAN" -eq 0 ] && [ "$MODE_YES" -eq 0 ]; then
    MODE_CLEAN=1
fi

# 聚合结果数组
declare -a SAFE_PATHS SAFE_DESC
declare -a REV_PATHS REV_DESC
TOTAL_SAFE=0; TOTAL_REV=0

# ---------------------------------------------------------------
# size_h 字节 -> 人类可读
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
# du_bytes 返回路径字节数（不存在/无权限返回 0）
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
# add_item 依据目标类别登记
#   add_item <safe|rev> <path> <desc> <command>
#   command: 实际删除命令（rm -rf 等）
# ---------------------------------------------------------------
add_item() {
    local cat="$1"; local path="$2"; local desc="$3"; local cmd="$4"
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
# 安全删除命令包装（打印 -> 如需立即回收才执行）
# ===============================================================
# 注意：此处只登记描述，真正执行在下方确认逻辑。

# ===============================================================
# 扫描各候选对象
# ===============================================================

# ---- [安全] 用户缓存/日志 ----
add_item safe "$HOME/Library/Caches" "用户应用缓存(Caches)" \
    "rm -rf \"$HOME/Library/Caches\"/*"
add_item safe "$HOME/Library/Logs" "用户日志(Logs)" \
    "rm -rf \"$HOME/Library/Logs\"/*"

# ---- [安全] npm / yarn / pnpm / node-gyp / pip 缓存（可再生）----
add_item safe "$HOME/.npm" "npm 缓存" \
    "npm cache clean --force 2>/dev/null; rm -rf \"$HOME/.npm\"/*"
add_item safe "$HOME/.cache/node-gyp" "node-gyp 缓存" \
    "rm -rf \"$HOME/.cache/node-gyp\"/*"
add_item safe "$HOME/Library/Caches/pip" "pip 缓存" \
    "pip3 cache purge 2>/dev/null; rm -rf \"$HOME/Library/Caches/pip\"/*"

# ---- [安全] Homebrew 缓存 & 旧版本 ----
add_item safe "$(brew --cache 2>/dev/null)" "Homebrew 下载缓存" \
    "rm -rf \"$(brew --cache 2>/dev/null)\"/*"

# ---- [安全] Xcode DerivedData / 模拟器缓存 ----
add_item safe "$HOME/Library/Developer/Xcode/DerivedData" "Xcode DerivedData(构建缓存)" \
    "rm -rf \"$HOME/Library/Developer/Xcode/DerivedData\"/*"
add_item safe "$HOME/Library/Developer/CoreSimulator/Caches" "模拟器缓存" \
    "rm -rf \"$HOME/Library/Developer/CoreSimulator/Caches\"/*"

# ---- [安全] Crash 转储 ----
add_item safe "$(find "$HOME" -maxdepth 2 -type f -name '*.hprof' 2>/dev/null | head -1)" \
    "JVM/IDE 崩溃转储(*.hprof)" \
    "find \"$HOME\" -maxdepth 2 -type f -name '*.hprof' -delete 2>/dev/null"

# ---- [安全] 核心转储 /System 临时（需 sudo，另行提示）----
# /cores 通常需要 sudo，这里做检测，若可写才列入
if [ -w /cores ] 2>/dev/null; then
    add_item safe "/cores" "核心转储(/cores)" \
        "rm -rf /cores/*"
fi

# ---- [需判断] Codex 运行时（若不用 Codex 可删）----
add_item rev "$HOME/.cache/codex-runtimes" "Codex 运行时缓存(未用 Codex 可删)" \
    "rm -rf \"$HOME/.cache/codex-runtimes\""

# ---- [需判断] HuggingFace 模型缓存 ----
add_item rev "$HOME/.cache/huggingface" "HuggingFace 模型缓存(本地推理才用)" \
    "rm -rf \"$HOME/.cache/huggingface\""

# ---- [需判断] 全局 npm 包体积过大项 ----
# 探测全局 node_modules 下超过阈值的子包
if [ -d "$HOME/.npm-global/lib/node_modules" ] || [ -d "$HOME/lib/node_modules" ]; then
    global_root="$HOME/.npm-global/lib/node_modules"
    [ -d "$global_root" ] || global_root="$HOME/lib/node_modules"
    for pkg in "$global_root"/*; do
        [ -e "$pkg" ] || continue
        b=$(du -sk "$pkg" 2>/dev/null | awk '{print $1*1024}')
        if [ "$b" -ge "$WARN_SIZE" ]; then
            add_item rev "$pkg" "全局 npm 包: $(basename "$pkg") (若不再使用可 `npm uninstall -g $(basename "$pkg")`)" \
                "npm uninstall -g --silent \"$(basename "$pkg")\" 2>/dev/null || rm -rf \"$pkg\""
        fi
    done
fi

# ---- [需判断] 项目级重依赖 (node_modules > 500MB) ----
if command -v find >/dev/null; then
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        b=$(du -sk "$nm" 2>/dev/null | awk '{print $1*1024}')
        if [ "$b" -ge $((500*1024*1024)) ]; then
            add_item rev "$nm" "项目依赖: ${nm#$HOME/} (删除需重装)" \
                "rm -rf \"$nm\""
        fi
    done < <(find "$HOME" -maxdepth 3 -type d -name node_modules 2>/dev/null)
fi

# ---- [安全] 废纸篓 (含隐藏文件, 且大小不设下限) ----
if [ -d "$HOME/.Trash" ]; then
    tbytes=$(du -sk "$HOME/.Trash" 2>/dev/null | awk '{print $1*1024}')
    SAFE_PATHS+=("$HOME/.Trash")
    SAFE_DESC+=("废纸篓(Empty Trash)|${tbytes:-0}|osascript -e 'tell application \"Finder\" to empty trash'")
    TOTAL_SAFE=$((TOTAL_SAFE + ${tbytes:-0}))
fi

# ---- [需判断] Downloads 大文件(>200MB) ----
while IFS= read -r f; do
    [ -n "$f" ] || continue
    add_item rev "$f" "下载文件夹大文件: $(basename "$f")" \
        "rm -rf \"$f\""
done < <(find "$HOME/Downloads" -type f -size +200M 2>/dev/null)

# ---- [需判断] 用户目录 >1GB 的大文件 ----
while IFS= read -r f; do
    [ -n "$f" ] || continue
    # 跳过已作为安全项登记的 hprof 及其它缓存路径，避免重复
    add_item rev "$f" "大文件(>1GB): ${f#$HOME/}" \
        "rm -rf \"$f\""
done < <(find "$HOME" -maxdepth 3 -type f -size +1G 2>/dev/null \
    -not -path '*/Library/*' -not -path '*/.hermes/*' -not -path '*/.npm/*' \
    -not -name '*.hprof')

# ===============================================================
# 打印列表
# ===============================================================
print_list() {
    echo ""
    echo "${C_BOLD}========== 扫描结果 ==========${C_RESET}"

    echo ""
    echo "${C_SAFE}■ [安全] 可直接删除 (可再生缓存/临时文件)${C_RESET}  共 ${TOTAL_SAFE:+$(size_h "$TOTAL_SAFE")}"
    if [ "${#SAFE_PATHS[@]}" -eq 0 ]; then
        echo "  (无)"
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
    echo "${C_REV}■ [需判断] 请确认是否删除 (可能含数据或在使用)${C_RESET}  共 ${TOTAL_REV:+$(size_h "$TOTAL_REV")}"
    if [ "${#REV_PATHS[@]}" -eq 0 ]; then
        echo "  (无)"
    else
        for idx in "${!REV_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${REV_DESC[$idx]}"
            printf "${C_REV}  - %s${C_RESET}${C_DIM} %s${C_RESET}  ${C_RED}%s${C_RESET}\n" \
                "$desc" "${REV_PATHS[$idx]}" "$(size_h "$bytes")"
        done
    fi

    echo ""
    echo "命令行帮助: --list(仅列出)  --clean(交互确认)  --yes(直接删安全项, 需判断项仍提问)"
}

# ---------------------------------------------------------------
# exec_cmd 执行删除命令
# ---------------------------------------------------------------
exec_cmd() {
    local cmd="$1"; local p="$2"
    echo "${C_DIM}执行: $cmd${C_RESET}"
    eval "$cmd" 2>/dev/null
    # 校验是否真的被删除/清空
    sleep 1
    if [ -f "$p" ]; then
        # 路径是文件且仍存在 -> 可能未删除（对大文件/独立文件）
        echo "  ${C_REV}⚠ 可能仍有残留: $p${C_RESET}"
    elif [ -d "$p" ]; then
        # 目录非空说明还有内容
        if [ -n "$(ls -A "$p" 2>/dev/null)" ]; then
            echo "  ${C_REV}⚠ 目录仍有内容: $p${C_RESET}"
        else
            echo "  ${C_SAFE}✓ 已清理${C_RESET}"
        fi
    else
        echo "  ${C_SAFE}✓ 已清理${C_RESET}"
    fi
}

# ---------------------------------------------------------------
# 交互确认 & 删除
# ---------------------------------------------------------------
do_clean() {
    # 阶段1: 处理 [安全] 项
    echo ""
    echo "${C_BOLD}── 第 1 步: 处理 [安全] 项 ──${C_RESET}"
    if [ "${#SAFE_PATHS[@]}" -eq 0 ]; then
        echo "  (无安全项可清理)"
    else
        local next=1
        for idx in "${!SAFE_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${SAFE_DESC[$idx]}"
            local q="程序问: ${C_SAFE}[${desc}]${C_RESET} ${SAFE_PATHS[$idx]} ($(size_h "$bytes")) 删除? [y/N] "
            if [ "$MODE_YES" -eq 1 ]; then
                echo "${C_DIM}--yes 自动确认: ${desc}${C_RESET}"
                ans="y"
            else
                read -r -p "${C_RESET}$q" ans
            fi
            case "$ans" in
                y|Y|yes|YES) exec_cmd "$cmd" "${SAFE_PATHS[$idx]}" ;;
                *) echo "  跳过" ;;
            esac
            next=$((next+1))
        done
    fi

    # 阶段2: 处理 [需判断] 项
    echo ""
    echo "${C_BOLD}── 第 2 步: 处理 [需判断] 项 ──${C_RESET}"
    if [ "${#REV_PATHS[@]}" -eq 0 ]; then
        echo "  (无需判断项)"
    else
        for idx in "${!REV_PATHS[@]}"; do
            IFS='|' read -r desc bytes cmd <<< "${REV_DESC[$idx]}"
            read -r -p "${C_RESET}${C_REV}需判断: ${desc}${C_RESET} ${REV_PATHS[$idx]} ($(size_h "$bytes")) 确认删除? [y/N] " ans
            case "$ans" in
                y|Y|yes|YES) exec_cmd "$cmd" "${REV_PATHS[$idx]}" ;;
                *) echo "  跳过" ;;
            esac
        done
    fi
    echo ""
    echo "${C_SAFE}✅ 清理结束${C_RESET}"
}

# ===============================================================
# 主流程
# ===============================================================
if [ "$MODE_LIST" -eq 1 ]; then
    print_list
    exit 0
fi

print_list

if [ "$MODE_CLEAN" -eq 1 ] || [ "$MODE_YES" -eq 1 ]; then
    echo ""
    read -r -p "${C_REV}是否开始清理? [y/N] ${C_RESET}" confirm
    case "$confirm" in
        y|Y|yes|YES) do_clean ;;
        *) echo "已取消，未删除任何内容。" ;;
    esac
fi