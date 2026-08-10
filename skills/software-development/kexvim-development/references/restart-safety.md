# Restart Script Safety — Why "Start First, Kill Later"

## The Problem: Self-Destruction

The original `restart_sage.sh` killed ALL processes matching `tsx.*Main.ts` FIRST, then started the new one:

```bash
pkill -f "tsx.*Main.ts"    # ← kills itself if called by sage!
sleep 2
# ... check + kill -9 ...
npx tsx src/Main.ts &       # ← new process starts after old ones are dead
```

**When sage calls this script from its agent loop** (via TerminalTool):

1. `pkill` kills ALL `tsx.*Main.ts` — including the running sage instance
2. The sage agent loop dies mid-flight
3. The shell script continues executing (separate bash process)
4. But none of the intermediate output reaches sage's agent — it's already dead
5. New sage starts, but the old session was interrupted

## The Fix: Start First, Kill Later

```bash
# 1. Record old PIDs
OLD_PIDS=$(pgrep -f "tsx.*Main.ts" || true)

# 2. Start new process
npx tsx src/Main.ts &
NEW_PID=$!

# 3. Wait for new process to be ready
for i in $(seq 1 15); do
  if grep -q "QQ Bot API v2 adapter ready" /tmp/sage.log; then
    break
  fi
  sleep 1
done

# 4. Kill old PIDs (excluding new PID and current bash)
for PID in $OLD_PIDS; do
  if [ "$PID" != "$NEW_PID" ] && [ "$PID" != "$$" ]; then
    kill -9 "$PID" 2>/dev/null
  fi
done
```

## Why This Works

| Step | What happens |
|------|-------------|
| Record old PIDs | Snapshot before any kill — safe to query |
| Start new process | Sage's agent loop continues to run |
| Wait for ready | New process grabs QQ WebSocket before old one dies |
| Kill old PIDs | Excludes `$NEW_PID` (don't kill what we just started) and `$$` (don't kill the script itself) |

## Verification

- Before restart: `pgrep -af "tsx.*Main.ts"` shows old process(es)
- After restart: same command shows exactly 1 set of processes (new PID)
- Log: `grep -a "runtime\|Loaded\|Recovered" /tmp/sage.log` shows session recovery
