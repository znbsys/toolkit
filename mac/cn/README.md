# macOS 磁盘管理与系统维护脚本集

macOS 版磁盘分析与系统维护脚本（Bash），全部只读或需确认后才删除，不使用 sudo，不碰个人文件。

## 脚本一览

| 脚本 | 功能 | 操作级别 |
|------|------|----------|
| `disk-overview.sh` | 磁盘占用快速概览（卷使用率 + 家目录 Top 10） | 只读 |
| `disk-full-report.sh` | 完整磁盘扫描，生成 Markdown 报告 | 只读 |
| `disk-timeline.sh` | 按修改时间定位最近磁盘增长原因 | 只读 |
| `smart-clean.sh` | 交互式清理（安全 / 需判断分类） | 确认后删除 |
| `sys-health-check.sh` | 系统健康检查 + L1 安全清理（兼容 Linux） | 默认预演 |

---

## disk-overview.sh

快速查看当前磁盘占用情况。

```bash
bash disk-overview.sh           # 卷使用率 + 家目录 Top 10
bash disk-overview.sh --top     # 加扫系统顶层目录（/Applications、/Library 等）
bash disk-overview.sh --deep    # 加看 Caches/Developer/workspace 等大目录明细
bash disk-overview.sh -h        # 显示帮助
```

- 卷使用率进度条（绿 / 黄 / 红着色，≥70% 黄、≥90% 红）
- `--deep` 覆盖 `~/Library/Caches`、`~/Library/Developer`、`~/.npm`、`~/.cache`、`~/.ollama/models`、`~/workspace`、`/Applications` 等
- 只读，不做任何删除

---

## disk-full-report.sh

生成完整磁盘扫描报告（Markdown 文件），大目录 du 并行扫描以缩短耗时。

```bash
bash disk-full-report.sh                    # 输出到脚本上级目录 disk-report-YYYY-MM-DD.md
bash disk-full-report.sh /path/to/out.md    # 指定输出路径
```

报告包含 10 个部分：

1. **总体概览** — `/` 与 `/System/Volumes/Data` 卷使用情况
2. **用户 Library 目录** — Application Support、Caches、Developer、Logs、Docker 数据等 + Top 15 排序
3. **隐藏开发 / AI 目录** — `.cache`、`.ollama/models`、`.npm`、`.lingma`、Podman、`.android`、`.vscode`、`.cursor`、`.cargo`、`.gradle`、`.go` 等
4. **开发环境与应用** — `/Applications` Top 10、Xcode DerivedData/Archives/iOS DeviceSupport、`~/workspace`、`~/projects`
5. **大型文件** — 下载/桌面/文档/影片/音乐/图片中 >200MB 的文件 Top 20
6. **Docker / Podman** — `docker system df` 输出 + 数据目录大小
7. **Ollama 模型** — `ollama list` + 模型总占用（若已安装）
8. **缓存详细分析** — uv、npm、`~/.cache` 子目录明细
9. **清理建议** — 按项目列出可回收空间估算（Docker / uv / Ollama / npm / Xcode 模拟器 / 堆转储）
10. **清理命令参考** — 可直接复制的清理命令

- 只读，仅生成报告文件，不删除任何内容

---

## disk-timeline.sh

按文件修改时间分析磁盘占用，定位"最近磁盘是因为什么被占用的"。

```bash
bash disk-timeline.sh              # 默认：最近 3 天，>=50M 的大文件
bash disk-timeline.sh --days 7     # 扩大到最近 7 天
bash disk-timeline.sh --min 10M    # 降低文件大小阈值（支持 K/M/G）
bash disk-timeline.sh --dirs       # 按目录聚合（看哪个目录最近写入多）
bash disk-timeline.sh --all        # 文件 + 目录一起看
bash disk-timeline.sh -h           # 显示帮助
```

- 使用 macOS Spotlight（`mdfind`）索引，查询秒级完成；无 Spotlight 时自动退回 `find`（仅扫精选目录，较慢）
- 先显示常见增长源快速体检（Docker / Ollama / 缓存 / 日志 / Downloads / Xcode 等）
- 文件按"最近 24 小时"和"最近 2 ~ N 天"分组展示，目录聚合给出累计大小与文件数
- 结尾附解读建议（不同增长源对应的处理方式）
- 只读，不做任何删除

---

## smart-clean.sh

交互式清理，扫描结果分为两类：

- **[安全]**：可再生缓存 / 临时文件 / 转储，删除无风险
- **[需判断]**：可能包含用户数据或正在使用，需用户确认

```bash
bash smart-clean.sh --list    # 仅扫描并列出，不删除
bash smart-clean.sh --clean   # 交互确认模式（推荐，默认）
bash smart-clean.sh --yes     # 直接删除所有 [安全] 项，[需判断] 项仍逐项询问
```

仅列出占用 ≥10MB 的项，≥200MB 显示醒目提示。

| 类别 | 覆盖项 |
|------|--------|
| [安全] | `~/Library/Caches`、`~/Library/Logs` |
| [安全] | npm / node-gyp / pip / Homebrew 缓存 |
| [安全] | Xcode DerivedData、模拟器缓存 |
| [安全] | JVM/IDE 崩溃转储（`*.hprof`）、`/cores`（若可写） |
| [安全] | 废纸篓（交互模式询问；`--yes` 下自动清空，通过 Finder AppleScript 执行） |
| [需判断] | Codex 运行时、HuggingFace 模型缓存 |
| [需判断] | 全局 npm 包（单包 >200MB） |
| [需判断] | 项目 `node_modules`（>500MB） |
| [需判断] | Downloads 大文件（>200MB）、家目录大文件（>1GB，排除 Library 等） |

- 删除后自动校验，未删净会提示残留（可能被占用）

---

## sys-health-check.sh

系统健康检查 + L1 级安全清理，兼容 macOS 与 Linux（systemd）。

```bash
bash sys-health-check.sh                  # 健康检查 + 优化预演（默认）
bash sys-health-check.sh --check          # 仅健康检查
bash sys-health-check.sh --optimize       # 仅优化预演（统计不删除）
bash sys-health-check.sh --optimize --execute  # 实际清理
bash sys-health-check.sh --help           # 显示帮助
```

**健康检查项（L0 只读）**：CPU / 内存 / 磁盘 / 网络（连通性 + DNS）/ 启动项

- macOS：LaunchAgents、LaunchDaemons、登录项
- Linux：systemd 启用单元、`~/.config/autostart`、shell rc 文件

**L1 清理范围**：

- macOS：`~/Library/Caches` 子目录（自动排除 CloudKit 等系统关键缓存）、Xcode DerivedData、CrashReporter、`~/Library/Logs`、Chrome/Safari/Firefox 缓存
- Linux：`~/.cache` 子目录、缩略图 / pip / npm / Yarn / Docker buildx 缓存、`/tmp` 超过 7 天的临时文件、用户日志

**安全承诺**：

- 不使用 sudo，不碰系统目录（/System、/Library、/usr 等）
- 不碰个人文件（桌面 / 文档 / 下载 / 图片 / 视频）
- 不清空废纸篓 / 回收站（不可逆，仅统计并提示用户自行处理）
- 只删可再生的用户级缓存、日志、临时文件
- 默认预演模式，实际删除需 `--optimize --execute`

---

## 使用建议

| 场景 | 推荐脚本 |
|------|----------|
| 快速看磁盘还剩多少 | `disk-overview.sh` |
| 月底做一次全面体检 | `disk-full-report.sh` |
| 磁盘突然变满，找原因 | `disk-timeline.sh` |
| 日常清理缓存 | `smart-clean.sh` |
| 系统变慢，全面检查 | `sys-health-check.sh` |

## Windows 版本

对应 PowerShell 脚本见 [../../windows/cn/](../../windows/cn/)。
