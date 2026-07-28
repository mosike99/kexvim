# Kexvim 管理工具 (PowerShell)
# 用法:  .\kexvim.ps1 {init|update|restart}
#        kexvim.ps1 {init|update|restart}

param([ValidateSet("init","update","restart")][string]$Action)

$KexvimDir = "$env:USERPROFILE\.kexvim"
$RepoUrl = "https://gitee.com/moscowzk/kexvim"

function Write-Colored($Color, $Text) { Write-Host $Text -ForegroundColor $Color }

switch ($Action) {
    "init" {
        if (Test-Path "$KexvimDir\kexvim.js") { Write-Colored Yellow "Kexvim 已安装"; return }

        # 检测 git
        $hasGit = $true
        try { git --version | Out-Null } catch { $hasGit = $false }

        New-Item -ItemType Directory -Path $KexvimDir -Force | Out-Null

        if ($hasGit) {
            Write-Colored Cyan "[~] 克隆仓库..."
            git clone --depth 1 $RepoUrl $KexvimDir 2>$null
            if (-not (Test-Path "$KexvimDir\kexvim.js")) { Write-Colored Red "[✗] 克隆失败"; return }
        } else {
            Write-Colored Cyan "[~] 下载 release 包..."
            Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri "$RepoUrl/repository/archive/main.zip" -OutFile "$env:TEMP\kexvim.zip"
            Expand-Archive -Path "$env:TEMP\kexvim.zip" -DestinationPath "$env:TEMP\kexvim-tmp" -Force
            Copy-Item "$env:TEMP\kexvim-tmp\kexvim-main\*" $KexvimDir -Recurse -Force
            Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force; Remove-Item "$env:TEMP\kexvim.zip" -Force
        }

        # API Key
        New-Item -ItemType Directory -Path "$KexvimDir\data" -Force | Out-Null
        $key = Read-Host "请输入 DeepSeek API Key"
        if ($key) {
            Set-Content -Path "$KexvimDir\data\.env" -Value "DEEPSEEK_API_KEY=$key" -Encoding ASCII
            Add-Content -Path "$KexvimDir\data\.env" -Value "KEXVIM_HOME=$KexvimDir" -Encoding ASCII
            Write-Colored Green "[✓] API Key 已保存"
        }
        Write-Colored Green "[✓] 安装完成。运行 .\kexvim.ps1 restart 启动"
    }

    "update" {
        if (-not (Test-Path $KexvimDir)) { Write-Colored Red "[✗] 未安装 Kexvim"; return }

        $hasGit = $true
        try { git --version | Out-Null } catch { $hasGit = $false }

        if ($hasGit -and (Test-Path "$KexvimDir\.git")) {
            Write-Colored Cyan "[~] git pull..."
            Push-Location $KexvimDir; git pull --ff-only; Pop-Location
        } else {
            Write-Colored Cyan "[~] 下载更新..."
            Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri "$RepoUrl/repository/archive/main.zip" -OutFile "$env:TEMP\kexvim.zip"
            Expand-Archive -Path "$env:TEMP\kexvim.zip" -DestinationPath "$env:TEMP\kexvim-tmp" -Force
            Copy-Item "$env:TEMP\kexvim-tmp\kexvim-main\kexvim.js" $KexvimDir -Force
            Remove-Item "$env:TEMP\kexvim-tmp" -Recurse -Force; Remove-Item "$env:TEMP\kexvim.zip" -Force
        }
        Write-Colored Green "[✓] 更新完成，正在重启..."
        & $MyInvocation.MyCommand.Path restart
    }

    "restart" {
        if (-not (Test-Path "$KexvimDir\kexvim.js")) { Write-Colored Red "[✗] 未安装 Kexvim"; return }

        Write-Colored Cyan "[~] 停止旧进程..."
        Get-Process node -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2

        Write-Colored Cyan "[~] 启动..."
        Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoExit -Command cd '$KexvimDir'; node kexvim.js"
        Write-Colored Green "[✓] Kexvim 已启动"
    }
}
