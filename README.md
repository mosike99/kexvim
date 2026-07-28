# Kexvim — AI 个人助理

## 快速开始

**要求:** Node.js 22+

### Windows
下载 [kexvim.bat](https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat)，双击运行。自动完成安装和启动。

或 PowerShell 一行命令：
```powershell
irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat -OutFile %USERPROFILE%\Desktop\Kexvim.bat; start %USERPROFILE%\Desktop\Kexvim.bat
```

### Linux / macOS
```bash
curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.sh -o kexvim.sh && chmod +x kexvim.sh
./kexvim.sh
```

首次双击会自动：下载 kexvim.js → 提示输入 API Key → 启动。之后双击直接启动。

## 命令行用法

安装后可在终端直接输入 `kexvim`（`init` 已自动配置 PATH）：

```bash
kexvim              # 启动
kexvim update       # 更新
kexvim restart      # 重启
kexvim --help       # 帮助
```

或通过入口脚本：
```bash
bash kexvim.sh restart      # Linux
kexvim.bat restart          # Windows
.\kexvim.ps1 restart        # Windows PowerShell
```
