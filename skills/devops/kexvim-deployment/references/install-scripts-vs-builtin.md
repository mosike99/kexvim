# Evolution: Per-Platform Scripts → Built-in CLI

## Phase 1 — 10 separate scripts

Each platform had its own `install`, `update`, `restart`, `watchdog` script (`.bat`, `.ps1`, `.sh`, `.command`).
Total: 10 files. User reaction: "脚本太重了" (scripts are too heavy).

## Phase 2 — Unified `kexvim.{sh,bat,ps1}`

Three files, each with subcommands `{init|update|restart}`.
Better, but still three files to maintain.

## Phase 3 — Built into `kexvim.js` (current)

`node kexvim.js` handles everything:
- No arguments → normal Gateway/REPL mode
- `init` → first-time install (auto-provisions `<项目根>`, prompts API Key)
- `update` → pull + restart
- `restart` → kill + start

Single file. Node.js is already cross-platform. No shell syntax to maintain.

Three thin wrapper scripts (`kexvim.sh`, `kexvim.bat`, `kexvim.ps1`) remain in the public repo as convenience entry points — each is 3-6 lines, just `exec node <项目根>/kexvim.js "$@"`.

No `install.ps1`, no `install.bat`, no `install.sh`, no `watchdog.*`, no `update.*` — all subsumed into `kexvim.js`'s `init|update|restart` commands.

## Bootstrap

Users download `kexvim.js` to **any directory** (desktop, downloads, temp). Then:

- **Windows**: `irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js > kexvim.js`
- **Linux/macOS**: `curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.js -o kexvim.js`

Then `node kexvim.js init` handles everything: if `<项目根>/kexvim.js` doesn't exist, it git clones or downloads. If it already exists (bootstrap case), skips download. Prompts for API Key, writes `data/.env`, prints "done". The bootstrap file can be deleted.

No `mkdir`, no `cd`, no path knowledge required from the user.

## Key Design Lesson

When the runtime is already cross-platform (Node.js), the management CLI belongs inside it — not in shell wrappers. Shell scripts should only exist for the initial bootstrap where the runtime isn't available yet.
