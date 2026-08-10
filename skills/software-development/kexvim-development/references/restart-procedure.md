# sage 重启脚本

使用 `bash /opt/sage/restart_sage.sh` 安全重启 sage。

## 脚本做了什么

1. 记录所有当前 sage 进程 PID（排除脚本自身 bash）
2. 加载环境变量（优先 `/opt/sage/.env`，回退 `~/.hermes/.env`）
3. **先启动新 sage** — `npx tsx src/Main.ts` 后台运行
4. 等待最多 15 秒，检测日志中出现 `"适配器已就绪"` 确认上线
5. **再杀旧进程** — 排除新 PID 和当前 bash 后 `kill -9`

**关键修复（2026-07-22）**：
- 检测字符串从 `QQ Bot API v2 adapter ready` 改为 `适配器已就绪`（i18n 后日志中文化）
- **移除 `exit 1`** — 超时不再退出脚本，确保无论如何都会清理旧进程

**为什么先启后杀？** 旧版先杀后启，sage 在 agent loop 里调用重启脚本时，`pkill -f "tsx.*Main.ts"` 会把自己也杀死。新版脚本 sage 自身也能安全调用。

## 验证

启动后检查：
- `ps aux | grep "Main\\.ts" | grep -v grep | wc -l` — 应该只有 1 组进程树
- 日志 `/tmp/sage.log` 末行应为 `[BotAPI] 适配器已就绪: {name}`
- 发一条 QQ 消息确认只回复一次

## 已知问题

### 超时假阴性

偶发：进程实际已上线但脚本判定超时。此时脚本仍会执行旧进程清理（已修 exit 1）。检查方法：
```bash
ps aux | grep "Main\\.ts" | grep -v grep
tail -3 /tmp/sage.log  # 应有 "适配器已就绪"
```

如果已上线、旧进程已清 → 重启成功，忽略超时提示。

### 旧进程没杀干净

SIGKILL 后残留的子进程（如 `sh -c tsx Main.ts`）可能孤儿化。手动补杀：
```bash
ps aux | grep "Main\\.ts" | grep -v grep | sort -k9 -r | awk 'NR>1 {print $2}' | xargs -r kill -9
```

### 多实例重复回复

旧进程的 QQ WebSocket 连接保持活跃 → 一条消息 N 次回复。**始终确保只有一个 sage 进程树。**
