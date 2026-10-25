# 一个 Windows 的脚本操作实例

使用 PowerShell 模拟按键的方法。它通过每隔一段时间模拟按下一次不影响操作的按键（如 `Scroll Lock`），让系统始终处于“人工操作”状态。

#### 1. 准备脚本代码

首先，复制以下经过优化的脚本代码：

```powershell
# 每隔 60 秒模拟按下一次 ScrollLock 键，保持系统活跃
$shell = New-Object -ComObject WScript.Shell
Write-Host "脚本已启动，正在保持桌面活跃..." -ForegroundColor Green
Write-Host "按 Ctrl+C 或关闭窗口即可停止。" -ForegroundColor Yellow

while($true) {
    # 模拟按下 ScrollLock 键（通常不会干扰你的打字或操作）
    $shell.SendKeys('{SCROLLLOCK}')
    # 等待 60 秒
    Start-Sleep -Seconds 60
}
```

#### 2. 详细实现步骤（手顺）

* **步骤 A：创建脚本文件**
1. 在桌面点击右键，选择 **新建** -> **文本文档**。
2. 将文件命名为 `StayActive.ps1`（**注意：** 后缀名必须从 `.txt` 改为 `.ps1`）。
3. 如果看不到后缀名，请在文件夹顶部的“查看”选项中勾选“文件扩展名”。


* **步骤 B：编辑并保存**
1. 右键点击 `StayActive.ps1`，选择 **编辑**（通常会用记事本或 PowerShell ISE 打开）。
2. 将上述代码粘贴进去，点击 **保存** 并关闭。


* **步骤 C：执行脚本**
1. **右键点击** 该文件，选择 **使用 PowerShell 运行**。
2. 此时会弹出一个蓝色或黑色的命令行窗口，显示“脚本已启动”。
3. **注意：** 只要这个窗口开着，你的电脑就不会进入休眠或自动锁屏。



#### 3. 如何停止

* **方法一：** 直接点击 PowerShell 窗口右上角的 **“X”** 关闭图标。
* **方法二：** 在该窗口内按下键盘组合键 `Ctrl + C`。

---

### 进阶提示：解决“禁止执行脚本”报错

如果你运行脚本时提示“在此系统上禁止运行脚本”，请执行以下一次性设置：

1. 以管理员身份运行 PowerShell。
2. 输入 `Set-ExecutionPolicy RemoteSigned` 并按回车。
3. 输入 `Y` 确认。
