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

三步完成。`init` 会在 `~/.kexvim` 创建数据目录并配置 API Key，`restart` 以后台进程运行。

> **自定义安装路径:** 下载到目标目录后执行上述命令即可，`init` 会自动识别。

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
