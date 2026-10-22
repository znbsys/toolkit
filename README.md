# toolkit

macOS / Windows 磁盘管理与系统维护脚本集，提供磁盘占用分析、系统健康检查与安全清理能力。所有删除操作均需确认或默认预演，不使用 sudo/admin，绝不触碰个人文件。

## 目录结构

```
toolkit/
├── mac/
│   ├── cn/        # macOS 脚本（中文文档）
│   └── en/        # macOS 脚本（英文文档）
├── windows/
│   ├── cn/        # Windows PowerShell 脚本（中文文档）
│   └── en/        # Windows PowerShell 脚本（英文文档）
├── README.md
└── LICENSE
```

## 脚本一览

| 脚本 | 平台 | 功能 | 操作级别 |
|------|------|------|----------|
| `disk-overview` | macOS / Windows | 磁盘占用快速概览（卷使用率 + 家目录 Top） | 只读 |
| `disk-full-report` | macOS / Windows | 完整磁盘扫描，生成 Markdown 报告 | 只读 |
| `disk-timeline` | macOS / Windows | 按修改时间定位最近磁盘增长原因 | 只读 |
| `smart-clean` | macOS / Windows | 交互式清理（安全 / 需判断分类） | 确认后删除 |
| `sys-health-check` | macOS / Linux / Windows | 系统健康检查 + L1 安全清理 | 默认预演 |

## 快速开始

**macOS（Bash）**

```bash
bash mac/cn/disk-overview.sh        # 中文脚本
bash mac/en/disk-overview.sh        # 英文脚本
```

**Windows（PowerShell）**

```powershell
Set-ExecutionPolicy -Scope Process Bypass   # 如遇执行策略限制先执行
.\windows\cn\disk-overview.ps1
.\windows\en\disk-overview.ps1
```

## 使用建议

| 场景 | 推荐脚本 |
|------|----------|
| 快速看磁盘还剩多少 | `disk-overview` |
| 月底做一次全面体检 | `disk-full-report` |
| 磁盘突然变满，找原因 | `disk-timeline` |
| 日常清理缓存 | `smart-clean` |
| 系统变慢，全面检查 | `sys-health-check` |

## 详细文档

- macOS 中文：[mac/cn/README.md](mac/cn/README.md)
- macOS 英文：[mac/en/README.md](mac/en/README.md)
- Windows 中文：[windows/cn/README.md](windows/cn/README.md)
- Windows 英文：[windows/en/README.md](windows/en/README.md)
