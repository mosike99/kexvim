# Kexvim — 双击或命令行运行
# 自动检查状态：缺文件下载，缺 Key 提示输入，完成后打印常用命令

param([string]$Action)

$KexvimDir = "$env:USERPROFILE\.kexvim"
$RepoUrl = "https://gitee.com/moscowzk/kexvim"
$HasError = $false

function Write-Colored($Color, $Text) { Write-Host $Text -ForegroundColor $Color }

# 有参数 → 直接转发
if ($Action) {
    if (-not (Test-Path "$KexvimDir\kexvim.js")) {
        Write-Colored Red "[✗] 未安装，先双击此脚本自动安装"
        Read-Host "按 Enter 退出"
        return
    }
    & node "$KexvimDir\kexvim.js" $Action
    Read-Host "按 Enter 退出"
    return
}

Write-Host "==================================="
Write-Host "       Kexvim"
Write-Host "==================================="

# 1. 检查 kexvim.js
if (-not (Test-Path "$KexvimDir\kexvim.js")) {
    Write-Colored Cyan "[~] 首次运行，下载 kexvim.js..."
    New-Item -ItemType Directory -Path $KexvimDir -Force | Out-Null
    try {
        Invoke-WebRequest -Uri "$RepoUrl/raw/main/kexvim.js" -OutFile "$KexvimDir\kexvim.js" -ErrorAction Stop
        Write-Colored Green "[✓] kexvim.js 已下载"
    } catch {
        Write-Colored Red "[✗] 下载失败，检查网络连接"
        $HasError = $true
    }
}

# 2. 检查 API Key
if (-not (Test-Path "$KexvimDir\data\.env")) {
    Write-Host ""
    Write-Colored Cyan "[~] 首次运行，需要配置 API Key"
    New-Item -ItemType Directory -Path "$KexvimDir\data" -Force | Out-Null
    $key = Read-Host "请输入 DeepSeek API Key"
    if ($key) {
        Set-Content -Path "$KexvimDir\data\.env" -Value "DEEPSEEK_API_KEY=$key" -Encoding ASCII
        Add-Content -Path "$KexvimDir\data\.env" -Value "KEXVIM_HOME=$KexvimDir" -Encoding ASCII
        Write-Colored Green "[✓] API Key 已保存"
    } else {
        Write-Colored Yellow "[!] 跳过，稍后可运行: .\kexvim.ps1 init"
    }
}

Write-Host ""

if ($HasError) {
    Write-Colored Red "[✗] 安装未完成，请检查后重试"
} else {
    Write-Colored Green "[✓] Kexvim 已就绪"
    Write-Host ""
    Write-Host "  常用命令:"
    Write-Host "    kexvim             启动"
    Write-Host "    kexvim restart     重启"
    Write-Host "    kexvim update      更新"
    Write-Host "    kexvim --help      帮助"
    Write-Host ""
    Write-Host "  或直接双击此脚本启动"
    Write-Host ""
    Write-Host "  启动试试:  .\kexvim.ps1 restart"
}

Read-Host "按 Enter 退出"
