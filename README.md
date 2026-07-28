# Kexvim — AI 个人助理

## 一键安装

**要求:** Node.js 22+

### Windows

```powershell
# 1. 下载
mkdir $env:USERPROFILE\.kexvim -Force
irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js > $env:USERPROFILE\.kexvim\kexvim.js

# 2. 初始化（配置 API Key）
cd $env:USERPROFILE\.kexvim
node kexvim.js init

# 3. 启动
node kexvim.js restart
```

### Linux / macOS

```bash
# 1. 下载到本地
mkdir -p ~/.kexvim
curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js -o ~/.kexvim/kexvim.js

# 2. 初始化
cd ~/.kexvim
node kexvim.js init

# 3. 启动
node kexvim.js restart
```

## 日常使用

```bash
node kexvim.js              # 正常运行（QQ Bot / TUI）
node kexvim.js update       # 拉取更新并重启
node kexvim.js restart      # 重启
node kexvim.js --help       # 查看帮助
```

也可用入口脚本（自动定位到安装目录）：

**Linux:** `bash kexvim.sh restart`
**Windows:** `kexvim.bat restart` 或 `.\kexvim.ps1 restart`
