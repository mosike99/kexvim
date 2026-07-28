# Kexvim — AI 个人助理

## 快速开始

**要求:** Node.js 22+

### Windows
```powershell
irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js > kexvim.js
node kexvim.js init
node kexvim.js restart
```

### Linux / macOS
```bash
curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js -o kexvim.js
node kexvim.js init
node kexvim.js restart
```

三步完成。下载到**任意位置**（桌面/下载/临时文件夹均可），`init` 自动安装到 `~/.kexvim` 并配置 API Key，`restart` 以后台进程运行。下载的引导文件用完可删。

> **自定义安装路径:** 设置环境变量 `KEXVIM_HOME`（如 `set KEXVIM_HOME=D:\my-kexvim`）再运行 `init`。

## 日常使用

```bash
node kexvim.js              # 正常运行（QQ Bot / TUI）
node kexvim.js update       # 拉取更新并重启
node kexvim.js restart      # 重启
node kexvim.js --help       # 查看帮助
```

也可用入口脚本（自动定位到安装目录）：
- **Linux:** `bash kexvim.sh restart`
- **Windows:** `kexvim.bat restart` 或 `.\kexvim.ps1 restart`
