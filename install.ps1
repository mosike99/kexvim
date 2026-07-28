# Kexvim 一键安装 (Windows)
# 用法:  irm https://gitee.com/moscowzk/kexvim/raw/main/install.ps1 | iex
# 然后:  kexvim.ps1 init
$url = "https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js"
$dir = "$env:USERPROFILE\.kexvim"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Invoke-WebRequest -Uri $url -OutFile "$dir\kexvim.js"
Write-Host "[✓] kexvim.js 已下载到 $dir" -ForegroundColor Green
Write-Host "运行以下命令完成安装:" -ForegroundColor Cyan
Write-Host "  cd $dir" -ForegroundColor White
Write-Host "  node kexvim.js init" -ForegroundColor White
