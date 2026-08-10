# pkill Regex: Distinguishing Daemon from CLI Invocation

## The Problem

`kexvim.js restart` kills running kexvim processes via `pkill -f`. But the same
`node kexvim.js restart` command that does the killing must NOT kill itself.

## The Pattern (corrected 2026-08)

```bash
pkill -f "[^ ]*node .*/kexvim\.js($|\s)"
```

### Why `[^ ]*node ` instead of `^node ` (2026-08 fix)

The daemon is spawned with `process.execPath` (CliHandler / Watchdog daemonize),
so the real daemon cmdline is:

```
/abs/path/to/node <项目根>/kexvim.js
```

The old pattern `^node .*/kexvim\.js` anchors the match at the START of the
cmdline (`node ...`), but execPath-spawned daemons start with `/abs/path/...`.
The regex therefore NEVER matched them. Consequence observed in production:
every `kexvim.js restart` spawned an extra daemon without killing the old ones
→ 3 daemons accumulated in one day → duplicate QQ replies (the exact bug the
user kept hitting). `[^ ]*node ` matches both `node /abs/...` (PATH node) and
`/abs/node /abs/...` (execPath) because `[^ ]*` swallows the absolute path
prefix up to the node binary name.

### Matching table

| Process command line | Matches? | Why |
|---------------------|----------|-----|
| `node <项目根>/kexvim.js` (PATH-node daemon) | YES | `[^ ]*node ` = `node `, then `.*/kexvim.js` |
| `/abs/node <项目根>/kexvim.js` (execPath daemon) | YES | `[^ ]*node ` = `/abs/node `, then `.*/kexvim.js` |
| `/abs/node <项目根>/kexvim.js --daemon` | YES | `\s` matches space before `--daemon` |
| `node kexvim.js` (CLI, relative path) | NO | `[^ ]*node ` matches but `.*/kexvim\.js` needs `/` before `kexvim` — relative has none |
| `node kexvim.js restart` (CLI with arg) | NO | Same — no `/` before `kexvim.js` |

The `/` before `kexvim.js` remains the self-kill guard: the CLI is always
invoked with a relative script path, so it never matches.

### Why alternatives break

- `pkill -f "kexvim.js"` — kills everything including the running CLI
- `pkill -f "node.*kexvim"` — too broad, matches the CLI
- `pkill -f "node .*/kexvim"` — misses execPath daemons (cmdline starts with `/`, not `node `)

### TS-source escaping: `\\s` vs `\\\\s` (commit 8cb23ad, 2026-08-01)

The bash one-liner above is correct, but the real implementation lives in
`src/CliHandler.ts` as a TS string literal passed to `execFileSync("pkill", ...)`.
There are TWO escaping layers:

- TS source must be `"\\s"` (backslash backslash s = 2 chars) → string VALUE is
  `\s` → pkill ERE treats it as the whitespace class.
- If TS source is `"\\\\s"` (4 chars) → value is `\\s` → pkill ERE sees literal
  backslash + `s` → matches NOTHING in a real cmdline (killed no one, silently).

The old code only worked because the `$` end-anchor matched bare
`.../kexvim.js` with no trailing args. Once the restart spawn added `--daemon`
(see daemon-lifecycle-restart.md), every live instance had a trailing arg and
needed the `\s` branch — which was dead. Symptom: `restart` printed
"已在后台运行" but the previous daemon was still running, so instances
accumulated.

**Always smoke-test the compiled pattern**: `pgrep -f '<pattern>'` must list
the daemon before you trust the restart. If it lists nothing, check the
escaping, not the daemon.

### pkill self-kill when run from a wrapper shell

`pkill -f <pattern>` matches the FULL cmdline of every process — including the
`bash -c '...'` wrapper Hermes/CI shells use to run your command. If the pattern
string appears inside that wrapper's cmdline (e.g. the pattern text is part of
the command you typed), pkill -9 kills the shell running the pkill itself.
Symptoms: the terminal command dies with `exit -9` / no output, processes may
or may not have been killed. Mitigations:
- Run pkill as its own statement (or via `setsid`/separate call) so the wrapper
  doesn't embed the pattern.
- Verify with `ps -eo pid,args | grep <pattern> | grep -v grep` (grep's own
  cmdline contains the pattern → always filter `grep -v grep` / `grep -v bash`).
- `pgrep` for checks is safer than `pkill` for reads; only `pkill` when ready.

### Implementation note

The `pkill` lives in `src/CliHandler.ts` `handleCliCommand("restart")`. It is
followed by `spawn(process.execPath, [binPath, "--daemon"], ...)` — the child
MUST receive `--daemon` or it runs console mode and dies on `/dev/null` stdin
EOF (see SKILL.md "restart must spawn with --daemon").
