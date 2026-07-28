# Kexvim 入口 — 轻量转发到 kexvim.js
# 用法:  .\kexvim.ps1 {init|update|restart}
param([string]$Action)

$KexvimDir = "$env:USERPROFILE\.kexvim"
if (-not (Test-Path "$KexvimDir\kexvim.js")) {
    if (-not $Action) { Write-Host "[✗] 未安装。先运行: .\kexvim.ps1 init" -ForegroundColor Yellow; return }
    & "$KexvimDir\kexvim.js" init
    return
}
& node "$KexvimDir\kexvim.js" $Action
