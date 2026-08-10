# Gateway Message Flow — kexvim 消息路由陷阱

## Data Flow (QQBotAPIAdapter → Gateway → AgentRuntime)

```
QQ WS message event
  → QQBotAPIAdapter.handleDirectMessage / handleGroupMessage
    → PlatformMessage { userId, text, messageId, sendReply }
    → this.handler(pm).catch(...)          // fire-and-forget
      → Gateway.dispatch(msg)
        → setSessionGuard(sessionKey)       // 互斥锁
        → processMessage(sessionKey, msg)   // fire-and-forget
          → flushTextDebounce()
          → messageHandler(msg)             // = AgentRuntime.chat()
          → msg.sendReply(reply)            // 发最终回复
          → finally: drain pending → cascade or releaseGuard
```

## PlatformMessage.sendReply 是回复的唯一出口

`QQBotAPIAdapter` (line 651-664) 构造 `PlatformMessage` 时附带了 `sendReply` 回调，具体调用 QQ Bot API v2 的 `sendC2CMessage` / `sendGroupMessage`。Gateway 的 `processMessage()` 通过 `msg.sendReply(reply)` 发送最终回复。

**关键规则**：Adapter 本身不调用 `sendText` 来发送回复——回复全由 Gateway 通过 `sendReply` 回调处理。

## ⚠️ Pitfall 1: 重复回复 — statusCallback / interim 消息

AgentRuntime 的 `agentLoop` (line 863-893) 支持流式回调 `onStream`。每次工具调用前，累计的文本通过 `cb()` (statusCallback) 推送给用户。

**错误的做法**：把 `statusCallback` 绑定到 `msg.sendReply`：

```typescript
// Main.ts — 错误：导致每条消息都变 N+1 条回复
const sendProgress = (progressMsg: string) => {
  msg.sendReply!(progressMsg).catch(() => {});
};
const result = await runtime.chat(text, { statusCallback: sendProgress });
```

**结果**：
1. 每调一次工具 → `cb()` 发一条中间消息（如 "🔍 正在search..."）
2. Gateway 处理完再发最终回复
3. 一轮对话产生 N 条 interim + 1 条 final = 用户看到重复回复

**修复**：
```typescript
// Main.ts — 不传 statusCallback，仅发最终回复
const result = await runtime.chat(text, { ... });
```

只在 TUI/终端模式下启用流式回调。QQ 平台不传 `statusCallback`。

## ⚠️ Pitfall 2: 停住 — Cascade fire-and-forget 未捕获异常

`processMessage` 的 `finally` 块检测 `pendingMessages`，有 pending 消息时递归调用自身：

```typescript
// Gateway.ts — 不安全的 fire-and-forget 级联
this.processMessage(sessionKey, pending);  // 未捕获的异常 → guard 永远不释放
```

**错误路径**：级联链中某环抛出异常（如 LLM 认证失败、完整性问题）
→ `processMessage` 的 finally 块不执行
→ `releaseSessionGuard()` 不调用
→ session guard 永远保持 `active`
→ 后续消息全卡在 pending 队列
→ 用户看到机器人 "死了"

**修复**：
```typescript
this.processMessage(sessionKey, pending).catch((err) => {
  console.error("[gateway] cascade error:", err.message);
  this.releaseSessionGuard(sessionKey);  // 确保 guard 释放
});
```

## 消息流状态表

| 场景 | 行为 |
|------|------|
| 单条消息，无并发 | `processMessage()` → handler → sendReply → finally: releaseGuard |
| 快速连发多条 | 第1条进 processMessage，其余进 debounce → pending |
| 处理中又来新消息 | dispatch 发现 active session → debounce/merge 到 pending slot |
| 处理完发现 pending | cascade: setGuard + processMessage(pending).catch(releaseGuard) |
| 级联链正常结束 | 最后一个 processMessage 的 finally: no pending → releaseGuard |

## sessionKey 计算

```typescript
private getSessionKey(msg: PlatformMessage): string {
  return msg.groupId
    ? `${msg.groupId}:${msg.userId}`   // 群聊: 按群+用户隔离
    : msg.userId;                       // 私聊: 按用户隔离
}
```
