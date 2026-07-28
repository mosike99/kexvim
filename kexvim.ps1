# Kexvim — 双击或命令行运行
# 双击自动安装/启动；传参 {init|update|restart} 执行对应操作

param([string]$Action)

$KexvimDir = "$env:USERPROFILE\.kexvim"
$RepoUrl = "https://gitee.com/moscowzk/kexvim"

function Write-Colored($Color, $Text) { Write-Host $Text -ForegroundColor $Color }

# 有参数 → 直接转发
if ($Action) {
    if (-not (Test-Path "$KexvimDir\kexvim.js")) { Write-Colored Red "[✗] 未安装，双击 kexvim.ps1 自动安装"; return }
    & node "$KexvimDir\kexvim.js" $Action
    return
}

# 无参数 → 自动模式
if (-not (Test-Path "$KexvimDir\kexvim.js")) {
    Write-Colored Cyan "[~] 首次运行，下载 kexvim.js..."
    New-Item -ItemType Directory -Path $KexvimDir -Force | Out-Null
    Invoke-WebRequest -Uri "$RepoUrl/raw/main/kexvim.js" -OutFile "$KexvimDir\kexvim.js"
    if (-not (Test-Path "$KexvimDir\kexvim.js")) { Write-Colored Red "[✗] 下载失败"; Read-Host "按 Enter 退出"; return }
    Write-Colored Green "[✓] 下载完成"
}

if (Test-Path "$KexvimDir\data\.env") {
    Write-Colored Cyan "[~] 启动 Kexvim..."
    & node "$KexvimDir\kexvim.js" restart
} else {
    Write-Colored Cyan "[~] 首次运行，配置 API Key..."
    & node "$KexvimDir\kexvim.js" init
    Write-Host ""
    & node "$KexvimDir\kexvim.js" restart
}

Read-Host "按 Enter 退出"
