---
name: linux-server-watchdog
description: >-
  Configure hardware watchdog + kernel panic-on-hang for Linux servers.
  Covers /dev/watchdog daemon, test-binary pitfalls, kernel.hung_task_panic,
  softlockup_panic, and Btrfs+RAID5 freeze diagnostics.
category: devops
triggers:
  - keywords: [watchdog, hung_task, softlockup, D-state, freeze, NAS重启, 卡死, 重启, 保活, 飞牛, 系统冻死]
    patterns:
      - "(系统|机器|nas).*(卡死|冻死|没反应|不响应)"
      - "watchdog.*(test-binary|不触发|没重启)"
      - "kernel.*(panic|hung|softlockup)"
      - "D.*state.*process"
      - "(Btrfs|RAID5).*(卡|死锁|deadlock)"
      - "怎么.*(重启|复活|救回)"
      - "服务器.*(挂了|不动了|远程.*重启)"
---

# Linux Server Watchdog & Freeze Recovery

## Architecture

A layered approach to ensuring a Linux server auto-recovers when it freezes:

```
Layer 3: Smart power strip / IPMI (physical power cycle)
Layer 2: Kernel panic-on-hang (hung_task_panic / softlockup_panic)
Layer 1: Hardware watchdog daemon (/dev/watchdog + test-binary)
Layer 0: User-space monitoring (systemctl, ping, custom scripts)
```

Layers 0-1 are user-space and fail when the filesystem freezes.
Layer 2 is kernel-level and works regardless of filesystem state.
Layer 3 is hardware-level and works regardless of OS state.

## Layer 1: Hardware Watchdog Daemon

### Install

```bash
# Install watchdog daemon
apt install watchdog
# or
yum install watchdog
```

### Configure `/etc/watchdog.conf`

```ini
# Device
watchdog-device = /dev/watchdog

# Timing
interval = 10           # How often to feed (seconds)
watchdog-timeout = 30   # Hardware watchdog timeout (seconds)

# Process priority
realtime = yes
priority = 1

# test-binary: optional external health check script
test-binary = /opt/scripts/wd_service_test.sh
test-timeout = 15

# Load thresholds (trigger if exceeded)
max-load-1 = 8
max-load-5 = 6
max-load-15 = 4

# Memory threshold (trigger if below)
min-memory = 50   # MB
```

### ⚠️ The test-binary Trap

**CRITICAL PITFALL:** The test-binary script itself may fail to execute during a freeze.

When the filesystem is in D-state (all processes stuck waiting for I/O):

```
watchdog daemon calls test-binary
  ↓
fork() succeeds (still in memory) but execve() blocks
  → script lives on disk → disk I/O frozen → execve never returns
  ↓
test-timeout (15s) kills the stuck child
  ↓
watchdog daemon got no valid exit code → continues feeding
  ↓
Hardware watchdog NEVER triggers
```

**Only these operations survive a frozen filesystem:**
- `ping` — kernel network stack, no disk I/O
- Kernel-level detection (`hung_task_panic`)

**test-binary rules to minimize freeze failure:**
1. Keep the script SHORT — one-liner `ping` checks only
2. Do NOT read or write any files (no counter files, no temp files)
3. Do NOT call `systemctl` (it uses D-Bus which can be affected by system-wide memory pressure)
4. Do NOT use `date` or any file-based operations
5. Best practice: make the test-binary a single shell command:
   ```bash
   # /etc/watchdog.conf
   test-binary = /bin/sh
   test-binary-arg = -c
   test-binary-arg = 'ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W3 223.5.5.5 >/dev/null 2>&1'
   ```

### Start watchdog daemon

```bash
systemctl enable watchdog
systemctl start watchdog
```

## Layer 2: Kernel-Level Panic-on-Hang (The Real Fix)

User-space watchdog fails during filesystem freezes. The kernel has built-in detectors that DON'T depend on user-space processes.

### Configuration

Create `/etc/sysctl.d/90-hung-task.conf`:

```ini
# Panic if any task is stuck in D-state for 120+ seconds
kernel.hung_task_panic = 1
kernel.hung_task_timeout_secs = 120

# Panic on kernel softlockup (spinlock held too long)
kernel.softlockup_panic = 1

# Panic on kernel hardlockup (NMIs not firing — CPU stuck)
# kernel.hardlockup_panic = 1   # enabled by default on most kernels

# After panic, wait N seconds then auto-reboot
kernel.panic = 10
```

Apply immediately:

```bash
sysctl -p /etc/sysctl.d/90-hung-task.conf
```

Verify:

```bash
sysctl kernel.hung_task_panic kernel.softlockup_panic kernel.hung_task_timeout_secs kernel.panic
# Expected:
# kernel.hung_task_panic = 1
# kernel.softlockup_panic = 1
# kernel.hung_task_timeout_secs = 120
# kernel.panic = 10
```

### How it works

```
Filesystem deadlock → processes stuck in D-state
  ↓ (120 seconds later)
Kernel hung task detector fires
  └─ Prints stack traces of ALL blocked tasks to console + journal
  └─ Triggers kernel panic
  └─ kernel.panic=10 → waits 10s → cold reboot
  └─ (Hardware watchdog also resets if panic takes too long)
```

This detects the EXACT freeze condition (D-state processes) at the kernel level, without depending on any user-space tool being able to run.

### Persist journald (Critical for Post-Mortem)

Without persistent journald, a power-cycle or panic erases all forensic evidence:

```bash
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
```

After this, the stack traces printed by `hung_task_panic` survive the reboot and are available via `journalctl -b -1`.

## Recovery Chain (All Layers)

```
                                   Time
                                   │
Freeze starts                      │
  ↓                                │
User-space tools stop working      │ ~0s
  ↓                                │
test-binary can't execute          │ ~10-15s (test-timeout)
  ↓                                │
watchdog daemon keeps feeding      │ (no valid exit → keep-alive)
  ↓                                │
Kernel detects D-state tasks       │ ~120s (hung_task_timeout_secs)
  ↓                                │
Kernel PANIC + prints stacks       │
  ↓                                │
Auto-reboot (kernel.panic=10)      │ ~130s from freeze
  ↓                                │
System fully operational again     │
```

Total downtime: ~2 minutes. No human intervention needed.

## Diagnostic Methodology (Live Freeze)

When a server is "alive" (lights on, fans spinning) but unresponsive, use this diagnostic sequence. The step at which you get a response tells you WHAT is frozen.

### Layer-by-layer probe

```bash
# Step 1: Check WireGuard / kernel network
wg show
# If WireGuard handshakes are recent (< 2min) → kernel IS alive
# If no recent handshake / interface down → full kernel freeze or power loss

# Step 2: Check ICMP (ping)
ping -c 2 <server>
# If ping works → kernel network stack alive, ARP/NDP working
# This means the freeze is in USER-SPACE, kernel is fine

# Step 3: Check TCP ports
timeout 3 bash -c "echo > /dev/tcp/<server>/22" 2>&1
# TCP handshake at kernel level. If it succeeds (SYN-ACK completed)
# but SSH hangs → SSHD is in D-state (user-space frozen)

# Step 4: Port scan
for port in 22 80 443 9090 8080 3000; do
  timeout 2 bash -c "echo > /dev/tcp/<server>/$port" 2>/dev/null && echo "PORT $port: ACCEPT"
done
# Multiple ports accepting TCP but not responding → confirmed user-space freeze

# Step 5: If WireGuard works, SSH through it
ssh -o ConnectTimeout=5 zk@10.0.0.x "echo alive"
# If ping works but SSH times out → user-space freeze confirmed
# If SSH works → not frozen, just network issue
```

### Interpretation

| Diagnostic Result | Conclusion | Action |
|---|---|---|
| WG handshake recent + ping works + TCP ACCEPT + SSH timeout | User-space D-state freeze | Layer 2 auto-recovers (hung_task_panic) |
| WG down + ping fails + no TCP response | Kernel panic or power loss | Layer 1/3 needed |
| SSH works but services hang | Partial service failure | Restart services |
| ICMP works, some TCP works, some fails | Partial freeze (specific mount) | Check mount points, storage pools |

## WireGuard as Diagnostic Tool

WireGuard is a kernel module. If the WG tunnel is still passing traffic during a reported freeze, it proves the freeze is **strictly user-space** (SSHD, Docker stuck in D-state). Kernel-level watchdog (hung_task_panic) will self-recover.

```bash
# SSH through WireGuard tunnel (bypass internet routing issues)
ssh zk@10.0.0.x
```

## test-binary: Inline Mode (Avoid Script-on-Disk)

For systems where the script file might fail to load during a freeze, use inline arguments:

```ini
# /etc/watchdog.conf — INLINE mode, no external script file
test-binary = /bin/sh
test-binary-arg = -c
test-binary-arg = 'ping -c1 -W3 8.8.8.8 >/dev/null 2>&1'
```

This eliminates the `execve()` block on a script file. Combined with Layer 2 kernel panic, this is the most reliable user-space fallback.

## Diagnosing Past Freezes

If journald was persistent, after reboot:

```bash
journalctl -b -1 --no-pager | grep -E 'task \S+:\d+ blocked' | head -10
journalctl -b -1 --no-pager | grep -i 'hung_task\|softlockup\|panic\|I/O error'
```

Look for patterns:
- **Btrfs transacti + mdX_raidY blocked** → Btrfs on RAID5/6 write deadlock (known issue)
- **NVMe errors + resets** → NVMe controller hang or thermal throttling
- **ext4 journal + kjournald blocked** → ext4 journal deadlock or disk failure
- **NFS + rpc_task blocked** → NFS server unreachable

### Btrfs+RAID5/6 Note

Btrfs on MD RAID5/6 has a known write-hole / transaction deadlock. Btrfs official docs warn against RAID5/6 for production. Symptoms:
- `btrfs-transacti` and `mdX_raid5` processes both stuck in D-state
- Kernel accepts TCP but SSH hangs (SSHD is D-state)
- WireGuard and ICMP still work (kernel network stack is independent)
- `journalctl -b -1` shows `task btrfs-transacti:N blocked for more than X seconds`

The only reliable fix for this specific case is to:
1. Move system root to a separate disk/partition (not on the RAID5 array)
2. Add kernel hung_task_panic as described above
3. Optionally migrate data off Btrfs+RAID5 to ZFS RAID-Z

## User-Space Fallback Script (Optional)

A simple ping-only test-binary that avoids filesystem I/O:

```bash
#!/bin/sh
# /opt/scripts/wd_service_test.sh
# watchdog test-binary — no filesystem I/O, pure kernel network stack
for target in 8.8.8.8 223.5.5.5 10.0.0.1; do
    if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
        exit 0
    fi
done
exit 1
```

This catches network-level failures while the filesystem is still healthy. It will NOT catch filesystem freezes (that's what Layer 2 is for).
