# Telegram Adapter — 实现细节（2026-08 落地）

`packages/platform/src/TelegramAdapter.ts`，零第三方依赖（原生 fetch + Node http 无）。对齐 Hermes `plugins/platforms/telegram/adapter.py` 的消息映射语义，但用长轮询而非 webhook。

## 消息构造（DM 与群）

```ts
// DM（chat.type === "private"）
const pm: PlatformMessage = {
  userId: `user:${chatId}`,                 // 与 QQ 的 user:{openid} 对齐
  text: content,
  messageId: String(msg.message_id),
  source: {
    platform: "telegram",
    chatId,                                  // chat.id 字符串
    chatType: "dm",
    userId,                                  // from.id
    userName: msg.from.username || msg.from.first_name,
  },
  sendReply: async (t) => this.sendMessage(chatId, t, msg.message_id),
};

// 群（chat.type === "group" | "supergroup"）
userId: `group:${chatId}:user:${userId}`,
groupId: chatId,
source: { ...chatType: "group", chatName: msg.chat.title || msg.chat.username },
```

## 群聊过滤逻辑

```ts
if (isGroup && this.groupMentionOnly) {
  const isCommand = text.startsWith("/");
  const isMention = this.botUsername && text.startsWith(`@${this.botUsername}`);
  if (!isCommand && !isMention) return;      // 静默丢弃
}
// 剥离 @bot 前缀（对齐 QQ MENTION_REGEX）
if (isGroup && this.botUsername && content.startsWith(`@${this.botUsername}`)) {
  content = content.slice(mention.length).trim();
}
```

## 长轮询循环（含退避）

```ts
const updates = await this.api<Update[]>("getUpdates", {
  offset: this.offset,                        // update_id + 1，天然去重
  timeout: this.pollTimeout,                  // 默认 30，Bot API 上限 50
  allowed_updates: ["message"],
});
// 有消息 → backoffIndex = 0（连接健康）；错误 → BACKOFF[2,5,10,30,60] 递增
// error_code === 409 → 另一实例在轮询，直接停止（不要退避重试）
```

## sendText（notify 路径复用）

`notifyHandler` / 重启通知传来的 userId 是 `.last_user` 存的格式，与 QQ 相同：
`user:{chatId}` 或 `group:{chatId}:user:{uid}`。解析 `user:`/`group:` 前缀取 `parts[1]` 即 chatId。

## 分块责任链（重要）

- Gateway.processMessage 拿到 handler 返回的长文本后，**先**用 `splitNatural` 切成 <1500（Gateway 内部默认）的块，每块单独走 `sendReply`
- adapter 的 `sendReply` 再调自己的 `splitText`（MAX_MSG_LENGTH=4000）：此时单块已 <4000 → 不加 `(i/n)`
- 编号只在"adapter 收到的单块仍超长"时加（如直接调 sendText 的场景）

测试断言：`longSends.reduce((s,p) => s + p.text.length, 0) === 6000`（内容无损），而非 `includes("(1/")`。

## Mock 测试要点

- 拦截 `globalThis.fetch`，`url.includes("api.telegram.org")` 时按 method 分发，否则透传 realFetch
- mock `getUpdates` **必须加 `await new Promise(r => setTimeout(r, 50))`**——否则 pollLoop 空转，Node 堆飙到 1.8GB FATAL OOM
- 每条 update 入队 `updatesQueue.push({update_id, message: {...}})`，adapter 按 offset 消费
- 验证 15 项：DM 映射（userId/source platform/chatType/reply）、群映射（@bot 剥离/userId/chatType/chatName）、无 mention 过滤、长文本分块、sendText DM+群
