# Sage Unified Deployment

## Hard Rules (All Devices)

| Variable | Path |
|----------|------|
| `SAGE_DIR` | `$HOME/.sage` (e.g. `/home/ubuntu/.sage`) |
| `SAGE_LOG` | `$SAGE_DIR/sage.log` |
| `SAGE_ENV` | `$SAGE_DIR/.env` |
| `SAGE_SESSION_DIR` | `$SAGE_DIR/sessions` |
| `SAGE_SKILLS_DIR` | `$SAGE_DIR/skills` |

No device is allowed to use different paths. `restart_sage.sh` supports `SAGE_DIR`/`SAGE_LOG`/`SAGE_ENV` env var overrides as a safety net, but deployment MUST use defaults.

## install.sh (Standard Setup)

```bash
# Fresh install on any device:
bash <(curl -fsSL https://gitee.com/moscowzk/sage/raw/master/install.sh)
```

What it does:
1. Clones repo to `$HOME/.sage` (or pulls if already cloned)
2. `npm install` (handles workspace hoisting for `packages/*`)
3. `npx tsc --noEmit` — compilation check
4. Creates `.env` template if missing (keys must be filled in)
5. Checks that `/tmp/sage_deploy_key` exists for git push

## SSH Key for Push

`/tmp/sage_deploy_key` — the SSH private key used for `git push origin master`. Must exist on every device.

## restart_sage.sh (Safe Restart)

```bash
bash $HOME/.sage/restart_sage.sh
```

Flow:
1. Record old `tsx.*Main.ts` PIDs
2. **Start new** — `npx tsx src/Main.ts` in background
3. Wait up to 15s for `适配器已就绪` signal in log
4. **Kill old** — all PIDs except new one and current bash

**⚠️ CRLF trap**: If `git pull` fetches a script with Windows line endings, `restart_sage.sh` fails with `$'\r': command not found`. Fix: `sed -i 's/\r$//' restart_sage.sh install.sh`
