# Kexvim — AI 个人助理

## 快速开始

**要求:** Node.js 22+

### Windows
下载 [kexvim.bat](https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat)，双击运行。

或一行命令：
```powershell
irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat -OutFile %USERPROFILE%\Desktop\Kexvim.bat; start %USERPROFILE%\Desktop\Kexvim.bat
```

### Linux / macOS
```bash
curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.sh -o kexvim.sh && chmod +x kexvim.sh
./kexvim.sh
```

首次运行自动下载 `kexvim.js` → 提示输入 API Key → 显示常用命令。

## 命令行

```bash
./kexvim.sh restart        # Linux / macOS
kexvim.bat restart          # Windows
```

安装后终端直接输入 `kexvim` 也可操作（`init` 已自动配置 PATH）。
