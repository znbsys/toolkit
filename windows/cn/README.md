# Windows 磁盘管理与系统维护脚本集（PowerShell）

Windows 版磁盘分析与系统维护脚本，与 [../../mac/cn/](../../mac/cn/) 功能对应。删除操作均需确认或默认预演，不碰个人文件。

> 运行前如遇执行策略限制，先执行：
> `Set-ExecutionPolicy -Scope Process Bypass`

## 脚本一览

| 脚本 | 功能 | 操作级别 |
|------|------|----------|
| `disk-overview.ps1` | 磁盘占用快速概览（卷使用率 + 家目录 Top 10） | 只读 |
| `disk-full-report.ps1` | 完整磁盘扫描，生成 Markdown 报告 | 只读 |
| `disk-timeline.ps1` | 按修改时间定位最近磁盘增长原因 | 只读 |
| `smart-clean.ps1` | 交互式清理（安全 / 需判断分类） | 确认后删除 |
| `sys-health-check.ps1` | 系统健康检查 + L1 安全清理 | 默认预演 |

---

## disk-overview.ps1

快速查看当前磁盘占用情况。

```powershell
.\disk-overview.ps1           # 卷使用率 + 家目录 Top 10
.\disk-overview.ps1 -Top      # 加扫系统顶层目录（Program Files、AppData、Temp 等）
.\disk-overview.ps1 -Deep     # 加看 Temp/npm/Docker/浏览器等大目录明细
```

- 各卷使用率进度条（绿 / 黄 / 红着色，≥70% 黄、≥90% 红）
- `-Deep` 覆盖 `Temp`、`npm-cache`、`pip\Cache`、`Docker`、Chrome/Edge 用户数据、`JetBrains`、`.ollama`、`.docker`、`Downloads`、`.cache`、UWP `Packages` 等
- 只读，不做任何删除

---

## disk-full-report.ps1

生成完整磁盘扫描报告（Markdown 文件）。

```powershell
.\disk-full-report.ps1                              # 输出到脚本所在目录 disk-report-YYYY-MM-DD.md
.\disk-full-report.ps1 -OutputPath C:\reports\d.md  # 指定输出路径
```

报告包含 6 个部分：

1. **总体概览** — 各固定卷总量 / 已用 / 可用 / 使用率
2. **用户目录一级子目录占用 Top 15**
3. **开发与缓存目录** — Temp、npm、pip、Docker、Chrome/Edge 用户数据、JetBrains、Ollama、`.docker`、`.cache`、Downloads、UWP `Packages`、WindowsApps
4. **大型文件（>200MB，Top 20）** — 下载 / 桌面 / 文档 / 视频目录
5. **浏览器缓存** — Chrome / Edge 的 Cache 与 Code Cache
6. **清理建议** — 临时文件、npm/pip 缓存、Docker、Ollama、浏览器缓存、回收站等对应命令

- 只读，仅生成报告文件，不删除任何内容

---

## disk-timeline.ps1

按文件修改时间（LastWriteTime）分析磁盘占用，定位"最近磁盘是因为什么被占用的"。

```powershell
.\disk-timeline.ps1                 # 默认：最近 3 天，>=50MB 的大文件
.\disk-timeline.ps1 -Days 7         # 扩大到最近 7 天
.\disk-timeline.ps1 -MinSize 10MB   # 降低文件大小阈值（K/M/G 均可）
.\disk-timeline.ps1 -Dirs           # 按目录聚合（看哪个目录最近写入多）
.\disk-timeline.ps1 -All            # 文件 + 目录一起看
```

- 精选搜索根目录（AppData Local/Roaming、Downloads、Documents、Desktop、`.ollama`、`.docker`、`.cache`、Program Files），避免全盘扫描卡死
- 先显示常见增长源快速体检（Temp、npm/pip、Docker、Chrome/Edge、JetBrains、Ollama、Downloads、UWP 包、Windows Temp 等）
- 文件按"最近 24 小时"和"最近 2 ~ N 天"分组展示，目录聚合给出累计大小与文件数
- 结尾附解读建议（不同增长源对应的处理方式）
- 只读，不做任何删除

---

## smart-clean.ps1

交互式清理，扫描结果分为两类：

- **[安全]**：可再生缓存 / 临时文件 / 转储，删除无风险
- **[需判断]**：可能包含用户数据或正在使用，需用户确认

```powershell
.\smart-clean.ps1 -List   # 仅扫描并列出，不删除
.\smart-clean.ps1         # 交互确认模式（推荐，默认）
.\smart-clean.ps1 -Yes    # 直接删除所有 [安全] 项，[需判断] 项仍逐项询问
```

仅列出占用 ≥10MB 的项。

| 类别 | 覆盖项 |
|------|--------|
| [安全] | 用户 `Temp`、`C:\Windows\Temp` |
| [安全] | npm / pip / Yarn / pnpm / NuGet 缓存、IE 系统缓存 |
| [安全] | 崩溃转储（CrashDumps）、蓝屏 Minidump |
| [安全] | Chrome / Edge 的 Cache、Code Cache、Service Worker 缓存 |
| [安全] | JetBrains、Gradle、Maven、NuGet 包、Cargo、Rustup、缩略图缓存 |
| [安全] | 回收站（Shell API 统计大小，执行时 `Clear-RecycleBin`，交互确认） |
| [需判断] | 项目 `node_modules`（>500MB，扫描 `source`/`Projects`/`dev`/`Documents`） |
| [需判断] | Downloads / Desktop / Documents 中 ≥200MB 的大文件 |
| [需判断] | Ollama 模型、HuggingFace 模型缓存 |

- 删除后自动校验，未删净（被占用）会提示残留

---

## sys-health-check.ps1

系统健康检查 + L1 级安全清理。

```powershell
.\sys-health-check.ps1                     # 健康检查 + 优化预演（默认）
.\sys-health-check.ps1 -Check              # 仅健康检查
.\sys-health-check.ps1 -Optimize           # 仅优化预演（统计不删除）
.\sys-health-check.ps1 -Optimize -Execute  # 实际清理
```

**健康检查项（L0 只读）**：CPU / 内存 / 磁盘 / 网络（接口 + 连通性 + DNS）/ 启动项

启动项覆盖：启动文件夹（用户 + 公共）、注册表 Run 键（当前用户）、非微软计划任务

**L1 清理范围**：

- 缓存：用户 `Temp`、npm / pip / Yarn / NuGet / Gradle / Cargo、Chrome / Edge、JetBrains
- 日志：`C:\Windows\Temp`、崩溃转储、WER 报告队列
- 回收站：默认跳过，仅统计大小并提示手动清空

**安全承诺**：

- 不碰系统目录（`C:\Windows`、`C:\Program Files` 等不删）
- 不碰个人文件（桌面 / 文档 / 下载 / 视频）
- 不清空回收站（不可逆，仅统计并提示）
- 只删可再生的用户级缓存、日志、临时文件
- 默认预演模式，实际删除需 `-Optimize -Execute`

---

## 与 ForMac 对照

| ForMac | ForWindows | 说明 |
|--------|-----------|------|
| `disk-overview.sh` | `disk-overview.ps1` | 磁盘概览 |
| `disk-full-report.sh` | `disk-full-report.ps1` | 完整报告 |
| `disk-timeline.sh` | `disk-timeline.ps1` | 时间线分析 |
| `smart-clean.sh` | `smart-clean.ps1` | 交互清理 |
| `sys-health-check.sh` | `sys-health-check.ps1` | 健康检查 |

## 使用建议

| 场景 | 推荐脚本 |
|------|----------|
| 快速看磁盘还剩多少 | `disk-overview.ps1` |
| 月底做一次全面体检 | `disk-full-report.ps1` |
| 磁盘突然变满，找原因 | `disk-timeline.ps1` |
| 日常清理缓存 | `smart-clean.ps1` |
| 系统变慢，全面检查 | `sys-health-check.ps1` |
