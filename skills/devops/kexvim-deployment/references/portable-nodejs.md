# Portable Node.js Auto-Download (Windows)

## Why

Non-technical Windows users cannot be expected to install Node.js manually.
The kexvim.bat entry script downloads a portable `node.exe` if the system
doesn't have one. This makes the install truly zero-prerequisite.

## Download URL

```
https://nodejs.org/dist/v22.0.0/win-x64/node.exe
```

Currently pinned to **v22.0.0** (LTS branch). Update when the LTS version
bumps. Check latest LTS at https://nodejs.org/en/download/ — use the
"Windows Binary (.exe)" 64-bit URL.

Node.js version URL pattern:
`https://nodejs.org/dist/v{MAJOR}.{MINOR}.{PATCH}/win-x64/node.exe`

## Implementation (in kexvim.bat)

```bat
:ensure_node
where node >nul 2>nul
if %errorlevel% equ 0 goto :node_ok
if exist "%KEXVIM_DIR%\node.exe" (
    set "PATH=%KEXVIM_DIR%;%PATH%"
    goto :node_ok
)
echo [~] 正在下载 Node.js（首次运行需要）...
mkdir "%KEXVIM_DIR%" 2>nul
powershell -Command "Invoke-WebRequest -Uri 'https://nodejs.org/dist/v22.0.0/win-x64/node.exe' -OutFile '%KEXVIM_DIR%\node.exe'" >nul 2>nul
if not exist "%KEXVIM_DIR%\node.exe" (
    echo [x] Node.js 下载失败，请手动安装 https://nodejs.org
    pause & exit /b 1
)
set "PATH=%KEXVIM_DIR%;%PATH%"
echo [v] Node.js 就绪
:node_ok
```

## Edge Cases

### No internet
If the download fails, the script prints an error and directs the user to
nodejs.org for manual install. Acceptable — truly offline machines are rare
for first-time installs.

### ARM64 Windows (Surface, etc.)
Portable `node.exe` from the standard dist is x64 only. ARM64 users need
either:
- System-installed Node.js via official ARM64 MSI (handled by `where node`)
- Or use the ARM64 binary URL:
  `https://nodejs.org/dist/v22.0.0/win-arm64/node.exe`
Currently not auto-detected — add architecture detection if ARM64 adoption
grows.

### Already have system Node.js
The `where node` check catches this — no download needed. The portable
download is only for machines without any Node.js.

### npm not available
Portable `node.exe` does not include npm. Kexvim's release build
(`kexvim.js`) is self-contained — no npm needed. If a future version
requires npm (e.g., for plugin installation), this approach breaks.
Fall back to requiring the MSI installer in that case.

## Verification

After download, verify the file is a valid PE executable:
```bat
"%KEXVIM_DIR%\node.exe" --version
```
(Should print e.g. `v22.0.0`)
