---
name: kexvim-deployment
description: "Build, install, update, deploy kexvim cross-platform"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, deployment, install, update, cross-platform, cli, entry-scripts, portable-nodejs]
    related_skills: [kexvim-restart, kexvim-development]
---

# Kexvim Deployment

## Design Principle: Simplicity Over Features

Every feature that adds steps to the user's path must justify itself. If it can be removed without breaking the core workflow, remove it.

This session's repeated user corrections:
- "别复杂了" — don't over-engineer
- "简洁" — keep it concise
- "用户感知最少" — minimum user-facing surface
- "kexvim.ps1 不需要" — fewer entry scripts
- "就一个 kexvim.js 不可以？" — one file to rule them all
- "线程之间本来就不该有什么通信" — no IPC, no shared state
- "你要什么权限？" — don't ask for credentials the user doesn't have; find them yourself (Gitee token on NAS /mnt/nas/agent安装/mosike99.git-token.txt)

**Catch them early**: When planning a feature, ask "could this be done with less code / fewer files / fewer steps?" If yes, do that instead.

## Project Layout

- **Dev repo** (`<项目根>/`): TypeScript source, build artifacts. Push source + built `kexvim.js`.
- **Public repo** (`/tmp/sage-public/`): Release-only. Contains `kexvim.js`, `kexvim.sh`, `kexvim.bat`, `skills/`, `README.md`, `LICENSE`, `package.json`, `.gitignore`.
- **Build**: `npm run build` (esbuild → `dist/kexvim.mjs`, ~30ms). Deploy to runtime binary: `cp dist/kexvim.mjs kexvim.js && chmod +x kexvim.js` (root `kexvim.js` is gitignored `*.js`, so it's local-only). No separate watchdog.js build.
- **Data**: `<项目根>/data/` — `.env` (API keys), `kexvim.db` (sessions), `config.yaml`, `cron-jobs.json`. Stop file: `<项目根>/.stop_watchdog`.

## Architecture

Single `kexvim.js`, single-process multi-thread (Worker Threads). Three Workers + main thread console.

- **watchdog Worker**: minimal — stop file (3s poll) + SIGTERM → daemonize
- **agent Worker**: config → LLM → TUI (always) + Gateway (optional) + GuardianAgent
- **guardian Worker**: config/LLM initialized, awaiting platform
- **console (main thread)**: spawn Workers, forward stdout/stderr, handle SIGTERM graceful shutdown

**No IPC**: Workers don't communicate. Zero message passing.
**No hierarchy**: Workers are peers. Watchdog doesn't restart others.
**Daemonize**: SIGTERM → worker.terminate() → wait 3s → spawn detached `--daemon` → exit.

## Built-in CLI

Implemented as `CliHandler.handleCliCommand()` in `src/CliHandler.ts` (moved out of Main.ts).

| Command | What it does |
|---------|-------------|
| `kexvim.js` | Console mode: spawns watchdog/agent/guardian Workers |
| `kexvim.js --daemon` | Background mode: spawns same Workers with no console |
| `kexvim.js init` | Self-installing: provisions `<项目根>`, prompts for API Key, sets up PATH, downloads skills |
| `kexvim.js update` | `git pull` (if .git exists) or download raw kexvim.js, then restart |
| `kexvim.js restart` | Kill old processes via pkill -9 / taskkill /f, start new detached |
| `kexvim.js --help` | Print usage |

### `restart` — pkill -9 (critical)

Uses **SIGKILL** (`-9`) to avoid triggering the watchdog Worker's SIGTERM handler:

```typescript
execFileSync("pkill", ["-9", "-f", "[^ ]*node .*/kexvim\\.js($|\\s)"]);
```

**Regex `[^ ]*node ` instead of `^node `** (2026-08 fix): the daemon is spawned with `process.execPath` (absolute node path), so its cmdline is `/abs/path/node <项目根>/kexvim.js` — it does NOT start with `node `. The old `^node .*/kexvim\\.js` pattern never matched execPath-spawned daemons, so every restart spawned an extra instance instead of replacing the old one (observed: 3 daemons accumulated in one day → duplicate replies). `[^ ]*node ` matches both `node /abs/...` and `/abs/node /abs/...`. The `/` before `kexvim.js` still distinguishes daemons from the CLI (`node kexvim.js` relative, no `/` → no self-kill).

**`\s` escaping pitfall (commit 8cb23ad, 2026-08-01)**: the TS source string must contain `\\s` (two chars) so the VALUE passed to pkill is `\s` = ERE whitespace class. If the source has `\\\\s` (four chars), the value is `\\s` = literal backslash followed by `s` — matches NOTHING in a real cmdline. The old code relied on the `$` end-anchor (bare `kexvim.js`, no args) so it worked by accident; once the spawn gained `--daemon`, every instance needed the `\s` branch and the pkill silently killed nothing. Verify with `pgrep -f '<the pattern>'` before trusting a restart.

### `restart` must spawn with `--daemon` (2026-08 fix)

`CliHandler` spawns the child WITHOUT `--daemon` (bug fixed to `[binPath, "--daemon"]`). Without it, the child runs console mode → main thread hits the REPL → stdin is `/dev/null` (stdio ignore) → immediate EOF → `terminateWorkers()` → process exits. Symptom: restart prints "已在后台运行" but the process is gone within seconds, or alive with zero sockets.

### `--daemon` mode: workers must stay ref'd (2026-08 fix)

`WorkerLauncher.launchDaemon()` must NOT `w.unref()` the spawned workers. With unref, the main thread returns → event loop empties → process exits immediately (empty log, no process). Workers themselves hold the event loop; keep them ref'd.

### Stale-process pitfall (2026-08)

A leftover dev process (`npm exec tsx src/Main.ts` / `node dist/dev.mjs`) does NOT match the `kexvim.js` pkill pattern and survives restarts. It can hold the log fd and keep spamming reconnect errors (`token not exist or expire` 11244) that look like the new build is broken. Check `lsof <项目根>/data/kexvim.log` to find who actually owns the log, and `pgrep -af "tsx src/Main"` for the old tree (npm/sh/node/esbuild). A fresh console-mode probe (`sleep 30 | node kexvim.js` in <项目根>) proves the new build connects (`[a] [BotAPI] 已就绪`) when the daemon path is the suspect.

### Verifying a running daemon actually connected

`pgrep -f kexvim.js` alive ≠ connected. Check sockets: `ls -la /proc/<pid>/fd | grep socket` or `ss -tnp | grep <pid>` — expect an ESTAB to `api.sgroup.qq.com:443`. Also refresh `<项目根>/data/kexvim.pid` (it can point at a dead PID after unclean kills).

**Stale log check first (2026-08)**: `data/kexvim.log` and `data/kexvim.pid` can be **hours old** — written by a previous boot, not the current process. The current daemon's workers may not write to kexvim.log at all (daemon mode doesn't pipe worker stdout anywhere). Before reading the log, compare mtimes:

```bash
stat -c "%y" data/kexvim.log data/kexvim.pid   # vs `date`
```

If the log's mtime predates the process start, **ignore its contents** — the reconnect-storm (`正在重连 (尝试 N)`) you see may be entirely historical. Verify the live process instead:

```bash
ss -tnp | grep <pid>                # expect ESTAB to api.sgroup.qq.com:443 (getent hosts api.sgroup.qq.com to confirm IP)
grep Threads /proc/<pid>/status     # 13 = main + watchdog/agent/guardian workers holding event loops
```

**Credential probe — prove the platform rejects the pair, not the code (2026-08)**: when the log screams `11244 token not exist or expire` on `GET /gateway`, probe the creds directly before touching the code:

```bash
node -e "
const https=require('https');
// 1) exchange app_id+client_secret for access_token
//    POST https://bots.qq.com/app/getAppAccessToken  {appId, clientSecret}
// 2) GET https://api.sgroup.qq.com/gateway  Authorization: 'QQBot '+token
"
```

Both returning 200 (token + `{"url":"wss://..."}`) means **credentials and gateway are fine** — the failure is elsewhere (stale process holding the log fd, old bundle, or the log itself being historical). A healthy current process shows an ESTAB connection to the gateway IP that stays stable (a reconnect loop churns connections instead of holding one).

### `--daemon` foreground timeout is NORMAL (2026-08)

`node dist/dev.mjs --daemon` (or `kexvim.js --daemon`) is a **long-lived process** — the main thread spawns the 3 workers and stays resident. A foreground `timeout 60`/`sleep` wrapper will hit its limit and get killed; that is expected, not a hang. To run it from a tool/session: use a background task, or `nohup`-style detach, then verify separately.

**Daemon mode does NOT pipe worker stdout/stderr** (`launchDaemon()` creates Workers without piping, unlike console mode). You will NOT see `[a]`/`[g]` prefixes in the terminal. Worker diagnostics historically went to `data/kexvim.log`, but **daemon boots may not write there at all** (2026-08: log mtime stayed hours-old across a fresh daemon start). Check `stat -c "%y" data/kexvim.log` before trusting its contents — for the live process, use sockets/threads (see "Verifying a running daemon actually connected").

**Judging "did my change break it" vs "pre-existing platform issue"**: kexvim.log accumulates across restarts. A reconnect loop counter (`正在重连 (尝试 N)`) that continues from a large N right after a fresh start (e.g. starts at 6, climbs to 5000+) means the failure predates this restart — the platform-side credential is the suspect, not the code you just changed. QQ error `11244 token not exist or expire` on `GET /gateway` = the app_id/client_secret pair no longer matches the QQ open platform record (secret rotated / app disabled) — check the console, not the code.

**Mock-server + execSync pitfall (2026-08, STT tool smoke test)**: when the code under test calls `execSync` (e.g. `SpeechToTextTool` invoking curl), it **blocks the event loop** — a mock http server in the SAME process never receives the request and the test hangs until timeout. The mock must be `spawn`ed as a separate child process (`spawn('node', ['-e', mockCode, mode])`), waiting for a `MOCK_UP` stdout signal before exercising the tool. Related: mock long-poll endpoints (`getUpdates`) need a ~50ms simulated delay or the poll loop busy-spins the heap to OOM (1.8GB).

## Entry Scripts

Two per-platform scripts in the public repo. Both are **pure launchers** — no state logic, no path prompts, no API key collection. kexvim.js handles all of that.

| Script | Behavior |
|--------|----------|
| `kexvim.bat` | Ensure Node.js → download kexvim.js + skills if missing → `node kexvim.js %*` |
| `kexvim.sh` | Ensure Node.js → download kexvim.js + skills if missing → `exec node kexvim.js "$@"` |

### First-Install Skills Download

Both entry scripts download `skills/` alongside `kexvim.js` on first install:

```bash
[ -f "$DIR/kexvim.js" ] || {
  mkdir -p "$DIR"
  curl -fsSL "$REPO/raw/main/kexvim.js" -o "$DIR/kexvim.js"
  command -v git >/dev/null 2>&1 && {
    tmp=$(mktemp -d)
    git clone --depth 1 "$REPO.git" "$tmp" --single-branch 2>/dev/null
    [ -d "$tmp/skills" ] && cp -r "$tmp/skills" "$DIR/skills/"
    rm -rf "$tmp"
  }
}
```

The InstallKexvim.ts tool inside kexvim.js (`kexvim init`) also downloads skills if missing, using the same git clone pattern. This provides a second chance if the entry script didn't have git available.

### Zero-Prerequisite Windows Install

kexvim.bat checks for `node` at startup. If not found, downloads portable `node.exe` (v22.0.0 win-x64) to `<项目根>\` and adds it to PATH. All subsequent operations use this portable Node.

```bat
powershell -Command "Invoke-WebRequest -Uri 'https://nodejs.org/dist/v22.0.0/win-x64/node.exe' -OutFile '%DIR%\\node.exe'"
```

**Limitation**: Portable node.exe has no npm. Kexvim release is self-contained, so this is fine.

### .bat Encoding: GBK for Chinese Windows

The public repo's kexvim.bat is **GBK-encoded** (not UTF-8). cmd.exe on Chinese Windows uses code page 936. UTF-8 Chinese text produces garbage. ASCII-only is fine regardless of encoding.

**Conversion**:
```bash
iconv -f utf-8 -t gbk kexvim.bat -o kexvim.bat.gbk && mv kexvim.bat.gbk kexvim.bat
```

### .bat Input Handling

Use `findstr` for case-insensitive prompts, never `if /i`:
```bat
echo !VAR!|findstr /i "^y$" >nul && ( ... )
```

Never use `chcp 65001`. It breaks Chinese text and `set /p` input on Windows.

## Release Workflow

1. cd <项目根> && npx tsc --noEmit (type check)
2. npm run build (esbuild → dist/kexvim.mjs) && cp dist/kexvim.mjs kexvim.js
3. cp <项目根>/kexvim.js /tmp/sage-public/ && cp -r <项目根>/skills /tmp/sage-public/skills
4. iconv -f utf-8 -t gbk kexvim.bat -o kexvim.bat.gbk && mv kexvim.bat.gbk kexvim.bat
5. cd /tmp/sage-public/ && git add -A && git commit -m ... && git push origin main
6. cd <项目根> && git add -A && git commit -m ... && git push origin main
7. Tag + Gitee release (optional): git tag vX.Y.Z && git push origin vX.Y.Z && npx gitee-release-cli create --upload --no-version-selection

### Gitee Release Token

Gitee access_token is stored at `~/.config/gitee-release-cli-nodejs/config.json`. If daily reset clears it:

```
# Read from NAS
cat /mnt/nas/agent安装/mosike99.git-token.txt
# Line 5 format: gitee  zk/zk-agent  <token>

# Write to gitee-release-cli config
cd /tmp && npm install gitee-release-cli --no-save
./node_modules/.bin/gitee-release-config accessToken "<token>"
```

### SSH push is fragile — prefer HTTPS + token (2026-08)

`~/.ssh/config` points gitee.com at `IdentityFile /tmp/sage_deploy_key`, but **/tmp is wiped on reboot** —
the key silently vanishes and `git push` fails with `Permission denied (publickey)` while
`~/.ssh/id_ed25519` is NOT registered on Gitee. Don't fight SSH after a reboot; push over HTTPS
with the access token from `~/.config/gitee-release-cli-nodejs/config.json`:

```bash
cd <项目根>
git push "https://moscowzk:<TOKEN>@gitee.com/moscowzk/kexvim-dev.git" main
# verify: git ls-remote "https://moscowzk:<TOKEN>@gitee.com/moscowzk/kexvim-dev.git" main
```

The token is on disk (survives reset), the deploy key is not. If SSH must be restored, the
private key is recoverable from NAS (`/mnt/nas/agent安装/`), not from /tmp.

**Diagnostics (2026-08):**
- `ssh -i ~/.ssh/id_ed25519 -T git@gitee.com` STILL fails even with a valid key, because
  `~/.ssh/config`'s `IdentityFile` + `IdentitiesOnly yes` override `-i`. Bypass the config
  entirely: `ssh -F /dev/null -i ~/.ssh/id_ed25519 ...` — if that still fails, the key is
  simply not registered on Gitee.
- Validate the token before pushing: `curl "https://gitee.com/api/v5/user?access_token=<TOKEN>"`
  returns the user JSON when valid. Token lives in `~/.config/gitee-release-cli-nodejs/config.json`.

**⚠️ Verify the REMOTE before declaring work missing (2026-08-01 教训)**:
When another agent (e.g. kexvim's in-bot agent) reports "commit xxx pushed" but `git log` /
`git cat-file -t xxx` on local says it doesn't exist, that proves NOTHING about the remote —
local refs are stale until you fetch. Especially when SSH is broken, `git fetch origin` fails
silently (Permission denied) and leaves `origin/main` pointing at an old commit, making the
other agent look like it hallucinated. The correct sequence:

```bash
git fetch "https://moscowzk:<TOKEN>@gitee.com/moscowzk/kexvim-dev.git" main
git log FETCH_HEAD --oneline -3     # actual remote state
git pull "https://moscowzk:<TOKEN>@gitee.com/moscowzk/kexvim-dev.git" main   # fast-forward
```

This session: kex's commit 6a3096d was real and on the remote; the local-only check wrongly
called it "fabricated" until the user said "你再拉取看下". Always fetch (HTTPS+token) BEFORE
declaring a commit absent.

### Public Repo Files

- `kexvim.js` — compiled binary (required)
- `kexvim.sh` — Linux entry, downloads kexvim.js + skills on first install
- `kexvim.bat` — Windows entry, GBK-encoded, same first-install behavior
- `skills/` — 20 public skills (devops, mcp, software-development, research, media, creative, productivity) downloaded on first install
- `README.md` — minimal: "download and double-click"
- `package.json`, `.gitignore`, `LICENSE` — metadata

No separate watchdog.js, no install.ps1, no update scripts. Everything is in kexvim.js.

## Hermes 官方技能移植到公开仓 skills/（2026-08）

移植源：`~/.hermes/hermes-agent/skills/`（~180 个）。筛选：纯 curl/python/CLI、无 GPU/
Hermes 专属/外部账号依赖。A 级 10 个已移植（arxiv/polymarket/gif-search/blogwatcher/
humanizer/architecture-diagram/pdf/docx/xlsx/ocr-and-documents），B 级候选（youtube-content/
jupyter-live-kernel/huggingface-hub/songsee/llm-wiki/ascii-art）。

**移植 = 复制 + 适配，不只是拷贝**（用户明确要求"移植后重新整理下内容"）：
1. 复制 SKILL.md + 辅助文件：`references/`（polymarket api-endpoints、pdf forms.md/reference.md）、
   `scripts/`（pdf 7 个、docx 60 个含 XSD、xlsx recalc.py、ocr 2 个、polymarket.py）、
   `templates/`（architecture-diagram template.html）、`LICENSE`（必须随附）
2. 工具名映射：`web_extract`→`web_fetch`、`vision_analyze`→`vision`、
   `${HERMES_HOME}/.env`→`<项目根>/data/.env`、frontmatter `metadata.hermes:`→`metadata.kexvim:`、
   `hermes skills install`→删
3. 删 Hermes 专属引用（nano-pdf/excel-author/powerpoint 若未移植）、`skill://sage-*`→`skill://kexvim-*`
4. author 注明移植来源；脚本内 User-Agent 改 kexvim（polymarket.py）
5. 验证：frontmatter 完整、`python3 -m py_compile` 全过、grep 无 web_extract/vision_analyze/HERMES_HOME 残留

**description ≤60 字符硬限制（移植第一大坑）**：kexvim `SkillManageTool.ts` 的
`MAX_DESCRIPTION_LENGTH = 60`（Hermes 是 1024）。Hermes 技能的 description 普遍 100-300 字符，
直接拷过来 `skill_manage(action='create')` 会拒绝。但**加载侧（parseSkill）不校验长度**，
只要求 name+description 存在——所以超长的公共技能能正常加载运行，只是无法通过 create 工具重建。
移植时把 description 压到 ≤60（数到 61 也算超），并提醒用户已有超长技能可留（能运行）。

运行时依赖不随移植（docx/xlsx 需 soffice、pdf 需 poppler/qpdf、ocr 需 marker-pdf）— 预期行为。

## Gitee Raw URL Downloads

Gitee serves `.bat` files as text/plain. Append `?download=1` to force download:
```
https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat?download=1
```

## DB Migration Pitfall

`CREATE TABLE IF NOT EXISTS messages (...)` includes `CREATE INDEX ON messages(session_id, parent_id)`. On existing DB, `CREATE TABLE` is no-op but `CREATE INDEX` fails because `parent_id` column doesn't exist yet → whole `exec()` throws → ALTER TABLE migrations never run.

**Fix**: Split schema into three parts, run indexes AFTER column migrations:
1. `exec(SCHEMA)` — base tables
2. `exec(SCHEMA_FTS)` — FTS5 virtual table  
3. ALTER TABLE migrations (try/catch per column)
4. `exec(SCHEMA_INDEXES)` — indexes (try/catch wrapped)

## Daily Reset Pitfall

The system auto-resets conversation context daily. This wipes:
- **Conversation history** — lost
- **In-memory state** — lost
- **Environment variables** — lost

It does NOT wipe:
- **Files on disk** (`<项目根>/`, `~/.config/`, NAS mounts) — preserved
- **Hermes persistent memory** — but may be full (2156/2200 chars) and need consolidation
- **Node_modules, builds, data files** — preserved

**Mitigations**:
- Store durable data (Gitee token, API keys) in files on disk, not memory
- Prefer `memory` tool over conversation for facts that must survive reset
- When token/config is missing after reset, check: NAS mounts → ~/.config/ → <项目根>/data/
- If memory is full, consolidate: merge stale entries, remove task-progress logs

## API Key .env File

- Path: `<项目根>/data/.env`
- Format (ASCII/UTF-8 only):
  ```
  DEEPSEEK_API_KEY=sk-xxx
  KEXVIM_HOME=<项目根>
  ```
- **Windows pitfall**: `Set-Content` defaults to UTF-16LE. Use `-Encoding ASCII`.

## Dev Build Workflow (esbuild + extensionless imports)

Since v0.4+, kexvim uses esbuild for both dev and production. No tsx, no strip-only, no runtime .ts files.

**Architecture:**
| Layer | Tool | Purpose |
|-------|------|---------|
| Type checking | `tsc --noEmit` | Static analysis only, no output |
| Dev compile | `esbuild src/Main.ts --bundle --platform=node --format=esm --outfile=dist/dev.mjs --external:cron --external:ws --external:js-yaml --external:@modelcontextprotocol/*` | Fast single-file bundle → `node dist/dev.mjs` |
| Prod compile | `esbuild ... --minify --banner:js='#!/usr/bin/env node' --outfile=dist/kexvim.mjs`, then `cp dist/kexvim.mjs kexvim.js` | Minified single-file (runtime binary = root `kexvim.js`) |
| **For command modules** (restart/stop/install): same esbuild pattern, entry from `src/commands/*.ts` |

**Scripts in `package.json`:**
```json
"start": "esbuild src/Main.ts --bundle --platform=node --format=esm --outfile=dist/dev.mjs --external:cron --external:ws --external:js-yaml --external:@modelcontextprotocol/* && node dist/dev.mjs",
"build:dev": "tsc --noEmit && esbuild src/Main.ts --bundle --platform=node --format=esm --outfile=dist/dev.mjs --external:cron --external:ws --external:js-yaml --external:@modelcontextprotocol/*",
"build": "esbuild ... --minify ... --outfile=kexvim.js"
```

**Essential rules:**
1. **Extensionless local imports** — `from './Foo'`, NOT `from './Foo.ts'` or `from './Foo.js'`. Esbuild resolves to `.ts` at compile time.
2. **npm package subpath imports MUST keep `.js`** — e.g. `from '@modelcontextprotocol/sdk/client/stdio.js'` not `'.../stdio'`. Esbuild's bundler resolution does NOT add `.js` to bare specifier subpaths.
3. **`--external` is critical** — CJS packages (cron, ws, js-yaml, @modelcontextprotocol/*) must be listed as externals. Bundling them into ESM bundle causes `Dynamic require of "child_process" is not supported` at runtime.
4. **`moduleResolution: "bundler"` in tsconfig** — allows extensionless imports in source for `tsc --noEmit`.
5. **`noEmit: true` in tsconfig** — tsc is type-check only.
6. **Single quotes for imports** — user preference: `from '...'` not `from "..."`.
7. **No `enum`** — tsc type-checks enums fine, but if the code ever runs through Node strip-only, `enum` is unsupported. Use `const` objects with `as const` type pattern.

**Why esbuild over tsc emit:**
- tsc outputs imports as-is → extensionless imports fail in Node ESM (needs `.js`)
- esbuild resolves extensionless to `.ts` at compile time, outputs valid ESM `.mjs`
- esbuild is 10x faster (141ms vs several seconds for tsc)
- No `tsc-alias` post-process step needed

**References:**
- `references/portable-nodejs.md` — download URL maintenance, version pinning
- `references/pkill-regex-daemon-vs-cli.md` — why the pkill regex uses `[^ ]*node ` (execPath daemons, not `^node `)
- `references/daemon-lifecycle-restart.md` — 2026-08 restart debugging: unref bug, missing --daemon, stale tsx process, verification checklist
- `references/install-scripts-vs-builtin.md` — evolution from per-platform scripts to built-in CLI
- `references/entry-script-auto-detect.md` — entry script auto-detect behavior
- `kexvim-architecture` skill — Gateway message flow, interim-message pitfall, cascade error safety
- `kexvim-hermes-alignment` skill — QQ platform interim-message pitfall, Hermes streaming differences
- `references/gateway-message-flow.md` — full message flow walkthrough with interim-message and cascade error pitfalls\n
