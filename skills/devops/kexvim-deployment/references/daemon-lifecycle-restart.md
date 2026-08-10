# Daemon Lifecycle & Restart Debugging (2026-08)

Root-caused on 2026-08-01: `kexvim.js restart` reported success but the bot was
dead / duplicating replies. Three independent bugs, all fixed in the same pass:

## 1. `--daemon` mode exited immediately (unref bug)

`WorkerLauncher.launchDaemon()` spawned watchdog/agent/guardian workers with
`w.unref()`. Unref'd workers do NOT hold the event loop → main thread returns →
process exits instantly. **Symptom**: `node kexvim.js --daemon` returns 0 with
an empty log and no process.

**Fix**: remove `w.unref()`. Worker threads themselves keep the process alive.

## 2. `restart` spawned the child without `--daemon`

`CliHandler.handleCliCommand("restart")` did
`spawn(process.execPath, [binPath], { stdio: "ignore", detached: true })` —
no `--daemon` flag. The child then ran console mode: main thread entered the
REPL, stdin was `/dev/null` (stdio ignore) → immediate EOF → `terminateWorkers()`
→ process exited. **Symptom**: restart prints `[✓] 已在后台运行 (PID: n)` but
the daemon is gone within seconds.

**Fix**: `spawn(process.execPath, [binPath, "--daemon"], ...)`.

## 3. pkill regex missed execPath-spawned daemons

See `references/pkill-regex-daemon-vs-cli.md`. Old `^node .*/kexvim\\.js` never
matched `/abs/node /abs/kexvim.js` → stale daemons accumulated → duplicate
replies. **Fix**: `[^ ]*node .*/kexvim\\.js($|\\s)`.

## 4. pkill pattern `\s` was double-escaped in TS source (8cb23ad)

After fixes 1–3, restart STILL didn't kill the old daemon. Root cause: the
pattern's whitespace class was written `\\\\s` in the TS source, so the string
VALUE passed to pkill was `\\s` = literal backslash + `s`, matching nothing.
It only worked before because the `$` end-anchor matched bare `.../kexvim.js`;
once `--daemon` was added every live instance carried a trailing arg and
needed the `\s` branch. **Fix**: `\\s` (2 chars) in TS source → `\s` value.
Smoke-test with `pgrep -f '<pattern>'` — it must list the daemon. Full detail:
`references/pkill-regex-daemon-vs-cli.md` (TS-source escaping section).

## Debugging sequence that found all four

1. `ps aux | grep kexvim` → 4 processes: 1 watchdog.sh wrapper + 3 daemons
   (all reparented to systemd, started minutes apart on the same day). Multiple
   instances = duplicate-reply source.
2. `node kexvim.js restart` output showed `[a] [BotAPI] 已就绪` — those lines
   came from the RESTART CLI's OWN workers (launchConsoleWorkers runs before
   CliHandler), not from the new daemon. The CLI's workers die with the CLI.
3. New daemon alive (11 threads) but `ls /proc/<pid>/fd | grep socket` = 0 →
   not connected. `ss -tnp | grep <pid>` → nothing.
4. `lsof kexvim.log` → log held by a 5-day-old `npm exec tsx src/Main.ts` tree
   (npm → sh → node → esbuild), NOT by any kexvim.js process. It kept spamming
   `token not exist or expire` (code 11244) reconnect attempts — that stale
   process was the only "live" thing writing the log, which misled diagnosis
   into thinking the token was broken. Kill the whole tree:
   `kill -9 <npm> <sh> <node> <esbuild>`.
5. `node kexvim.js` console probe with stdin held open
   (`sleep 30 | node kexvim.js`) → agent worker connects (`[a] [BotAPI] 已就绪
   sessionId=...`) → proves code + config + token are fine; the fault is in the
   daemon spawn path, not connectivity.
6. `node kexvim.js --daemon` in isolation → exits 0, empty log → pinpoints bug #1.

## Post-restart verification checklist

- `pgrep -af kexvim.js` → exactly ONE `.../node .../kexvim.js --daemon`.
- `ls -la /proc/<pid>/fd | grep socket` → at least one socket.
- `ss -tnp | grep <pid>` → ESTAB to `api.sgroup.qq.com:443` (or api.sgroup.qq.com).
- `<项目根>/data/kexvim.pid` → points at the live daemon PID (it can hold a
  dead PID after unclean kills — rewrite it).
- Old dev/tsx processes gone: `pgrep -af "tsx src/Main"` empty.

## Related

- `kexvim-architecture` skill — Worker Threads model, watchdog/agent/guardian roles.
- `kexvim-hermes-alignment` skill — QQ platform interim-message pitfall.
