# VPS 日常维护 — Hermes 升级 & Gateway 管理

## Hermes 升级

```bash
pip install --upgrade hermes-agent
```

然后重启 Gateway（Hermes 是 systemd user service）：

```bash
systemctl --user restart hermes-gateway.service
```

### 从内部升级的注意事项

如果从 QQ bot 对话中触发升级（当前会话本身就在 Hermes Gateway 内跑），`systemctl restart` 会把自己杀掉。需要用 `execute_code` 或 `terminal(background=true)` 绕过：

```python
import subprocess, os, signal, time

# 先 SIGKILL 硬杀当前 gateway 进程
os.kill(3230604, signal.SIGKILL)  # PID 来自 `systemctl --user show --property=MainPID hermes-gateway.service`
time.sleep(3)

# 然后 systemctl start 重启
subprocess.run(['systemctl', '--user', 'start', 'hermes-gateway.service'])
```

或直接 `systemctl --user restart hermes-gateway.service` 从外部 shell 执行。

### 检查版本

```bash
pip show hermes-agent | grep Version
```

## Gateway 状态管理

| 操作 | 命令 |
|------|------|
| 查看状态 | `systemctl --user status hermes-gateway.service` |
| 查看日志 | `journalctl --user -u hermes-gateway.service -n 50 --no-pager` |
| 重启 | `systemctl --user restart hermes-gateway.service` |
| 停止 | `systemctl --user stop hermes-gateway.service` |
| 启动 | `systemctl --user start hermes-gateway.service` |
| 获取 PID | `systemctl --user show --property=MainPID hermes-gateway.service` |

## 升级后检查 Hermes 新功能

```bash
# 看 git log 最近版本
cd ~/.hermes/hermes-agent && git fetch upstream --tags 2>/dev/null
git log --oneline <old_tag>..<new_tag> | wc -l

# 按主题筛选
git log --oneline <old_tag>..<new_tag> | grep -iE "stream|agent.loo|tool.call|gateway|delegat|memory|skill"
```

对比版本时 pip 版本号与 git tag 对照：

| pip | git tag |
|-----|---------|
| v0.17.x | v2026.7.1 |
| v0.18.x | v2026.7.7 ~ v2026.7.14 |
| v0.19.0 | v2026.7.20 |

## 需要关注的主题（Sage 可借鉴）

升级后重点看：
- **Streaming 改进** — 是否有 interim text / tool_progress 新模式
- **Gateway 会话管理** — 轮次租约、投递账本
- **子代理** — 实时日志流、并行控制
- **Memory/Skills** — 缓存策略、凭证隔离
