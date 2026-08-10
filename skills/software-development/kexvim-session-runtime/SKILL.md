---
name: kexvim-session-runtime
description: "kexvim 会话/运行时调试：消息流、interim、卡死排查"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, session, runtime, debugging, interim, stall, gateway, message-flow, hermes-alignment]
    related_skills: [kexvim-session, kexvim-llm-provider]
---

# Kexvim Session & Runtime

## Message Flow

```
QQ Bot API WS → QQBotAPIAdapter.handleDirectMessage()
  → this.handler(pm)  (= Gateway.dispatch)
    → processMessage() → this.messageHandler(msg)  (= Main.ts handler)
      → AgentRuntime.chat() → agentLoop → invokeLLM
      → returns reply string
    → msg.sendReply(reply)  (final reply via QQ API)
```

## Session Guard — Serialization per Session Key

`Gateway.ts` serializes message processing per session key:

```
dispatch(msg):
  if no active session for sessionKey:
    setSessionGuard(sessionKey)
    processMessage(sessionKey, msg)  // fire-and-forget, NOT awaited
    return void
  else:
    queueTextDebounce() or mergeIntoPending()

processMessage(sessionKey, msg):
  flushTextDebounce(sessionKey)
  try:
    reply = await messageHandler(msg)
    if reply && msg.sendReply: await msg.sendReply(reply)
  finally:
    flushTextDebounce(sessionKey)
    if pending (from prior mergeIntoPending):
      setSessionGuard(sessionKey)
      processMessage(sessionKey, pending).catch(releaseGuard)  // cascade
    else:
      releaseSessionGuard(sessionKey)
```

**Critical rules:**
- `processMessage` is fire-and-forget from `dispatch` — NOT awaited
- The recursive cascade call in `finally` MUST `.catch(releaseGuard)`. Without this, any unhandled error in the cascade permanently locks the session (bot goes silent forever).

## GetMessagesAsConversation — FLAT Query Only (CRITICAL)

This is the MOST CRITICAL function. It extracts the conversation context that the LLM sees. **Must use flat ORDER BY id. NEVER walk parent_id chains.**

```sql
SELECT role, content, tool_call_id, tool_calls
FROM messages
WHERE session_id = ? AND entry_type = 'message' AND role IS NOT NULL AND active = 1
ORDER BY id DESC
LIMIT ?
```

- `AND entry_type = 'message' AND role IS NOT NULL` filter is ESSENTIAL — compaction/label/model_change entries (role=null) leak into context without it, corrupting the LLM's conversation view.
- `ORDER BY id DESC LIMIT 200` then `.reverse()` — gives the last 200 real messages in chronological order.
- The `active = 1` filter ensures only visible branch messages are included (future-proof; currently nothing sets it to 0).
- **DO NOT** change this to a parent_id chain walk. Chain walks fail because:
  1. Old messages lack parent_id (historical `appendMessage` didn't set it)
  2. Leaf-finding queries (`NOT EXISTS ... parent_id`) can return label/compaction entries instead of real messages
  3. No persisted `active_leaf_id` (unlike Pi Agent) means the leaf must be computed dynamically — fragile with mixed entry types

## Compression: persist messages to new session

`compressAndRotate()` creates a new session in DB and must ALSO persist compressed messages to it:

```ts
await this.sessionStore.create(childSession);
for (const msg of compressedMessages) {
  this.sessionStore.appendMessage(newSessionId, msg.role, content, {
    tool_call_id: msg.tool_call_id,
    tool_calls: JSON.stringify(msg.tool_calls),
  });
}
```

Without this, a restart after compression leaves the new session with 0 messages in the DB. The `getMessagesAsConversation` query returns empty, and the bot produces random/canned responses with no context.

### 1. Bot repeats same response / incoherent (上下文污染)

**Symptom:** Bot says the same thing every turn, ignores user input, mixes English/Chinese.

**Root cause:** Non-message entries (compaction, label with `role=null`) leaked into LLM context.

**Diagnosis:** Run SQL directly:
```sql
SELECT id, entry_type, role, substr(content,1,60)
FROM messages WHERE session_id = '<id>' AND active = 1
ORDER BY id DESC LIMIT 20;
```
Look for rows with `role=null` or `entry_type != 'message'`.

### 2. Bot goes silent / stuck (停住)

**Root cause 1:** Session guard never released — `processMessage` threw before `finally`, or cascade error without `.catch()`.

**Root cause 2:** Tool execution hangs — `handler.execute()` never returns. Fix: add timeout wrapper.

**Root cause 3:** Token expiry — `kexvim.log` shows `"token not exist or expire"` with 2000+ retry attempts.

### 3. Duplicate replies (重复回复 / 双份回复)

**Root cause 1:** ~~`statusCallback` 双发送~~ — 已过时。2026-08-01 起 interim 走 `statusCallback`（工具边界发完整句子）是**预期行为**；2026-08-02 起去重改为 Hermes 对齐的 `_deliveredInterimTexts` **集合查重**（同一 interim 文本只发一次，`_flushInterimSentences` 发送前查重/发送后记录），**不再做 final 前缀裁剪**。若仍重复，检查去重逻辑是否被绕过（见上方 Streaming 一节）。

**Root cause 2:** 跨轮 buffer 污染 — 每轮 while 迭代开头未清空 `_streamBuffer`，上一轮 tool_use 残留半截尾与新一轮输出拼接成垃圾发出去。修复：迭代开头 `this._streamBuffer = ""`。

**Root cause 3:** Two kexvim processes running (daemon + console). Check `ps` / Task Manager.

### 4. 插话必断 / 插话恒走 queue（2026-08-02，commit 8722b44）

**Symptom:** 任务进行中插话 → bot 不打断不 redirect，插话被排队等本轮结束（用户感觉"插话必断"）。

**Root cause:** Gateway busy 分支查 `ProgressTracker.getProgress(sessionKey)`，但 AgentRuntime 写进度用的是 **runtime session key**（`${source}:${chatId}`，`buildSessionKey` 格式）——**两处 key 格式不一致 → 恒查不到 → progressState 恒 undefined → 误走 queue 分支**，steer/redirect 分支永不可达。

**Fix:** Gateway 新增 `toRuntimeSessionKey(msg)` 换算（`msg.source ? \`${source.platform}:${source.chatId}\` : 旧格式 fallback`），查询与写入用同一 key。

**Pitfall（跨组件 key 对齐）:** 任何"查状态/写状态"跨组件（Gateway dispatch vs AgentRuntime）都要核对 key 格式是否同源。kexvim 里 session key 有三处口径：`AgentRuntime.buildSessionKey`（`source:chatId`）、ProgressTracker key、Gateway 的 `sessionKey` 变量（平台侧格式）。改动任一处必须同步其余。

**⚠️ 8722b44 只是第一层——真正的"插话必断"根因在 7dd317f（cancelled finishReason 陷阱）**

8722b44 修完 key 对齐后 redirect 能走到了，但插话仍可能"静默中断"（用户复现：19:54 连发两条消息 → `null↪ 已重定向` → 数据库只有一条**空 content 的 assistant** 落库，之后无任何消息）：

```
用户插话 → Gateway redirect() → _requestAbortController.abort()
→ OpenAIChatAdapter stream() catch (747行)：AbortError → yield { type: "done", finishReason: "cancelled" }
   ← 关键：abort 被转成"正常 done"，不是 error！
→ invokeLLM 收到 done/cancelled → 返回 { response: { content: "", error: null } }（fullContent 空）
→ agentLoop：llmError=null → 不走 _hasPendingRedirect→continue 分支（1357/1367行）→ 也走不到 llmError 分支
→ 1525 行落库空 content → 1528 "if (!cappedCalls.length) break" → 循环退出 → 空回复 = 静默中断
```

**Fix（7dd317f）:** invokeLLM 的 done 事件处理里，`finishReason === "cancelled" || "aborted"` 时 **throw ProviderError**（status 499）→ 让 agentLoop 走 llmError 分支：
- 有 pendingRedirect → `continue` 同轮重试（插话后任务继续）✅
- 用户 interrupt（`opts.signal.aborted`）→ `interrupted=true; break`（正确打断语义）✅

**通用教训:** 任何把 abort/取消**吞成正常响应**的 adapter 行为（`cancelled`/`timeout` 作为合法 finishReason 返回）都会让 agentLoop 上层误判为"无工具空轮"而静默结束。排查"任务静默中断/插话必断"时，先查 finishReason 归一化路径（`ChatCompletionHelpers` 的 knownReasons 集合里有 cancelled/timeout/error——它们被当作合法值处理，只有 7dd317f 的显式 throw 才让上层能区分）。

### 4b. 调试会话库判读规则（2026-08-02，从复现记录总结）

用户在本机复现后说"直接看聊天记录"——查 `data/kexvim.db`（node `DatabaseSync`，表 `sessions`/`messages`）：

```bash
node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/kexvim.db');
// 1. 最近的会话（按 updated_at）
db.prepare('SELECT id, session_key, source, chat_id, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 3').all()
// 2. 该会话最近消息（时间倒序）
db.prepare('SELECT id, role, substr(content,1,80) c, tool_name, finish_reason, timestamp FROM messages WHERE session_id=? ORDER BY timestamp DESC LIMIT 25').all(id)
"
```

**判读规则（重要）:**
- **空 content 的 assistant 消息是常态**——`appendMessage`（SessionStore.ts:542）只存 role/content/tool_call_id/tool_calls/token_count，**不存 reasoning/finish_reason/provider**，且每轮 LLM 调用都会落一条（`response.content || ""`）。所以空 assistant 消息本身**不是**中断标志。
- **中断标志 = 空 assistant 之后没有任何后续消息**（无工具消息、无最终回复）。正常轮次空 assistant 后面会跟工具消息或最终回复。
- **`null↪ 已重定向` 里的 "null" 是显示噪音**：ack 消息 `sendReply` 带 `replyTo=msgId` 引用块，QQ 客户端对无效/已失效 msg_id 的引用渲染成 `null`。不是内容 bug，不要据此推断插话文本丢了。
- 插话（第二条消息）**不进 messages 表**（走 redirect/steer 注入，不是落库），所以在 DB 里看不到插话内容——要结合 QQ 聊天记录判断。



### 4c. 静默中断断点定位 — DB 取证 + 进程时间三角（2026-08-03 实例）

完整取证查询（含 entry_type/tool_call_id/tool_calls 列）：

```bash
node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/kexvim.db');
// 断点附近消息全景（按 id 区间，断点 = 空 assistant 之后无任何后续）
db.prepare('SELECT id, entry_type, role, substr(content,1,120) c, tool_call_id, tool_calls, timestamp FROM messages WHERE session_id=? AND id BETWEEN ? AND ? ORDER BY id ASC').all(sid, lo, hi)
// 全库统计：role=tool 极少（实测 3430 assistant / 443 user / 2 tool）
db.prepare('SELECT entry_type, role, count(*) n FROM messages GROUP BY entry_type, role').all()
"
```

判读规则（对 §4b 的实测补充）:
- **interim 句子也落库**（带 content、间隔 2-4s），与空 assistant 交替出现：带文本 = 工具边界 flush 的完整句子（可据此重建 agent 当时在做什么），空 assistant = 一轮 LLM 调用（`response.content || ""`）。工具执行**不落库**（tool_calls 列实测全 null，全库 role=tool 仅 2 条）——别用 tool_calls 列证明工具是否执行，只能靠 interim 文本推断。
- **agent 绕圈前兆**：interim 连续多轮"还没找到 X"（08-03 实例：19 轮搜工具注册位置"DefaultToolRegistry 只是接口…"）→ 工具链路异常，agent 在自言自语，是中断前兆信号。
- **进程时间三角定位**（判断中断时刻跑的是哪个 commit 的代码）：① `git show <commit> --stat` 看修复提交时间；② dist 构建时间 + 进程启动时间（`wmic process where "name='node.exe'" get ProcessId,CreationDate,CommandLine`）；③ 中断时间 < 修复部署时间 → 中断发生在旧代码上（零保护零日志），**不能归咎于修复未生效**。
- 实测：08-03 08:52（北京）中断（3859 空 assistant 后 2h 无后续），崩溃保护 ef47ddd 10:50 提交 → 中断跑的是零保护旧代码，日志不可查 → "旧代码时代最后一次无痕中断"。
- **⚠️ 修复落地核实（08-03 实测纠偏）**：提交/构建 ≠ 生效。ef47ddd 10:50 提交 + dist 10:50 重编译，但 11:04 运行中进程仍是 8-02 20:05 启动的旧代码（`ps -o lstart -p <pid>`）——**编译只更新磁盘，不更新已运行进程的内存**。判定修复是否生效：进程启动时间 ≥ dist mtime，且 `ls -la /proc/<pid>/fd | grep kexvim.log` 能看到日志句柄（fd 佐证法：旧进程没打开 kexvim.log → 落盘逻辑没在跑）。确认前先 grep dist 符号 + 核对进程 lstart，别信提交时间。
- **max_iterations 迭代上限硬截断（fbd6fdf，08-03）**：长任务"跑着跑着自己断"的另一个断点 —— 旧默认 maxIterations=20（Config）/25（AgentRuntime 兜底），工具绕圈或任务过大触发迭代上限 → finalizer 硬截断。已归一为 90 对齐 hermes（委派子任务 50）。排查长任务中断：先查 `maxIterations` 当前值（`grep -n "maxIterations" src/Config.ts`），上限过低时 20 轮就断，与 finish_reason=length 无关。

### 5. 改 max_tokens 预算时 grep 所有调用点（2026-08-02，commit f1ca2cb）

修推理模型 max_tokens 时只改了 `AgentRuntime.ts` 的三处（主循环 req / finalizer / 压缩重试），**漏了 `src/inference/Agent.ts` 的 LLM 调用路径**（subagent/delegate 的独立 agent 也硬编码 4096）——f1ca2cb 才补上，且 `setLLM()` 切换 provider 时要同步更新 `_modelName`。

**Pitfall:** 改全局预算类常量（maxOutputTokens 等），先 `grep -rn "4096\|maxOutputTokens" src/ --include="*.ts"` 全量枚举调用点再动手；AgentRuntime 之外还有 `Agent.ts`、`LLMClient.ts`（guardian）、`SamplingHandler.ts`（MCP）。

### 6. 验证进程跑的是不是最新代码（stale dist 陷阱）

用户报"修复没生效"时，先确认运行中的 dist 是否包含最新提交——**远程有新 commit ≠ 本地进程在跑它**：

```bash
# 1. 对比 dist 构建时间 vs 最新 commit 时间
stat -c "%y" dist/dev.mjs | cut -d. -f1
git log -1 --format="%ci" <commit>
# 2. grep dist 确认新符号已进产物（比时间戳更可靠）
grep -c "toRuntimeSessionKey" dist/dev.mjs   # 0 = 旧 dist，需 rebuild + restart
# 3. 重启后确认新进程：pgrep -fa "dist/dev.mjs" 找 node PID，再 ss -tnp 确认 QQ ESTAB
```

2026-08-02 实例：8722b44（插话修复）已推送但 dist 是 01:12 构建（commit 01:34）——进程跑旧代码，用户报的"插话必断"正是旧 bug。rebuild + restart 后问题消失。

### 7. Compression + restart loses context → FIXED

`compressAndRotate()` creates a new session in DB but did NOT persist compressed messages to it. On restart, the new session had 0 messages.

**Fix:** After `sessionStore.create(childSession)`, iterate `compressedMessages` and call `appendMessage()` for each one. Now the new session has all compressed messages in DB across restarts.

## Streaming / Interim Messages

**⚠️ 注意：`kexvim-hermes-alignment` 技能 §8 仍是旧结论（"禁用 statusCallback / QQ 上 interim 是刷屏"）——该技能是手工维护、不可自动改。以本技能为准：QQ 上 interim 是「工具边界发完整句子」的预期行为，不要按 §8 去禁用。**

**结论（2026-08-01 修正，推翻旧结论）**: zk 在 QQ 上的真实行为是 **「工具边界发完整句子 interim + 最终回复」**，interim **不是**被抑制的。旧结论"QQ 无 stream consumer → already_streamed=True → interim 全部抑制、只发最终回复"是错的——zk 源码里 `_fire_stream_delta` 只在有 consumer 时累积文本，QQ 无 consumer → 不累积 → `already_streamed=False` → `_interim_assistant_cb` 真实发送完整句子。

### 正确实现（commit 6a3096d + 32405ee + e42316c 定稿）

`AgentRuntime.agentLoop()` 里：
1. **tool_use 边界** flush `_streamBuffer` 中**已完整的句子**（`_flushInterimSentences()`）：
   - 中英文句末标点切分（`。！？!?` 直接切；英文 `.` 需后随空格/换行/闭合符才切，避免 `3.14`、`e.g.` 误切——前字符字母数字且后随字母数字则跳过）
   - **半截尾部保留**在 buffer 等下一轮（不丢弃）
   - thinking 事件丢弃，不外发
2. **每轮（while 迭代）开头清空 `_streamBuffer`**——防止上一轮 tool_use 残留的半截文本与新一轮 LLM 输出拼接污染（kex 初版漏了这个，会发出"旧半截尾+新句子"的垃圾）
3. **interim 去重（2026-08-02 改为 Hermes 对齐方式，推翻此前的 final 前缀裁剪）**：
   - Hermes 源码定案：去重靠 `_delivered_interim_texts` **集合查重**（`run_agent.py` `_interim_text_was_delivered`/`_record_delivered_interim_text`，`conversation_loop.py:675` 每轮重置），**绝不做 final 前缀裁剪**（Hermes 没有这个，final 完整性由 already_streamed 决定，与 interim 无关）
   - kexvim 对齐：`_deliveredInterimTexts: Set<string>`，`_flushInterimSentences` 发送前查重（`replace(/\s+/g," ")` normalize 后精确匹配）、发送后记录、turn 开头重置
   - ❌ 不要实现 final 前缀裁剪——自创 hack，有丢文本风险（Hermes 注释原话：fails safe to a benign duplicate, never loses text）

### 流式截断恢复（finish_reason=length，commit e230bda + 3a43e87）

**先治本：推理模型 max_tokens 预算（028ad6b）**——kexvim 每轮 LLM 请求硬编码 `maxOutputTokens = 4096`，而推理模型（deepseek-v4-flash/deepseek-r1/o1/o3 系，`ErrorClassifier.isReasoningModel` 列表）的 **max_tokens 包含 reasoning/thinking token**：长思考把 content 预算挤到几十 token → 正文 20 字就触顶 `finish_reason=length` → 随机轮次中断（"为什么中断两次"根因）。Hermes 对照：`run_agent.py` `max_tokens: int = None` **默认不传**，API 用默认值（远大于 4096）→ 从不截断。kexvim 对齐：`_reasoningAwareMaxTokens` getter = 推理模型 16384 / 非推理 4096，三处统一（主循环 req、finalizer 优雅收尾、压缩重试 req）。**排查随机中断：先查 max_tokens 预算是否对推理模型够用，再谈截断恢复逻辑。**

`agentLoop` 内 `response.finishReason === "length"` 分支（对齐 Hermes `conversation_loop.py:2755-3076`）：
- **纯文本截断**：截断片段累积进 `truncatedParts` → 追加 continuation prompt（"Continue exactly where you left off"）重试，≤4 次；**重试成功必须拼接** `truncatedParts.join("") + continuation`（对齐 Hermes L5483-5484 `"".join(truncated_response_parts) + final_response`）——否则用户只收到后半段，前半段丢失
- **tool_call 截断**：参数可能不完整 → 提升 max_tokens（×2^n，封顶 32768）重试同一请求，**不拼接文本**（参数重试是全新生成）
- **两条重试路径重试前都清空 `_streamBuffer`**——防截断残尾拼入新输出（interim 混合）
- **4 次仍截断**：回滚 continuation 消息 + 返回拼接的 partial；tool_call 4 次仍 length → 拒绝执行不完整参数（`response.toolCalls = null`）

### 发送链路

`opts.statusCallback` → GatewayLauncher 的 `sendProgress` → `msg.sendReply`。interim 句子经此发出，final 由 `runtime.chat()` 返回值经 Gateway 发送。

### 已推翻的旧做法（不要再改回去）

- ~~"Do NOT pass statusCallback / 不要 flush mid-stream"~~ — 那是旧错误结论的产物，会让 bot "只会回结果"
- ~~"tool_use 边界 flush 全部累积文本"~~ — 会把半截尾一起发出去，造成"刚发的句子原封不动再发一遍"（用户 2026-07-31 反馈）
- ~~"QQ 上 interim 被抑制、对齐 zk 只发最终"~~ — zk 源码实测反证
- ~~"final 前缀裁剪去重（_interimSentThisTurn）"~~ — 自创 hack，Hermes 没有（Hermes 用 `_delivered_interim_texts` 集合查重，final 完整性与 interim 无关）；裁剪有丢文本风险，2026-08-02 已推翻

### 调试要点

- `_flushInterimSentences` 单测（切分/跨轮/去重）见会话记录；验证时用独立脚本复刻实现逻辑，不需要 import AgentRuntime
- 若发现"过程消息和最终回复内容重复"，检查去重逻辑是否被绕过（如 welcome 前缀拼接发生在去重之后、或走了 plannedContent 路径）
- **先 `git fetch` 再断言他人声称的提交/改动**——kex 的 commit 曾因未 fetch 被误判为幻觉；零结果≠不存在。fetch 用 HTTPS+token（`~/.config/gitee-release-cli-nodejs/config.json` 的 accessToken），SSH 的 deploy key 在 /tmp 已被重启清空
- **对齐 Hermes 必须逐行读源码**（`~/.hermes/hermes-agent/venv/lib/python3.12/site-packages/` 的 run_agent.py / conversation_loop.py / gateway/run.py）——kex 的实现"看起来对齐"不等于真对齐：interim 去重（集合 vs 裁剪）和截断恢复（拼接 vs 覆盖）两次都是对照源码才发现偏差
- 完整定稿（zk 源码证据链 + 切分规则 + 跨轮清理 + 去重实现）见 [references/qq-interim-messages-corrected.md](skill://kexvim-session-runtime/references/qq-interim-messages-corrected.md)

## 切会话对旧会话的影响（2026-08-10 验证定案）

用户问「切新会话对旧会话的影响」时直接给结论（代码链路 + 全库实测）：

**同进程**：`switchSession`（SessionMixin.ts:40）每次 chat 按 sessionKey（`source:chatId`）切换——key 变化时先 `sessionMessages.set(旧key, [...this.messages])` 存快照、再 `sessionMessages.get(新key)` 加载；`_chatQueue`（AgentRuntime.chat）串行执行 chat，切到新会话的消息排队等旧回合完成，不并发打断；**不同会话的 chat 不触发 redirect**（只有同会话 busyKey 插话才掐断，WebServer.handleChat L475-490）。→ 内存上下文不丢、不串，零干扰。

**重启后切回**：sessionInstances/sessionMessages 内存缓存为空 → ensureSession findByQuery 恢复 session → messages 空 → getMessagesAsConversation 从 DB 恢复（后处理闭合+合并，见 kexvim-session）→ 上下文合法，不再 400。**DB 数据原样保留，可随时切回。**

**web 端切会话语义**：切会话列表只发 `messages` 查询（只读看历史）；真正切回继续对话 = `chat` 带 sessionId（= chatId 稳定键，**不是**内部 session.id，session.id 仅用于历史查询）；新建话题 = chat 不带 sessionId → 新 chatId。

**验证方法（全库扫描）**：better-sqlite3 只读打开 DB → 遍历所有 sessions（按 updated_at DESC）→ 对每个会话复刻 getMessagesAsConversation（SQL LIMIT 200 + 闭合 + 合并）→ 断言 3 项：最大连续 assistant ≤ 1、孤立 tool = 0、工具链闭合。实测 21 会话 0 FAIL。**DB 复制用 backup API，勿直接拷文件**（带 WAL 时拷贝会缺未合并数据，kexvim.db 非 .sqlite）。

## CLI 会话命令（2026-08-12 实现：kexvim sessions / kexvim session <id>）

kexvim CLI 原本没有会话命令 → 新增两个（src/commands/SessionsKexvim.ts + SessionResumeKexvim.ts，CliHandler 注册 + HelpCommand 同步）：

- **`kexvim sessions`**：列出全部会话（前 8 位 id + title + source + 条数 + 更新时间，按 last_activity DESC）——数据源 = SQLite sessions 表
- **`kexvim session <前8位ID>`**：切换/恢复历史会话。**CLI 与 daemon 是不同进程，设计 = 一次性标记文件握手**：CLI 写 `data/session-switch.json`（`{sessionId, requestedAt}`）→ daemon 收到下一条消息时在 GatewayLauncher 消费（**位置 = source/chatId 会话解析之后、recover 之前**——初次插到 repair 路由前是错的，那时还没解析会话键）→ `resumeSession` 恢复该会话上下文 → 删除标记。**事件驱动、零常驻轮询**（不违反"不发明常驻文件/端口/通道"——一次性标记是 CLI→daemon 跨进程握手的唯一手段，用户点名要的功能）。⚠️ 测试注意：写标记后**下一条消息会被切走**（测试埋标记会劫持用户下一条消息，测完必须删 data/session-switch.json）
- **esbuild bundle 陷阱**：CLI 读 DB 时**动态 `require('node:sqlite')` 在 bundle 里失败**（esbuild 不支持动态 require 内置模块，`node dist/dev.mjs sessions` 无输出）——SessionStore 已是顶层 import node:sqlite，命令复用 SessionStore/顶层 import 即可，禁止动态 require（AGENTS.md 本也禁止）

## User Workflow Lesson: Study Evidence First

User zk prefers direct, concise answers — long architecture analyses waste time and frustrate. When the user reports a broken bot:

1. **ASK for the conversation log** (QQ chat transcript) — read the actual bot responses before touching code. If the user uploaded a file, read it first.
2. **Check the DB directly** — run the `getMessagesAsConversation` SQL to see what the LLM actually sees
3. **Check kexvim.log** — any errors, token issues, reconnect loops?
4. **Form a hypothesis from the evidence** before making changes
5. **Make ONE change at a time** and verify before proceeding
6. **If a fix doesn't work, REVERT IT** rather than analyzing why it should have worked. Dead-end approaches cost more time than rollbacks.
7. **Never ask questions the user already answered** in a file they sent. Read the file thoroughly.

**Critical warning: dangerous approaches that made things worse:**
- **Parent_id chain walk** for `getMessagesAsConversation` — broke completely on existing data. Flat ORDER BY id is the only safe approach.
- **Tool timeout as primary fix** — user explicitly rejected this as a band-aid. Address root causes first.
- **Architecture fusion without full scaffolding** — integrating Pi Agent's tree with Hermes' linear model requires ALL preconditions met (parent_id on every message, persisted leaf ID, branch switching mechanism). Half-measures break the bot.

**Communication pattern:** Answer first, explain later. When zk says "双份回复的问题" or provides a conversation file, investigate the specific issue — don't launch into architecture analysis. Be concise. Admit when a fix was a mistake and revert quickly.
