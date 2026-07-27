# Kexvim 更新脚本 (Windows)
# 用法: 双击运行，或在终端执行

$KexvimDir = "$env:USERPROFILE\.kexvim"

Write-Host "======================================" -ForegroundColor Cyan
Write-Host "  更新 Kexvim..."
Write-Host "======================================" -ForegroundColor Cyan

if (-not (Test-Path $KexvimDir)) {
    Write-Host "[✗] 未找到 $KexvimDir，先运行安装脚本" -ForegroundColor Yellow
    Read-Host "按 Enter 退出"
    exit 1
}

Push-Location $KexvimDir

# 检查是否有 git
$hasGit = $true
try { git --version | Out-Null } catch { $hasGit = $false }

if ($hasGit -and (Test-Path ".git")) {
    Write-Host "[~] git pull 拉取更新..." -ForegroundColor Cyan
    git pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[✗] 拉取失败" -ForegroundColor Red
        Read-Host "按 Enter 退出"
        exit 1
    }
} else {
    Write-Host "[~] 重新下载（无 git）..." -ForegroundColor Cyan
    Remove-Item "$env:TEMP\kexvim-update" -Recurse -Force -ErrorAction SilentlyContinue
    $zipUrl = "https://gitee.com/moscowzk/kexvim/repository/archive/main.zip"
    $zipPath = "$env:TEMP\kexvim-update.zip"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath "$env:TEMP\kexvim-update" -Force
    Copy-Item "$env:TEMP\kexvim-update\kexvim-main\*" $KexvimDir -Recurse -Force
    Remove-Item "$env:TEMP\kexvim-update" -Recurse -Force
    Remove-Item $zipPath -Force
}
Pop-Location

Write-Host "[✓] 更新完成" -ForegroundColor Green

Write-Host "[~] 重启..." -ForegroundColor Cyan
taskkill /f /im node.exe 2>$null
Start-Sleep -Seconds 2
Start-Process powershell -ArgumentList "-NoExit -Command cd '$KexvimDir'; npm start"

Write-Host "[✓] Kexvim 已重启" -ForegroundColor Green
