# Entry Script Behavior

## Current: Direct kexvim.js Launch

Both entry scripts reference `kexvim.js` directly (no separate `watchdog.js`).

**kexvim.bat** (Windows):
```
1. Check for system Node.js (where node)
2. If missing: check <项目根>\node.exe (portable download)
3. If still missing: download portable node.exe from nodejs.org
4. Download kexvim.js if not in <项目根>
5. → node <项目根>/kexvim.js [args]
```

**kexvim.sh** (Linux/macOS):
```
1. Check for Node.js (command -v node)
2. If missing: print error, exit (no portable download for Unix)
3. Download kexvim.js if not in <项目根>
4. → exec node <项目根>/kexvim.js "$@"
```

Both scripts are pure ASCII (`.bat` is GBK-encoded for Chinese Windows).

## .bat Encoding

Saved as **GBK (cp936)**, not UTF-8.

**Why**: cmd.exe on Chinese Windows uses code page 936. UTF-8 Chinese characters become garbage bytes when misinterpreted as GBK, corrupting nearby keywords (`if`, `echo`, `exist`).

**Conversion**: `iconv -f utf-8 -t gbk kexvim.bat -o kexvim.bat.gbk && mv kexvim.bat.gbk kexvim.bat`

**Rule**: Never use `chcp 65001` in batch files targeting Chinese Windows. It breaks `set /p` prompts and `if` comparisons.

## Input Handling

For Y/N prompts, use `findstr` (not `if /i`):
```bat
echo !VAR!|findstr /i "^y$" >nul && ( ... )
```

## kexvim.js Handles Everything

All state-machine logic migrated from scripts to kexvim.js:
- First-run detection (no `.env` → auto-run `init`)
- Path selection prompt
- API Key collection
- PATH setup
- Commands menu

## .bat Content (Reference)

Final minimal kexvim.bat (~18 lines):
```bat
@echo off
set "DIR=C:\kexvim-dev"
set REPO=https://gitee.com/moscowzk/kexvim

REM Check/install Node.js...
where node >nul 2>nul || (
    if not exist "%DIR%\node.exe" (
        powershell -Command "iwr 'https://nodejs.org/dist/v22.0.0/win-x64/node.exe' -OutFile '%DIR%\node.exe'"
    )
    set "PATH=%DIR%;%PATH%"
)

REM Download kexvim.js if missing
if not exist "%DIR%\kexvim.js" (
    mkdir "%DIR%" 2>nul
    powershell -Command "iwr '%REPO%/raw/main/kexvim.js' -OutFile '%DIR%\kexvim.js'"
)

REM Launch
node "%DIR%\kexvim.js" %*
pause
```
