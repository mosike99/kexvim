# Kexvim Windows 一键安装脚本
# 用法: irm https://gitee.com/moscowzk/kexvim-dev/raw/main/install.ps1 | iex

$ErrorActionPreference = "Stop"
$KexvimDir = "$env:USERPROFILE\.kexvim"
$RepoUrl = "https://gitee.com/moscowzk/kexvim"

# 颜色输出
function Write-Colored($Color, $Text) {
    Write-Host $Text -ForegroundColor $Color
}

Write-Colored Cyan "======================================"
Write-Colored Cyan "  Kexvim 安装程序 (Windows)"
Write-Colored Cyan "======================================"

# 1. 检查 Node.js
try {
    $nodeVer = node --version
    Write-Colored Green "[✓] Node.js $nodeVer"
} catch {
    Write-Colored Yellow "[!] 未安装 Node.js"
    Write-Colored Yellow "    去 https://nodejs.org 下载 LTS 版安装后重试"
    Write-Host "    按任意键打开下载页面..."; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Start-Process "https://nodejs.org"
    exit 1
}

# 2. 检查 git
$hasGit = $true
try { git --version | Out-Null } catch { $hasGit = $false }

# 3. 克隆/下载代码
if (Test-Path "$KexvimDir\src") {
    Write-Colored Cyan "[~] Kexvim 目录已存在，拉取更新..."
    Push-Location $KexvimDir
    if ($hasGit) {
        git pull --ff-only 2>$null
    }
    Pop-Location
} else {
    Write-Colored Cyan "[~] 下载 Kexvim..."
    if ($hasGit) {
        git clone $RepoUrl "$env:TEMP\kexvim-tmp" 2>$null
        Move-Item "$env:TEMP\kexvim-tmp\*" $KexvimDir -Force 2>$null
        Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force 2>$null
    } else {
        # 没 git 就用 zip 下载
        $zipUrl = "https://gitee.com/moscowzk/kexvim/repository/archive/master.zip"
        $zipPath = "$env:TEMP\kexvim.zip"
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\kexvim-tmp" -Force
        $extracted = Get-ChildItem "$env:TEMP\kexvim-tmp\kexvim-master" | Select-Object -First 1
        if (-not $extracted) { $extracted = Get-ChildItem "$env:TEMP\kexvim-tmp" | Select-Object -First 1 }
        Copy-Item "$($extracted.FullName)\*" $KexvimDir -Recurse -Force
        Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force
        Remove-Item $zipPath -Force
    }
    Write-Colored Green "[✓] 代码下载完成"
}

# 4. 安装依赖
Push-Location $KexvimDir
Write-Colored Cyan "[~] 安装 npm 依赖..."
npm install --ignore-scripts 2>&1 | Out-Null
Write-Colored Green "[✓] 依赖安装完成"
Pop-Location

# 5. 配置 API Key
$envPath = "$KexvimDir\data\.env"
if (-not (Test-Path $envPath)) {
    if (-not (Test-Path "$KexvimDir\data")) { New-Item -ItemType Directory -Path "$KexvimDir\data" -Force | Out-Null }
    $key = Read-Host "请输入 DeepSeek API Key"
    if ($key) {
        Set-Content -Path $envPath -Value "DEEPSEEK_API_KEY=$key`nKEXVIM_HOME=$KexvimDir"
        Write-Colored Green "[✓] API Key 已保存"
    } else {
        Write-Colored Yellow "[!] 跳过 API Key 配置，稍后编辑 $envPath"
    }
}

# 6. 创建快捷方式
$shortcutPath = "$env:USERPROFILE\Desktop\Kexvim.lnk"
if (-not (Test-Path $shortcutPath)) {
    $wshell = New-Object -ComObject WScript.Shell
    $shortcut = $wshell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoExit -Command cd '$KexvimDir'; npm start"
    $shortcut.Description = "Kexvim AI Assistant"
    $shortcut.Save()
    Write-Colored Green "[✓] 桌面快捷方式已创建"
}

Write-Colored Cyan "======================================"
Write-Colored Green "  Kexvim 安装完成！"
Write-Colored Cyan "======================================"
Write-Host ""
Write-Host "在桌面双击 [Kexvim] 快捷方式启动"
Write-Host "或打开终端: cd $KexvimDir && npm start"
Write-Host ""
Read-Host "按 Enter 启动 Kexvim..."
Start-Process powershell -ArgumentList "-NoExit -Command cd '$KexvimDir'; npm start"
