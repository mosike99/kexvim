---
name: china-proxy
title: China Proxy Setup
description: >-
  Set up a network proxy on Chinese cloud servers (mainland China) to bypass
  GFW restrictions for GitHub, HuggingFace, PyPI, Docker, and other blocked
  or throttled services. Covers sing-box (vmess/vless/shadowsocks), Go
  compilation from goproxy.cn, and Clash config conversion.
triggers:
  - keywords: [中国, 国内, 墙, GFW, proxy, 代理, GitHub拉不下来, CN服务器, China server, 国内服务器]
    patterns:
      - "github.*(拉不动|超时|连不上|timeout|blocked)"
      - "国内.*(代理|服务器|云)"
      - "(set up|setup|configure).*proxy.*(china|CN|国内)"
      - "subscription.*(clash|v2ray|vmess)"
      - "从中国.*(访问|下载|拉)"
      - "国内机.*科学上网"
      - "无法.*(github|huggingface|docker)"
category: devops
---

# China Proxy Setup

A systematic approach to setting up a network proxy on a mainland China cloud server.

## Architecture

```
server (CN)              proxy node (Japan/SG/US)
  ┌─────────┐    vmess     ┌──────────┐
  │ sing-box ├─────────────►│ 机场节点  │
  │ :7890    │   (TLS)     └──────────┘
  └────┬────┘
       │ HTTP/SOCKS5
       ▼
  git, curl, pip, apt via proxy
```

## Step-by-Step

### 1. Understand the Environment

Always test first what's actually blocked and what works:

```bash
# Check if GitHub is reachable
curl -sI --max-time 10 https://github.com
timeout 15 git ls-remote --heads https://github.com/NousResearch/hermes-agent.git
timeout 15 curl -sI --max-time 10 -L https://raw.githubusercontent.com

# Check proxy subscription link (often behind Cloudflare - expect blocks)
# China cloud IPs frequently get Cloudflare-blocked
```

**What usually works from China:**
- `api.github.com` — often reachable (API)
- `goproxy.cn` — Go module proxy ✅
- `pypi.tuna.tsinghua.edu.cn` — PyPI mirror
- `cdn.jsdelivr.net` — CDN, sometimes works
- `raw.githubusercontent.com` — sometimes works, unreliable

**What usually does NOT work:**
- `github.com` — heavily throttled
- `git clone/pull/ls-remote` via HTTPS — times out
- `raw.githubusercontent.com` for large files
- `huggingface.co` — blocked
- DockerHub — throttled

### 2. Get Proxy Config (Clash/V2Ray Format)

The user will have one of:
- **Subscription URL** — often Cloudflare-protected from CN IPs
- **Clash config file** (preferred) — `.yml` with `proxies:` section
- **Individual node info** — server, port, protocol, UUID/password

If the subscription URL is behind Cloudflare, ask the user to:
- Export the Clash config from their client app
- Or whitelist the server IP in their proxy panel
- Or provide individual node details

### 3. Compile sing-box from Source

Do NOT try to download pre-compiled binaries from GitHub — they time out.

```bash
# Required env vars for Chinese Go module proxy
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
export GONOSUMCHECK="*"
export GONOSUMDB="*"
export GOPROXY=https://goproxy.cn,direct

# Compile sing-box (supports vmess, vless, shadowsocks, trojan, etc.)
go install -v github.com/sagernet/sing-box/cmd/sing-box@latest

# Verify
ls -lh $GOPATH/bin/sing-box
$GOPATH/bin/sing-box version
```

**⚠️ Route rule note for sing-box 1.13.x:** `domain_keyword` rules are still supported. Use them as catch-alls for broad matching (e.g. `"domain_keyword": ["github"]` catches `github.com`, `raw.githubusercontent.com`, `githubassets.com`, etc.). But `domain_suffix` rules are preferred for precision. Rules are evaluated in order — first match wins.
- `go install github.com/MetaCubeX/mihomo@latest` FAILS — mihomo's go.mod has `replace` directives
- Checksum mismatch may occur (GFW tampering) → set `GONOSUMCHECK=*` and `GONOSUMDB=*`
- Must explicitly set `GOPROXY=https://goproxy.cn,direct` — git-based resolution times out

### 4. Create sing-box Config

**Use the conversion script** when the user has a Clash-format YAML config:

```bash
python3 scripts/clash-to-singbox.py < ~/downloaded-config.yml
```

This outputs sing-box JSON outbound entries for each proxy node. Then assemble them into the full config as shown below.

**sing-box 1.13.x inbound format:**
```json
{
  "inbounds": [
    {
      "type": "mixed",
      "tag": "proxy-in",
      "listen": "127.0.0.1",
      "listen_port": 7890
    }
  ]
}
```

⚠️ Do NOT use `address`/`port` (deprecated 1.11). Do NOT use `sniff`/`sniff_override_destination` (now route actions). Always use `listen`/`listen_port`.

**VMess outbound template:**
```json
{
  "type": "vmess",
  "tag": "node-name",
  "server": "server.example.com",
  "server_port": 443,
  "uuid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "security": "auto",
  "alter_id": 0,
  "tls": {
    "enabled": true,
    "server_name": "gw.alicdn.com",
    "insecure": true
  }
}
```

**Always include a `direct` outbound** for Chinese sites, and add route rules to bypass the proxy:
```json
{
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      {
        "outbound": "direct",
        "domain_suffix": [
          "proxyinfo.net",
          ".aliyun.com",
          ".tencent.com",
          ".qq.com"
        ]
      }
    ],
    "final": "主要节点",
    "auto_detect_interface": true
  }
}
```

### 5. Start & Verify

```bash
nohup $GOPATH/bin/sing-box run -c /path/to/config.json > /path/to/log.log 2>&1 &
# Or: terminal(background=true) from Hermes

# Verify
ss -tlnp | grep 7890
export https_proxy=http://127.0.0.1:7890
curl -sI --max-time 15 https://github.com
timeout 15 git ls-remote --heads https://github.com/NousResearch/hermes-agent.git
```

### 6. Traffic-Saving Mode: Smart Routing

For users with limited proxy traffic (e.g. 80GB/month), **do NOT route everything through the proxy**. Instead, make `direct` the default and only route specific blocked domains through the proxy.

**Config approach:**
```json
{
  "route": {
    "rules": [
      // Proxy service's own domains must go direct or they'll loop
      { "outbound": "direct", "domain_suffix": [
        "proxyinfo.net", "your-proxy-service.com"
      ]},
      // Only route blocked foreign domains through the proxy
      { "outbound": "美国1", "domain_suffix": [
        "github.com", "githubusercontent.com", "githubassets.com",
        "google.com", "googleapis.com", "gstatic.com",
        "huggingface.co", "hf.co",
        "stackoverflow.com", "docker.com", "docker.io",
        "pypi.org", "python.org",
        "arxiv.org", "openai.com", "anthropic.com",
        "npmjs.com", "npmjs.org",
        "gitlab.com", "bitbucket.org",
        "golang.org", "go.dev"
      ]},
      // GitHub keyword catch-all
      { "outbound": "美国1", "domain_keyword": ["github"] }
    ],
    "final": "direct",  // ⚠️ Everything else goes direct, NOT through proxy!
    "auto_detect_interface": true
  }
}
```

This means even when `http_proxy` is set, domestic sites (Baidu, QQ, Alibaba, Tencent Cloud) bypass the proxy entirely and don't consume quota. Test this:

```bash
export https_proxy=http://127.0.0.1:7890
# Blocked site → through proxy (consumes quota)
curl -sI https://github.com               # → 200, ~3-4s via tunnel
# Domestic site → direct (0 quota used)
curl -sI https://www.baidu.com            # → 200, ~0.05s direct
# No proxy → blocked as usual
unset https_proxy && curl -sI https://github.com  # → times out
```

### 7. Persist

⚠️ **Do NOT set global git proxy or bash env vars unless the user explicitly asks.** The smart routing approach means the proxy is only needed for specific commands. Global proxy env vars consume quota unnecessarily and can interfere with domestic services.

Instead, use on-demand proxy:

```bash
# Per-command proxy
git -c http.proxy=http://127.0.0.1:7890 clone https://github.com/...
curl -x http://127.0.0.1:7890 -LO https://github.com/...

# Or per-session env vars (domestic sites still bypass via smart routing)
export https_proxy=http://127.0.0.1:7890
# ... do GitHub things ...
unset https_proxy
```

If the user wants persistent env vars:
```bash
cat >> ~/.bashrc << 'EOF'
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export no_proxy=localhost,127.0.0.1,.aliyun.com,.tencent.com,.qq.com,cn,tencent-cloud.com
EOF
```

### 8. Auto-Start + Keepalive (systemd User Service)

To make sing-box survive reboots AND auto-restart on crash:

```bash
mkdir -p ~/.config/systemd/user
```

Create `~/.config/systemd/user/sing-box.service`:

```ini
[Unit]
Description=sing-box proxy (vmess smart routing)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/go/bin/sing-box run -c %h/.hermes/sing-box-config.json
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3
Environment=GOPATH=%h/go

[Install]
WantedBy=default.target
```

Then enable and start:

```bash
systemctl --user daemon-reload
systemctl --user enable sing-box
systemctl --user start sing-box

# Verify
systemctl --user status sing-box --no-pager
ss -tlnp | grep 7890
```

**Test keepalive:** Force-kill the process — systemd auto-restarts within 5s:

```bash
kill -9 $(pgrep sing-box)
sleep 5
systemctl --user status sing-box --no-pager  # should show "active (running)" with new PID
```

**Troubleshooting — "Failed to connect to bus: No medium found"**

This happens when running `systemctl --user` via SSH. The user session's DBUS socket isn't exported. Fix:

```bash
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
# Or use the system-level path if configured:
sudo systemctl restart sing-box  # if system-level service exists
```

Make sure systemd linger is enabled so user services survive logout:

```bash
sudo loginctl enable-linger $USER
```

**Before vs After:**

| | Before (manual) | After (systemd) |
|---|---|---|
| Reboot survival | ❌ Must re-start manually | ✅ Auto-starts on boot |
| Crash recovery | ❌ Silent death | ✅ Auto-restarts within 5s |
| Startup order | ❌ Race with gateway | ✅ After network-online.target |

### 9. Alternative: Use Chinese Mirrors Directly

| Service | Mirror |
|---------|--------|
| Hermes Agent repo | `https://cnb.cool/hermesagent-cn/hermes-agent-cn-mirror.git` |
| PyPI | `https://pypi.tuna.tsinghua.edu.cn/simple` |
| Go modules | `https://goproxy.cn` |

## Verification Checklist

- [ ] `sing-box check -c config.json` passes
- [ ] sing-box starts and `:7890` is listening
- [ ] `curl -I https://github.com -x http://127.0.0.1:7890` → `200`
- [ ] `git ls-remote` works through proxy
- [ ] Domestic sites via proxy → direct route, <0.1s response, no quota consumed
- [ ] **Autostart:** systemd user service enabled (`systemctl --user is-enabled sing-box`)
- [ ] **Keepalive:** systemd service has `Restart=on-failure` configured
- [ ] `systemctl --user status sing-box` shows `active (running)`

## Reference Files

See `references/session-config-example.json` for a complete sing-box config example from a working setup.
