---
name: kexvim-platform
description: "平台适配器开发：Gateway 解耦、source 模型、注册"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, platform, adapter, gateway, source-model, registration]
    related_skills: [kexvim-platform-adapter, kexvim-development]
---

# Kexvim Platform Layer

给 kexvim 加新平台（Telegram/Discord/HTTP/WS/...）的完整模式。2026-08 起 Gateway 已从 QQ 专用解耦为平台无关，对齐 Hermes `event.source` 模型。

## 核心模型：PlatformMessage.source

每个 adapter 构造消息时填充平台无关元数据：

```ts
source?: SessionSource  // { platform, chatId, chatType, userId, threadId?, guildId? }
```

- `GatewayLauncher.createGatewayHandler` 优先用 `msg.source` 恢复会话（`sessionStore.recover({chatId, chatType, source: platform, userId})`）
- 无 source 时 fallback 旧 QQ userId 解析（`user:{id}` / `group:{gid}:user:{uid}`）——兼容未迁移的调用方

**DB 兼容铁律**：QQ adapter 填 source 时 chatId 必须保持旧解析形状，否则旧会话恢复失败：
- C2C：chatId = openid（不带 `user:` 前缀）
- group：chatId = `group:{group_openid}`（带前缀）
- 新平台自由定义 chatId 形状（如 api_server 用 user_id 裸值）

## 新增平台步骤（3 步）

1. **实现 PlatformAdapter 接口**（packages/platform/src/ 下新文件）：
   `name / start() / stop() / sendText() / sendTyping?() / setMessageHandler() / isConnected()`
2. **在 `GatewayLauncher.ts` 的 `ADAPTER_FACTORIES` 加一行**：
   ```ts
   telegram: (opts) => new TelegramAdapter({ token: opts["token"] as string, ... }),
   ```
   config 键为 snake_case，`Record<string, Record<string, unknown>>` 直接透传。
3. **config.yaml 加段**：
   ```yaml
   platform:
     enabled: true
     adapters:
       telegram:
         token: "..."
   ```

handler / notify / 启动通知零改动（已通用化：`adapters.find(...)` 而非硬绑 qq）。

## 无外呼通道的平台（api_server 模式）

HTTP 等请求/响应式平台没有主动外呼能力：
- **notify 循环必须跳过**：`if (adapter.name === "api_server") continue;`（GatewayLauncher 里已写死）
- 回复经 `sendReply` 异步返回 → 用**静默去抖窗口**合并多段文本（busy ack + 最终回复 = 单个响应）：
  ```ts
  sendReply: async (t) => { chunks.push(t); clearTimeout(timer); timer = setTimeout(() => resolve(chunks.join("\n")), settleMs); }
  ```
- 超时兜底（120s）要有内容就返回已收集内容，无内容才报错
- 零依赖优先：Node 原生 `http` 模块即可，不要引框架

**模板**：`templates/stateless-adapter.ts` — 无状态 adapter 的可复制骨架（含核心去抖合并模式），新 HTTP/WS/Webhook 平台从它改起。

## 有外呼通道的平台（Telegram 模式）

Push 型平台（Telegram/Discord/Slack）与 api_server 相反——有主动外呼通道，notify / .last_user / 启动通知直接复用，`ADAPTER_FACTORIES` 注册即可，GatewayLauncher 零改动。

**userId 格式与 QQ 对齐（关键设计决策）**：
- DM: `user:{chatId}`；群: `group:{chatId}:user:{uid}`
- 这样 `.last_user` 文件、notifyHandler、启动通知、sendText 解析**全部零改动复用**（sendText 只需解析 `user:`/`group:` 两种前缀）

**Telegram 实现要点**（零依赖，原生 fetch，不引 python-telegram-bot / node-telegram-bot-api）：
- `getUpdates` 长轮询：`offset = update_id + 1` 天然去重；`allowed_updates: ["message"]`；`timeout: 30`
- 断线退避 `BACKOFF = [2,5,10,30,60]`，成功重置；`error_code === 409` = 另一实例在轮询 → 停止并报错
- `getMe` 拿 bot username → 群聊 `@bot` 前缀剥离 + mention 过滤（默认只响应 `@bot` 或 `/` 命令）
- 回复 `sendMessage` + `reply_to_message_id` 引用原消息

**分块责任链（易错）**：Gateway 的 `splitNatural` 已先把长文本切成 <4000 的块 → adapter 收到的每段都 <4000 → adapter 自己的 splitter **不会**再加 `(i/n)` 编号。编号只由最终发送层对"单块仍超长"的内容添加（对齐 QQ truncateMessage）。测试断言用**内容拼接长度 = 原文长度**，不要断言存在 `(1/` 标记。

## 有状态 adapter 的无头测试（mock fetch）

Push 型 adapter 不用真 token——mock 拦截 fetch 验证轮询/映射/过滤逻辑：

```js
const realFetch = globalThis.fetch;
globalThis.fetch = (async (url: any, init?: any) => {
  if (String(url).includes("api.telegram.org")) {
    // 按 method 分发：getMe / getUpdates / sendMessage → 返回构造的 JSON Response
  }
  return realFetch(url, init);
}) as typeof fetch;
```

**OOM 陷阱**：mock 的 `getUpdates` 立即返回 → `pollLoop` while 空转刷爆 JS heap（实测 1.8GB FATAL OOM）。mock 必须模拟长轮询延迟：
```js
await new Promise(r => setTimeout(r, 50)); // 模拟长轮询，防空转
```
验证点：DM/群消息映射（userId + source 各字段）、@bot 剥离、无 mention 过滤、长文本分块内容无损、sendText 两种格式。

**参考**：`references/telegram-adapter.md` — Telegram 适配器完整实现细节（消息构造、测试用例清单）。

## 已注册平台（ADAPTER_FACTORIES，2026-08-01）

| key | 类 | 协议 | 测试 |
|---|---|---|---|
| `qq` | QQBotAPIAdapter | WS 直连 Bot API v2 | 真实环境 |
| `api_server` | HTTPAdapter | Node http，POST /chat | mock ✅ |
| `telegram` | TelegramAdapter | fetch 长轮询 getUpdates | mock ✅ 15 项 |
| `discord` | DiscordAdapter | ws Gateway + 心跳 + RESUME | mock ✅ 20 项 |
| `weixin` | WeixinAdapter | iLink HTTP 长轮询 + context_token 回显 | mock ✅ |
| `dingtalk` | DingTalkAdapter | stream WS + session_webhook 回发 markdown | mock ✅ |
| `feishu` | FeishuAdapter | tenant_access_token + WS 长连接 | mock ✅ |
| `ws` | WSAdapter | Node ws 服务端，双向 + push | mock ✅ 15 项 |

新平台对照：长轮询照 Telegram / WS 心跳照 Discord / token+WS 照 Feishu。

## WS 类 adapter（Discord/钉钉/飞书/WSAdapter）测试要点

- **`start()` 永不返回**：内部 `connectAndListen()` 只在断线时才 resolve → 测试 `await start()` 会挂死（timeout 124）。必须 `adapter.start().catch(...)` 后台跑 + sleep 数百 ms
- **mock WS server 要主动发握手帧**：飞书连上后服务端必须先发 `{type:2}` 握手帧，adapter 回 ack 才处理事件；Discord 发 `Hello(op=10)`。mock 不发则 adapter 停在握手前
- **busy ack 帧识别**：WSAdapter 用 Gateway i18n busy 文案的 emoji 前缀 `⏩↪⏳⚡` 正则区分 busy/reply 帧（不要用文本包含"忙"判断——busy 文案实际是"⏳ 已排队到下一轮 — {status}"）
- **鉴权拒绝测试**：服务端 close(4001) 后客户端 `open` 事件仍触发，断言要看 close code 不是连接失败

## 分平台 mention 过滤语义（易错）

- **Telegram/Discord/飞书**：有 mentions 数组（Discord `mentions[].id === botId`、飞书 `mentions[].id.open_id === botOpenId`、钉钉 `isInAtList`）
- **微信 iLink 无 mention 字段**：平台侧只推 @bot 的消息，adapter 侧过滤只能靠 `@bot 前缀剥离`（`text.startsWith("@accountId")`）或 `/` 命令开头；无 accountId 时无法判断，保守跳过
- 剥离 mention 用 `text.replace(/<@!?botId>/g, "")`（Discord）或前缀切片（微信）

## 完整 URL 回发平台（钉钉）

钉钉 `session_webhook` 是**完整 URL**（每条入站消息携带）→ 不能复用拼 apiBase 的请求 helper（会拼成 `apiBase + 完整URL` 的无效地址）。必须单独写直发完整 URL 的请求方法。回复 payload 对齐 Hermes：`{msgtype:"markdown", markdown:{title, text}}`。webhook 缺失时兜底 `sendToConversation` 机器人 API。

## 无头测试排障（headless smoke test）

**主线程 REPL 依赖 stdin**：后台跑 `node dist/dev.mjs` 时 stdin EOF → REPL 立即退出 → 杀掉所有 worker。保持 stdin 打开：

```bash
export KEXVIM_CONFIG=/path/smoke-config.yaml && tail -f /dev/null | node dist/dev.mjs
```

**shell 管道陷阱**：`VAR=x cmd1 | cmd2` 里 VAR 只作用于 cmd1（tail）！不 export 的话 kexvim 会加载真实 `<项目根>/data/config.yaml`（连上真 QQ 而不是测试配置）。必须 `export` 先行。

**首次运行拦截**：Bootstrap 检查 `userDataDir/.env` 是否存在，缺失则交互式"请输入 DeepSeek API Key"卡死。测试前：
```bash
mkdir -p tmp/smoke-data && cp data/.env tmp/smoke-data/.env
```

**worker 崩溃复现**：agent worker 静默 exit 时用独立脚本抓输出：
```js
const w = new Worker('/path/dist/dev.mjs', { workerData: { role: 'agent' }, stdout: true, stderr: true });
w.stdout.on('data', d => process.stdout.write(`[a-out] ${d}`));
w.stderr.on('data', d => process.stderr.write(`[a-err] ${d}`));
w.on('error', e => console.error('[worker error]', e));
w.on('exit', code => { console.log(`[worker exit] ${code}`); process.exit(0); });
```

**LSP 诊断可能是缓存误报**：patch 工具报的 TS 错误（如"Compactor 无导出"）在 `npx tsc --noEmit` 全绿时以 tsc 为准。

**execSync 阻塞事件循环**：工具实现（STT 的 curl、TTS 的 edge-tts）用 `execSync` 时，mock server **必须放独立子进程**（`spawn('node', ['-e', mockCode])` 等 MOCK_UP 再测），同进程 mock 会被 execSync 卡死，表现为"测试挂起/curl 连接拒绝"。参考 `src/tool/SpeechToTextTool.ts` 的 smoke 测试。

**先查断言再动实现**：smoke 测试的 FAIL 多数是断言写错而非代码 bug——数量断言写错（7 vs 8）、busy 文案没带 emoji 前缀、ready 帧在首条 chat 后才发、显式 setApiKey 优先级高于 env、adapter 字段在 `config` 下不在顶层。FAIL 时先核对这些再改 adapter。

## 验证流程

```bash
npx tsc --noEmit && npm run build:dev
```
- 独立冒烟（stub handler 模拟 runtime，验证 HTTP 层：health/chat/400/404/鉴权/并发）
- 端到端（真实 config + LLM key：curl 对话 + 跨轮会话记忆验证）
- session 落库检查：`sqlite3 .../kexvim.db "SELECT source, chat_type, chat_id, user_id FROM sessions LIMIT 5;"`
