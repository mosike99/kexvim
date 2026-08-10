---
name: kexvim-platform-adapter
description: "新增平台适配器：接口、注册、mock 冒烟测试"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, platform-adapter, interface, registration, mock-test]
    related_skills: [kexvim-platform, kexvim-development]
---

# kexvim 平台适配器开发

给 kexvim 加新平台（Telegram/Discord/Slack/...）的标准流程。核心原则：**Gateway 平台无关，adapter 负责填充平台无关的会话元数据**（对齐 Hermes `event.source` 模式）。

## 架构（已定案，2026-08）

- `packages/platform/src/PlatformAdapter.ts`：`PlatformAdapter` 接口 + `PlatformMessage`（含可选 `source?: SessionSource`）
- `packages/platform/src/SessionContext.ts`：`SessionSource` 类型 + `SessionContextHelper.PLATFORM` 常量
- `src/GatewayLauncher.ts`：`ADAPTER_FACTORIES` 工厂注册表 + `registerAdapters()`；handler 优先用 `msg.source` 恢复会话，无则 fallback 旧 QQ 解析
- `packages/platform/src/Index.ts`：导出 adapter + config 类型

## 已注册平台（ADAPTER_FACTORIES，2026-08）

| key | 类 | 协议 | 测试 |
|---|---|---|---|
| `qq` | QQBotAPIAdapter | WS 直连 Bot API v2 | 真实环境 |
| `api_server` | HTTPAdapter | Node http，POST /chat | mock ✅ |
| `telegram` | TelegramAdapter | fetch 长轮询 getUpdates | mock ✅ 15 项 |
| `discord` | DiscordAdapter | ws Gateway + 心跳 | mock ✅ 20 项 |
| `weixin` | WeixinAdapter | iLink HTTP 长轮询 + context_token | mock ✅ |
| `dingtalk` | DingTalkAdapter | stream WS + session_webhook 回发 | mock ✅ |
| `feishu` | FeishuAdapter | tenant_access_token + WS 长连接 | mock ✅ |
| `ws` | WSAdapter | Node ws 服务端，双向 + push | mock ✅ 15 项 |

新平台模式照 TelegramAdapter（长轮询）/ DiscordAdapter（WS）/ FeishuAdapter（token+WS）。

## 新平台步骤

1. **创建 `packages/platform/src/XxxAdapter.ts`**，实现 `PlatformAdapter`：
   - `readonly name` — 平台标识（用 `SessionContextHelper.PLATFORM` 的命名，如 `"telegram"`、`"api_server"`）
   - `start()/stop()/isConnected()` — 连接生命周期
   - `setMessageHandler(handler)` — 保存 Gateway 注入的 dispatch
   - `sendText(userId, text)` — 主动外呼（notifyHandler/重启通知用；无外呼通道的平台如 HTTP 可仅 log）
   - `sendTyping?(userId)` — 可选，仅支持的平台

2. **消息构造规则**（关键，必须对齐）：
   - `userId` 格式与 QQ 一致：DM = `user:{chatId}`，群 = `group:{chatId}:user:{senderId}` → `.last_user`/notify 机制直接复用
   - `source` 填平台无关元数据：`{ platform, chatId, chatType: "dm"|"group", userId, userName?, chatName? }`
   - `sendReply` 回调发回当前会话（带 reply_to_message_id 引用原消息更佳）
   - 长文本按自然边界分块（Gateway 已用 splitNatural 切，adapter 只对超长块补 (i/n) 编号）

3. **注册**：`GatewayLauncher.ts` 的 `ADAPTER_FACTORIES` 加一行（config key → 构造），`Index.ts` 导出

4. **notify/重启通知**：无需改 — `GatewayLauncher` 自动跳过 `name === "api_server"`，其余 adapter 用第一个外呼平台

## 测试（无真实凭证也可全量验证）

写 `tmp/smoke-xxx.ts`：
- **mock API**：用 `globalThis.fetch` 拦截（Telegram 模式）或本地 http server；**getUpdates 类轮询 mock 必须加 50ms 延迟**，否则测试进程空转 OOM（heap 1.8GB 爆掉）
- 断言项：DM/群消息映射、userId 格式、source 字段、@bot 剥离/过滤、长文本分块内容无损（拼接长度相等）、sendText 两种格式
- 运行：`npx esbuild tmp/smoke-xxx.ts --bundle --platform=node --format=esm --outfile=tmp/smoke-xxx.mjs --external:ws --external:better-sqlite3 && node tmp/smoke-xxx.mjs`

## 验证命令

```bash
cd /home/ubuntu/<项目根>
npx tsc --noEmit            # 类型检查
npm run build:dev           # esbuild 编译 dist/dev.mjs
```

## 参考

- 参考实现：`packages/platform/src/TelegramAdapter.ts`（长轮询）、`HTTPAdapter.ts`（请求/响应）
- Hermes 对照：`~/.hermes/hermes-agent/venv/lib/python3.12/site-packages/plugins/platforms/<platform>/adapter.py`、`gateway/session_context.py`
- 端到端测试：`KEXVIM_CONFIG=<tmp-config> node dist/dev.mjs`，配置只开目标 adapter 避免连真实 QQ；注意 `VAR=x cmd1 | cmd2` 中 VAR 只作用于 cmd1（用 `export` 再跑管道）
