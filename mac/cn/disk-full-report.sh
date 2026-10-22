#!/bin/bash
# disk-full-report.sh - Mac 磁盘空间扫描报告生成脚本
# Usage: bash scripts/disk-full-report.sh [output-path]
# Default output: ./disk-report-$(date +%F).md
#
# 策略：用少量批量 du 调用收集数据，避免逐目录 du。
# 所有 du 命令在后台并行执行，然后汇总。

set -u

OUTPUT="${1:-$(dirname "$0")/../disk-report-$(date +%F).md}"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Helpers ─────────────────────────────────────────────────────────
section() { printf "\n## %s\n\n" "$1" >> "$OUTPUT"; }
w() { echo "$@" >> "$OUTPUT"; }

# Run du in background, wait, and capture output.
# $1 = variable name to store result
# $2 = path to measure
bgdu() {
  local var=$1 path=$2
  du -sh "$path" 2>/dev/null > "$TMPDIR/$var" &
  echo $! >> "$TMPDIR/pids"
}

# Check all bg jobs are done
wait_du() {
  [ ! -f "$TMPDIR/pids" ] && return
  while IFS= read -r pid; do
    wait "$pid" 2>/dev/null || true
  done < "$TMPDIR/pids"
}

# Get size from previously stored result
getsize() {
  local var=$1
  [ -f "$TMPDIR/$var" ] && awk '{print $1}' "$TMPDIR/$var" || echo "?"
}

start_spinner() {
  printf "  ⏳ 扫描中..."
}
stop_spinner() {
  printf "\r  ✅ 扫描完成\n"
}

# ── Start report ───────────────────────────────────────────────────
cat > "$OUTPUT" <<- HEADER
	# Mac 磁盘空间扫描报告

	> 生成时间：$(date '+%Y-%m-%d %H:%M:%S')
	> 扫描脚本：\`scripts/disk-full-report.sh\`

HEADER

start_spinner

# ── PHASE 1: 批量 du 扫描（所有大目录并行） ────────────────────────
# Library 关键子目录
bgdu lib_AdSupport   "$HOME/Library/Application Support"
bgdu lib_AdGoogle    "$HOME/Library/Application Support/Google"
bgdu lib_AdJetBrains "$HOME/Library/Application Support/JetBrains"
bgdu lib_AdClaude    "$HOME/Library/Application Support/Claude"
bgdu lib_AdCode      "$HOME/Library/Application Support/Code"
bgdu lib_Caches      "$HOME/Library/Caches"
bgdu lib_Developer   "$HOME/Library/Developer"
bgdu lib_Logs        "$HOME/Library/Logs"
bgdu lib_DockerData  "$HOME/Library/Containers/com.docker.docker/Data"

# 隐藏目录
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

# 开发环境
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

# Library 总量（也放后台，显示进度用）
bgdu lib_total       "$HOME/Library"

# 大文件
bgdu hprof          "$HOME/java_error_in_idea.hprof"

# 并行等待所有 du 完成
wait_du
stop_spinner

# ── 1. 总体概览 ────────────────────────────────────────────────────
section "1. 总体概览"
{
  df -h /
  echo ""
  df -h /System/Volumes/Data 2>/dev/null
} >> "$OUTPUT" 2>/dev/null
echo "" >> "$OUTPUT"

DATA_USED=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $3}')
DATA_TOTAL=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $2}')
DATA_AVAIL=$(df /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')
w "**数据卷 (\`/System/Volumes/Data\`): 已用 $DATA_USED / 总量 $DATA_TOTAL, 可用 $DATA_AVAIL**"

# ── 2. Library ─────────────────────────────────────────────────────
section "2. 用户 Library 目录"

LIB_TOTAL=$(getsize lib_total)
w "**\`~/Library\` 总大小：$LIB_TOTAL**"
w ""
w "| 子目录 | 大小 |"
w "|--------|------|"

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
w "**Library 子目录排序（Top 15）：**"
w ""
{ du -sh "$HOME"/Library/*/ 2>/dev/null | sort -rh | head -15; } >> "$OUTPUT"

# ── 3. 隐藏开发/AI目录 ─────────────────────────────────────────────
section "3. 隐藏开发 / AI 目录"

w "| 目录 | 大小 | 说明 |"
w "|------|------|------|"

while IFS='|' read -r key dir desc; do
  # Trim whitespace
  key="${key// /}"
  dir="${dir// /}"
  sz=$(getsize "$key")
  [ -n "$sz" ] && [ "$sz" != "?" ] && w "| \`~/$dir\` | $sz | $desc |"
done <<- DIRS
	dot_cache     |.cache                 |通用缓存
	dot_uv        |.cache/uv              |uv (Python) 缓存
	dot_ollama    |.ollama/models         |Ollama AI 模型
	dot_npm       |.npm                   |npm 缓存
	dot_lingma    |.lingma                |Lingma AI 辅助
	dot_podman    |.local/share/containers|Podman 容器数据
	dot_android   |.android               |Android SDK/AVD
	dot_vscode    |.vscode                |VS Code 数据
	dot_cursor    |.cursor                |Cursor IDE 数据
	dot_cargo     |.cargo                 |Cargo Rust 缓存
	dot_gradle    |.gradle                |Gradle 缓存
	dot_pubcache  |.pub-cache             |Flutter/Dart 包缓存
	dot_go        |.go                    |Go 模块缓存
	dot_docker    |.docker                |Docker CLI 配置
DIRS

w ""
w "**所有 \`~/.xx\` 目录排序（Top 15）：**"
w ""
{ du -sh "$HOME"/.[!.]* 2>/dev/null | sort -rh | head -15; } >> "$OUTPUT"

# ── 4. 开发环境与应用 ──────────────────────────────────────────────
section "4. 开发环境与应用"

w "| 目录 | 大小 |"
w "|------|------|"

run_row apps       "/Applications"
run_row lib_dev    "/Library/Developer"
run_row coresim    "/Library/Developer/CoreSimulator"
run_row xc_derived "~/Library/Developer/Xcode/DerivedData"
run_row xc_archives "~/Library/Developer/Xcode/Archives"
run_row xc_iosdevsp "~/Library/Developer/Xcode/iOS DeviceSupport"
run_row workspace  "~/workspace"
run_row projects   "~/projects"

w ""
w "**Applications 占用 Top 10：**"
w ""
{ [ -f "$TMPDIR/apps_sub" ] && sort -rh "$TMPDIR/apps_sub" | head -10; } >> "$OUTPUT"

# ── 5. 大文件 ──────────────────────────────────────────────────────
section "5. 大型文件"

w "**快速扫描已知大目录（> 200MB，Top 20）：**"
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
  w "上述目录中未找到大于 200MB 的文件。"
fi
rm -f "$BIGFILE_TMP"

# ── 6. Docker / Podman ─────────────────────────────────────────────
section "6. Docker / Podman"

if command -v docker &>/dev/null; then
  echo '```' >> "$OUTPUT"
  docker system df 2>/dev/null >> "$OUTPUT" || w "Docker daemon not running"
  echo '```' >> "$OUTPUT"
fi
w ""

if command -v podman &>/dev/null; then
  w "**Podman 占用：**"
  w ""
  { du -sh "$HOME/.local/share/containers" 2>/dev/null; } >> "$OUTPUT"
fi
w ""

DOCKER_DATA_SIZE=$(getsize lib_DockerData)
w "**Docker 数据目录：$DOCKER_DATA_SIZE**"
w ""
RAW_FILE="$HOME/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
if [ -f "$RAW_FILE" ]; then
  du -h "$RAW_FILE" >> "$OUTPUT"
fi

# ── 7. Ollama ──────────────────────────────────────────────────────
if command -v ollama &>/dev/null; then
  section "7. Ollama 模型"
  echo '```' >> "$OUTPUT"
  ollama list 2>/dev/null >> "$OUTPUT" || w "Ollama not running"
  echo '```' >> "$OUTPUT"
  w ""
  OLLAMA_SIZE=$(getsize dot_ollama)
  w "**模型文件总占用：$OLLAMA_SIZE**"
fi

# ── 8. 缓存详情 ────────────────────────────────────────────────────
section "8. 缓存详细分析"

w "**uv 缓存：**"
w ""
getsize dot_uv >> "$OUTPUT"
w ""
w "**npm 缓存：**"
w ""
getsize dot_npm >> "$OUTPUT"
w ""
w "**~/.cache 子目录详情：**"
w ""
{ du -sh "$HOME/.cache"/*/ 2>/dev/null | sort -rh | head -20; } >> "$OUTPUT"

# ── 9. 回收估算 ────────────────────────────────────────────────────
section "9. 清理建议"

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

w "| 项目 | 建议操作 | 可回收 |"
w "|------|---------|--------|"

[ "$DOCKER_KB" -gt 0 ] 2>/dev/null && w "| Docker 数据 | \`docker system prune -a --volumes -f\` | $(fmt_kb "$DOCKER_KB") |"
[ "$UV_KB" -gt 0 ] 2>/dev/null && w "| uv 缓存 | \`uv cache clean\` | $(fmt_kb "$UV_KB") |"
[ "$OLLAMA_KB" -gt 0 ] 2>/dev/null && w "| Ollama 模型 | \`ollama rm <model>\`（按需删） | $(fmt_kb "$OLLAMA_KB") |"
[ "$NPM_KB" -gt 0 ] 2>/dev/null && w "| npm 缓存 | \`npm cache clean --force\` | $(fmt_kb "$NPM_KB") |"
[ "$CORESIM_KB" -gt 0 ] 2>/dev/null && w "| Xcode 模拟器 | \`xcrun simctl delete unavailable\` | $(fmt_kb "$CORESIM_KB") |"
[ "$HPROF_KB" -gt 0 ] 2>/dev/null && w "| IntelliJ 堆转储 | \`rm ~/java_error_in_idea.hprof\` | $(fmt_kb "$HPROF_KB") |"
w "| 其他缓存 | 逐项检查（JetBrains / Google / ~/Library/Caches 等） | — |"

TOTAL=$(( (DOCKER_KB + UV_KB + OLLAMA_KB + NPM_KB + CORESIM_KB + HPROF_KB) ))
w ""
w "> **估算总计可回收：$(fmt_kb $TOTAL)+**"
w ""
w "> ⚠️ 清理前请确认数据是否仍需使用，尤其是 Ollama 模型和 Docker 数据。"

# ── 10. 清理命令 ────────────────────────────────────────────────────
section "10. 清理命令参考"
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

	# ===== Xcode 模拟器 =====
	# xcrun simctl delete unavailable

	# ===== 大文件 =====
	# rm ~/java_error_in_idea.hprof

	# ===== 通用缓存 =====
	# rm -rf ~/Library/Caches/*
	# rm -rf ~/.cache/uv/*
	```

CMDS

w ""
w "---"
w ""
w "*报告由 \`disk-full-report.sh\` 自动生成 | 清理前请确认数据重要性*"

echo ""
echo "✅ 报告已生成：$OUTPUT"
echo "总行数：$(wc -l < "$OUTPUT")"
echo ""
echo "查看：less \"$OUTPUT\""
echo "预览：open \"$OUTPUT\""
