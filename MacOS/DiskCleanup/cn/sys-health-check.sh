#!/bin/bash
# =============================================================================
# sys-health-check.sh — 电脑健康检查与安全优化脚本 (v1.1 修复 macOS 兼容)
# 兼容: Linux (systemd) / macOS
# 级别: L0 只读检查 + L1 安全清理(只删用户级缓存/日志/临时文件)
#
# 用法:
#   bash sys-health-check.sh              # 默认: 健康检查 + 优化预演(只统计不删除)
#   bash sys-health-check.sh --check      # 仅健康检查
#   bash sys-health-check.sh --optimize   # 仅优化预演
#   bash sys-health-check.sh --execute    # 实际执行清理(需配合 --optimize)
#   bash sys-health-check.sh --help       # 帮助
#
# 安全承诺:
#   - 不使用 sudo,不碰系统目录 (/System /Library /usr /etc /var)
#   - 不碰个人文件 (桌面/文档/下载/图片/视频)
#   - 不清空回收站/废纸篓(不可逆,需用户自行处理)
#   - 只删除可再生的缓存、日志、临时文件
#   - 删除前统计可释放空间,默认预演模式
# =============================================================================

set -u

# ---------- 全局变量 ----------
MODE_CHECK=1
MODE_OPTIMIZE=1
DRY_RUN=1
TOTAL_FREED_KB=0
OS_TYPE=""

# ---------- 颜色输出 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[信息]${NC} $*"; }
success() { echo -e "${GREEN}[完成]${NC} $*"; }
warn()    { echo -e "${YELLOW}[警告]${NC} $*"; }
error()   { echo -e "${RED}[错误]${NC} $*"; }
section() { echo -e "\n${CYAN}========== $* ==========${NC}"; }

# ---------- 参数解析 ----------
usage() {
  cat <<EOF
用法: bash $0 [选项]

选项:
  --check      仅执行健康检查 (CPU/内存/硬盘/网络/启动项)
  --optimize   仅执行安全优化 (默认预演,不删除)
  --execute    与 --optimize 配合,实际执行删除操作
  --help       显示此帮助

示例:
  bash $0                  # 健康检查 + 优化预演
  bash $0 --check          # 只检查
  bash $0 --optimize       # 只看能清多少(预演)
  bash $0 --optimize --execute  # 实际清理
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
    *) error "未知参数: $arg"; usage; exit 2 ;;
  esac
done

if [ "$check_only" = "1" ] && [ "$opt_only" = "1" ]; then
  MODE_CHECK=1; MODE_OPTIMIZE=1
elif [ "$check_only" = "1" ]; then
  MODE_CHECK=1; MODE_OPTIMIZE=0
elif [ "$opt_only" = "1" ]; then
  MODE_CHECK=0; MODE_OPTIMIZE=1
fi

# ---------- 系统检测 ----------
detect_os() {
  case "$(uname -s)" in
    Darwin) OS_TYPE="macos" ;;
    Linux)  OS_TYPE="linux" ;;
    *)      error "不支持的操作系统: $(uname -s)"; exit 1 ;;
  esac
  info "检测到系统: $OS_TYPE ($(uname -r))"
}

# ---------- 工具函数 ----------
# 目录大小(KB), 永远返回数字, 不存在或失败返回 0
dir_size_kb() {
  local path="${1:-}"
  if [ -n "$path" ] && [ -d "$path" ]; then
    local s
    s=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
    # 确保返回纯数字
    if echo "$s" | grep -qE '^[0-9]+$'; then
      echo "$s"
    else
      echo 0
    fi
  else
    echo 0
  fi
}

# KB 转人类可读 (兼容 macOS BSD awk, 使用 -v 传参 + 单引号程序)
kb_to_human() {
  local kb="${1:-0}"
  # 确保是正整数
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

# 安全加法 (避免空值导致算术错误)
safe_add() {
  local a="${1:-0}" b="${2:-0}"
  echo "$((a + b))"
}

# =============================================================================
# 健康检查模块
# =============================================================================

check_cpu() {
  section "CPU 检查"
  if [ "$OS_TYPE" = "macos" ]; then
    echo "  型号: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '未知')"
    echo "  核心数(物理): $(sysctl -n hw.physicalcpu 2>/dev/null || echo '?')"
    echo "  核心数(逻辑): $(sysctl -n hw.logicalcpu 2>/dev/null || echo '?')"
    # CPU 使用率 (取采样)
    local cpu_usage
    cpu_usage=$(top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $3+$5}' | sed 's/%//')
    [ -z "$cpu_usage" ] && cpu_usage=$(ps -A -o %cpu | awk 'NR>1 {s+=$1} END {printf "%.1f", s}')
    echo "  当前使用率: ${cpu_usage:-?}%"
    # CPU 温度 (Apple Silicon 需额外工具, 这里只尝试)
    if command -v osx-cpu-temp >/dev/null 2>&1; then
      echo "  CPU 温度: $(osx-cpu-temp 2>/dev/null || echo '无法读取')"
    else
      echo "  CPU 温度: 未安装 osx-cpu-temp (可通过 brew install osx-cpu-temp 安装)"
    fi
  else
    echo "  型号: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo '未知')"
    echo "  核心数(逻辑): $(nproc 2>/dev/null || echo '?')"
    echo "  系统负载 (1/5/15分钟): $(uptime 2>/dev/null | awk -F'load average:' '{print $2}' | xargs)"
    local cpu_usage
    cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print 100-$8}' || echo "?")
    echo "  当前使用率: ${cpu_usage}%"
    if command -v sensors >/dev/null 2>&1; then
      echo "  CPU 温度: $(sensors 2>/dev/null | grep -i 'core 0' | head -1 | awk '{print $3}' || echo '无法读取')"
    else
      echo "  CPU 温度: 未安装 lm-sensors"
    fi
  fi
}

check_memory() {
  section "内存检查"
  if [ "$OS_TYPE" = "macos" ]; then
    local total_mem
    total_mem=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.1f", $1/1073741824}')
    echo "  总内存: ${total_mem:-?} GB"
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
    echo "  已使用: ~${used_mb} MB (含活跃+联动内存)"
    echo "  空闲: ~${free_mb} MB"
  else
    if command -v free >/dev/null 2>&1; then
      free -h | head -2
    else
      echo "  总内存: $(awk '/MemTotal/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
      echo "  可用内存: $(awk '/MemAvailable/ {printf "%.1f GB", $2/1048576}' /proc/meminfo 2>/dev/null)"
    fi
    local swap_total swap_used
    swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    swap_used=$(awk '/SwapFree/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "${swap_total:-}" ] && [ "$swap_total" -gt 0 ] 2>/dev/null; then
      local swap_used_kb=$((swap_total - swap_used))
      echo "  Swap: 已用 $(kb_to_human $swap_used_kb) / 总计 $(kb_to_human $swap_total)"
    fi
  fi
  echo "  --- 内存占用 TOP 5 ---"
  if [ "$OS_TYPE" = "macos" ]; then
    ps -Ao pid,comm,%mem -r 2>/dev/null | head -6 | awk 'NR>1 {printf "  %-8s %-30s %s%%\n", $1, $2, $3}'
  else
    ps aux --sort=-%mem 2>/dev/null | head -6 | awk 'NR>1 {printf "  %-8s %-30s %s%%\n", $2, $11, $4}'
  fi
}

check_disk() {
  section "硬盘空间检查"
  echo "  挂载点               总量    已用    可用    使用率"
  echo "  ----------------------------------------------------"
  if [ "$OS_TYPE" = "macos" ]; then
    df -h / /System/Volumes/Data 2>/dev/null | awk 'NR>1 {printf "  %-20s %-7s %-7s %-7s %s\n", $9, $2, $3, $4, $5}'
  else
    df -h -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1 {printf "  %-20s %-7s %-7s %-7s %s\n", $6, $2, $3, $4, $5}'
  fi
  echo ""
  info "用户目录占用 TOP 5 (仅统计,不删除):"
  du -sh "$HOME"/* 2>/dev/null | sort -rh | head -5 | awk '{printf "  %-8s %s\n", $1, $2}'
}

check_network() {
  section "网络检查"
  echo "  --- 网络接口状态 ---"
  if [ "$OS_TYPE" = "macos" ]; then
    ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | grep -v "127.0.0.1" | grep -v "inet6" | \
      awk '/^[a-z]/ {iface=$1} /inet / {printf "  %-12s IP: %s\n", iface, $2}'
  else
    ip -4 addr show 2>/dev/null | grep -v "127.0.0.1" | \
      awk '/^[0-9]/ {iface=$2} /inet / {printf "  %-12s IP: %s\n", iface, $2}'
  fi
  echo ""
  echo "  --- 连通性测试 ---"
  local targets=("223.5.5.5" "8.8.8.8" "baidu.com" "google.com")
  for target in "${targets[@]}"; do
    if ping -c 2 -W 2 "$target" >/dev/null 2>&1; then
      local latency
      latency=$(ping -c 2 -W 2 "$target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}' | awk '{printf "%.1f", $1}')
      success "连通 $target (延迟 ${latency:-?}ms)"
    else
      warn "无法连通 $target"
    fi
  done
  echo ""
  echo "  --- DNS 解析 ---"
  if command -v nslookup >/dev/null 2>&1; then
    nslookup baidu.com 2>/dev/null | grep -A2 "Name:" | head -3 || warn "DNS 解析可能异常"
  elif command -v dig >/dev/null 2>&1; then
    dig +short baidu.com 2>/dev/null | head -3 || warn "DNS 解析可能异常"
  else
    echo "  未安装 nslookup/dig,跳过 DNS 详细测试"
  fi
}

check_startup() {
  section "启动项检查"
  if [ "$OS_TYPE" = "macos" ]; then
    echo "  --- 用户登录项 (LaunchAgents) ---"
    ls -1 "$HOME/Library/LaunchAgents/" 2>/dev/null | head -20 || echo "  (无)"
    echo ""
    echo "  --- 系统级 LaunchDaemons (只读查看) ---"
    ls -1 /Library/LaunchDaemons/ 2>/dev/null | head -20 || echo "  (无)"
    echo ""
    echo "  --- 当前用户登录项 ---"
    osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null || echo "  (无法获取,可在 系统设置→通用→登录项 中查看)"
  else
    echo "  --- 开机自启服务 (systemd) ---"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-unit-files --type=service --state=enabled 2>/dev/null | head -25 || echo "  (无法获取)"
    else
      echo "  未检测到 systemd"
    fi
    echo ""
    echo "  --- 用户自启目录 ~/.config/autostart ---"
    ls -1 "$HOME/.config/autostart/" 2>/dev/null || echo "  (无)"
    echo ""
    echo "  --- Shell 配置文件 ---"
    for rcfile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
      [ -f "$rcfile" ] && echo "  $rcfile: $(wc -l < "$rcfile") 行"
    done
  fi
}

run_health_check() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          电脑健康检查报告 $(date '+%Y-%m-%d %H:%M')          ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

  check_cpu
  check_memory
  check_disk
  check_network
  check_startup

  section "检查总结"
  info "以上为只读检查,未对系统做任何修改。"
  info "如需优化,请运行: bash $0 --optimize (预演) 或 bash $0 --optimize --execute (执行)"
}

# =============================================================================
# 安全优化模块 (L1: 只清用户级缓存/日志/临时文件)
# =============================================================================

# 清理单个目录(只删内容,保留目录本身)
clean_dir() {
  local label="$1" path="$2"
  [ -d "$path" ] || { echo "  [跳过] $label: 目录不存在 ($path)"; return; }
  local size_kb
  size_kb=$(dir_size_kb "$path")
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [预演] $label: 可清理 $(kb_to_human "$size_kb") ($path)"
  else
    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
    echo "  [完成] $label: 已清理约 $(kb_to_human "$size_kb")"
  fi
  TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$size_kb")
}

# 清理缓存目录的子目录内容(保留子目录本身,跳过关键项)
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
      echo "  [跳过] 系统关键缓存: $name"
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
    echo "  [预演] $label: 可清理 $(kb_to_human "$total_kb") (已排除系统关键项)"
  else
    echo "  [完成] $label: 已清理约 $(kb_to_human "$total_kb")"
  fi
  TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$total_kb")
}

run_optimize() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     安全优化 $([ $DRY_RUN = 1 ] && echo '(预演模式,未删除任何文件)') $(date '+%Y-%m-%d %H:%M')     ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"

  if [ "$DRY_RUN" = "1" ]; then
    warn "当前为【预演模式】,只统计可清理空间,不实际删除。"
    warn "确认无误后,执行: bash $0 --optimize --execute"
  else
    success "开始执行安全清理(L1级别,仅用户级缓存/日志/临时文件)..."
  fi

  section "缓存清理"

  if [ "$OS_TYPE" = "macos" ]; then
    clean_caches_subdirs "$HOME/Library/Caches" "用户应用缓存"
    clean_dir "Xcode 编译缓存" "$HOME/Library/Developer/Xcode/DerivedData"
    clean_dir "iOS 设备日志" "$HOME/Library/Logs/CrashReporter"
  else
    clean_caches_subdirs "$HOME/.cache" "用户应用缓存 (~/.cache)"
    clean_dir "缩略图缓存" "$HOME/.cache/thumbnails"
    clean_dir "pip 缓存" "$HOME/.cache/pip"
    clean_dir "npm 缓存" "$HOME/.npm/_cacache"
    clean_dir "Yarn 缓存" "$HOME/.cache/yarn"
    clean_dir "Docker 构建缓存" "$HOME/.docker/buildx"
    # /tmp 超过7天的临时文件
    if [ -d /tmp ]; then
      local tmp_old_kb=0
      tmp_old_kb=$(find /tmp -type f -atime +7 -not -path '/tmp/.X*' -not -path '/tmp/.ICE*' 2>/dev/null | xargs du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')
      [ -z "$tmp_old_kb" ] && tmp_old_kb=0
      if [ "$DRY_RUN" = "1" ]; then
        echo "  [预演] /tmp 超过7天的临时文件: 可清理 $(kb_to_human "$tmp_old_kb")"
      else
        find /tmp -type f -atime +7 -not -path '/tmp/.X*' -not -path '/tmp/.ICE*' -delete 2>/dev/null
        echo "  [完成] /tmp 超过7天的临时文件: 已清理约 $(kb_to_human "$tmp_old_kb")"
      fi
      TOTAL_FREED_KB=$(safe_add "$TOTAL_FREED_KB" "$tmp_old_kb")
    fi
  fi

  section "日志清理"
  if [ "$OS_TYPE" = "macos" ]; then
    clean_dir "用户日志" "$HOME/Library/Logs"
  else
    clean_dir "用户最近文档记录" "$HOME/.local/share/RecentDocuments"
    if command -v journalctl >/dev/null 2>&1; then
      local journal_size
      journal_size=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1 || echo "未知")
      echo "  [信息] systemd 日志当前占用: ${journal_size} (建议通过 sudo journalctl --vacuum-time=7d 清理,需管理员权限)"
    fi
  fi

  section "浏览器缓存"
  if [ "$OS_TYPE" = "macos" ]; then
    # Chrome 缓存路径 (macOS 上可能在多个位置)
    clean_dir "Chrome 缓存" "$HOME/Library/Caches/Google/Chrome/Default/Cache"
    clean_dir "Chrome 代码缓存" "$HOME/Library/Caches/Google/Chrome/Default/Code Cache"
    clean_dir "Chrome 缓存(备选路径)" "$HOME/Library/Application Support/Google/Chrome/Default/Cache"
    clean_dir "Safari 缓存" "$HOME/Library/Caches/com.apple.Safari"
    clean_dir "Firefox 缓存" "$HOME/Library/Caches/Firefox"
  else
    clean_dir "Chrome 缓存" "$HOME/.cache/google-chrome/Default/Cache"
    clean_dir "Chrome 代码缓存" "$HOME/.cache/google-chrome/Default/Code Cache"
    clean_dir "Firefox 缓存" "$HOME/.cache/mozilla/firefox"
  fi

  section "包管理器缓存"
  if [ "$OS_TYPE" = "linux" ]; then
    if command -v apt >/dev/null 2>&1; then
      local apt_cache
      apt_cache=$(dir_size_kb "/var/cache/apt/archives")
      echo "  [信息] apt 下载缓存: $(kb_to_human "$apt_cache") (清理需 sudo apt clean)"
    fi
    command -v dnf >/dev/null 2>&1 && echo "  [信息] dnf 缓存可通过 sudo dnf clean all 清理"
    command -v pacman >/dev/null 2>&1 && echo "  [信息] pacman 缓存可通过 sudo pacman -Sc 清理"
  elif [ "$OS_TYPE" = "macos" ]; then
    if command -v brew >/dev/null 2>&1; then
      local brew_cache
      brew_cache=$(dir_size_kb "$HOME/Library/Caches/Homebrew")
      echo "  [信息] Homebrew 缓存: $(kb_to_human "$brew_cache") (清理可执行 brew cleanup)"
    fi
  fi

  section "废纸篓/回收站 (默认不清理)"
  if [ "$OS_TYPE" = "macos" ]; then
    local trash_kb
    trash_kb=$(dir_size_kb "$HOME/.Trash")
    echo "  [跳过] 废纸篓: $(kb_to_human "$trash_kb") — 清空不可恢复,请自行在 Finder 中清空"
  else
    local trash_kb
    trash_kb=$(dir_size_kb "$HOME/.local/share/Trash")
    echo "  [跳过] 回收站: $(kb_to_human "$trash_kb") — 清空不可恢复,请自行在文件管理器中清空"
  fi

  section "优化总结"
  if [ "$DRY_RUN" = "1" ]; then
    success "预演完成,合计约 $(kb_to_human "$TOTAL_FREED_KB") 可安全清理。"
    echo ""
    info "确认清理请执行: bash $0 --optimize --execute"
  else
    success "清理完成,合计释放约 $(kb_to_human "$TOTAL_FREED_KB")。"
  fi
  echo ""
  info "未触碰: 系统目录、个人文件(桌面/文档/下载/图片/视频)、浏览器书签/密码、钥匙串、废纸篓"
  info "建议: 定期清理浏览器缓存、保持磁盘剩余空间 >10%、关闭不需要的开机自启项"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
  detect_os
  echo ""
  info "脚本版本: 1.1 | 系统: $OS_TYPE | 用户: $USER"
  info "安全级别: L0 检查 + L1 清理 | 不使用 sudo | 不碰个人文件"

  if [ "$MODE_CHECK" = "1" ]; then
    run_health_check
  fi

  if [ "$MODE_OPTIMIZE" = "1" ]; then
    run_optimize
  fi

  echo ""
  success "全部操作完成。"
}

main
