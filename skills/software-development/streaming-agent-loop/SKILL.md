---
name: streaming-agent-loop
description: Implement and debug LLM streaming agent loops with tool calling. Covers streaming SSE parsing, tool_call_id passthrough, interim text flushing, zero-chunk guard, finish_reason ordering, logical boundary splitting, and content sanitization for providers like DeepSeek, OpenAI, etc.
tags: [streaming, tool-calling, agent-loop, sse, deepseek]
---

# Streaming Agent Loop Implementation

Implementing a streaming agent loop where the LLM returns content and tool calls incrementally over SSE (Server-Sent Events).

## Architecture Overview

```
User Message
  → agentLoop (while loop)
    → invokeLLM (streaming path)
      → LLM.stream(req) [AsyncGenerator]
        → SSE parser (chunk by chunk)
          → _parseStreamChunk(content)
          → [DONE] → finalize tool calls
      → onStream callback (interim text)
      → return { content, toolCalls }
    → execute tools (for each tool call)
    → push tool results → repeat
  → extractContent → return final
```

## Critical Patterns

### 1. Tool Call ID Passthrough (MUST PRESERVE LLM IDs)

When the LLM returns tool calls via streaming SSE, each chunk carries an `id` (e.g. `call_xxxx`). **This ID must be preserved all the way through**:

```
SSE chunk → streamToolCallAssembler.addDelta(index, tc)
  → partial.id += delta.id       ✓ PRESERVE
  → partial.name += fn.name      ✓ PRESERVE
  → partial.args += fn.arguments ✓ PRESERVE

[DONE] → finalize()
  → Return { type: "tool_use", name, args, id }  ← MUST include id

invokeLLM → response.toolCalls = [{ id: tc.id, name, arguments }]
  → Agent loop assistant message: tool_calls id = tc.id  ✓
  → Tool result message: tool_call_id = tc.id             ✓
```

**Why**: DeepSeek (and OpenAI) require the `tool_call_id` in tool response messages to match the `id` in the assistant's `tool_calls`. If you replace with custom IDs (`tool_Date.now_i`), the API rejects with:
> "An assistant message with 'tool_calls' must be followed by tool messages responding to each 'tool_call_id'"

**Pitfall**: `StreamToolCallAssembler.finalize()` originally only returned `{ type, name, args }` — the `id` was accumulated by `addDelta` but **dropped** in `finalize()`.

### 2. Finish Reason Ordering (DON'T yield done from _parseStreamChunk)

SSE chunks can carry `finish_reason` in the choice object BEFORE the `[DONE]` marker arrives:

```json
{"choices": [{"delta": {"tool_calls": [...]}, "finish_reason": "tool_calls"}]}
```
Then later:
```
data: [DONE]
```

**Rule**: Never yield `{ type: "done" }` from `_parseStreamChunk`. Instead:
1. Save the `finish_reason` to a field (`_streamFinishReason`)
2. Let the `[DONE]` handler call `finalize()` then yield done with saved reason
3. If stream ends without `[DONE]` (reader returns done), yield done with saved reason in the post-loop code

**Why**: If `_parseStreamChunk` yields `done` on `finish_reason`, the consumer (`for await`) breaks immediately. The `[DONE]` handler's `finalize()` tool_use events and the final `done` event are never consumed by the caller.

### 3. Empty Content is Still Content (Zero-Chunk Guard)

The first SSE chunk in a streaming response is a role-establishment chunk:

```json
{"choices": [{"delta": {"role": "assistant", "content": ""}, "finish_reason": null}]}
```

**Rule**: Use `typeof delta.content === "string"` instead of `if (delta.content)`.

**Why**: `if (delta.content)` treats `""` as falsy, so the chunk yields NO events. `hadContent` stays `false`. When `[DONE]` arrives, `!hadContent && !hadToolCalls` → true → zero-chunk guard fires with error.

When the first chunk yields an empty text event:
- `hadContent = true` (from the for-loop check)
- `fullContent += ""` (no actual content added)
- `[DONE]` guard passes → `finalize()` runs → tool_use events are yielded
- Prevents `extractContent()` from falling back to old session messages (which causes "答非所问")

### 4. Interim Text Flushing — Two Approaches

Choose based on platform capability:

**Approach A (EDIT-capable platforms: Telegram, Discord, Slack)**: Progressive edit via `stream_consumer` — send one message, edit in place with each delta. No splitting needed. Configured via `editMessageText` API.

**Approach B (SEND-ONLY platforms: QQ OneBot, WeChat)**: Flush at tool boundaries. Accumulate text during streaming, send only when tool_use event fires (matching Hermes `interim_assistant_callback`). Final response (no tool calls) sends as one message via handler return.

```
Kexvim QQ (OneBot) — final approach:
  onStream text → accumulate only (no send)
  onStream tool_use → flush entire buffer as one message
  stream end + no tool calls → buffer stays, handler returns text, Gateway sends once
```

**Approach C (deprecated — boundary splitting)**: Previous approach used `_findLogicalBoundary()` which splits at sentence/paragraph boundaries every 200ms. Removed for Kexvim QQ because:
- Boundary detection inevitable produces wrong splits (cut mid-sentence)
- Platform doesn't support edit, so each split creates a permanent separate message
- Hermes on QQ doesn't do boundary splitting either (uses `_emit_interim_assistant_message` at tool call completion)

保留原文档中 boundary splitting 的参考实现供其他平台参考。

**Why 0.3 threshold**: The boundary must be in the later part of the buffer (past 30%) to avoid sending micro-chunks. If the boundary is in the first 30%, the text is too short to split meaningfully — keep accumulating.

**Always clear the buffer after flushing** to prevent the same text from being re-sent by tool_use handler or final response path.

**Throttle by platform**:
- **QQ/Telegram messaging**: 200ms — fast enough to feel real-time, slow enough to avoid flooding with per-character messages
- **CLI/TUI**: 1000ms — slower rate is fine because text updates the same line progressively

**User preference**: Do NOT send tool-progress indicators (`🔍 正在xxx...` / "searching..."). Users find them distracting and they flood the chat. The final response includes everything. Only flush actual LLM thinking/analysis text.

Config idea: `display.tool_progress` (boolean, default false) — if supported by the platform, this preference could become user-configurable.

### 5. Empty Content Fallback

When `invokeLLM` returns empty content (`content: ""`), `extractContent(messages)` searches backwards for the last non-empty assistant message. If previous session messages exist, it returns OLD content, causing "答非所问".

**Guard**: Ensure the streaming path always returns proper content or let the agent loop handle empty responses explicitly.

### 6. Diagnostic Counters: Trace Where Data is Lost

When tool calls or content are silently missing, the most effective debug technique is **adding counters at each stage** of the pipeline to pinpoint exactly where data stops flowing.

**Pattern**: Systematically add a counter at each data-flow boundary:
1. **SSE parser** — did the delta chunks with `tool_calls` arrive?
2. **StreamToolCallAssembler** — did `addDelta` get called? How many partials after accumulation?
3. **`finalize()` output** — how many `tool_use` events did it produce?
4. **`invokeLLM` loop** — how many `tool_use` events did `for await` consume?
5. **Agent loop** — how many tool calls did `extractToolCalls` find in the response?

When the count drops between stage X and stage Y, the bug is in that boundary. Common drops:
- `addDelta` called but `finalize()` returns 0 → partials didn't accumulate (format mismatch)
- `finalize()` returns N but `invokeLLM` sees 0 → early `break` before finalize ran
- `invokeLLM` returns N but `extractToolCalls` finds 0 → response.toolCalls format mismatch

### 7. When Tool Calls Disappear After a Change: DON'T Blame the Model

When a user reports that tool calls stopped working after a change (even a cleanup/refactor change), **never assume the model "chose" not to call tools**. The model does not spontaneously stop using tools it was previously using.

**Correct debugging order:**
1. **Revert first** — the fastest way to confirm the change caused the regression is to revert it. Do NOT add diagnostic counters first. The user's explicit feedback: "直接把那次改动内容还原，如果恢复正常就能确认问题了" (just revert that change, if things go back to normal then we've confirmed the issue). Only after reverting confirms the regression should you investigate the root cause.
2. **Present evidence first** — when reporting findings, lead with what you actually saw (command output, log lines, file contents — the raw evidence), NOT what you concluded. The user wants to see the same evidence you see. Only after presenting the evidence should you explain what it means.
3. Assume the code is broken — every time, without exception
4. Diff the change that triggered the regression — even if it seems unrelated (removing debug logs, changing an `if` condition, rearranging code)
5. Check if the streaming path is actually being used — `agent.onStream` being set switches `invokeLLM` from `chat()` (non-streaming) to `stream()` (streaming). These are different code paths that handle tool calls differently.
6. Add diagnostic counters only after reversion doesn't help — they are the second line of investigation, not the first.

**User's exact words when this debugging mistake was made repeatedly**:
- "不要告诉我模型自那以后全部选择不调用工具" — Don't tell me the model chose not to call tools after that.
- "你分析的到底对不对？你看看你自个儿的回复，每次都跟多条的啊" — Is your analysis even right? Look at your own replies! They come in multiple messages.
- "我不太懂，之前为什么是好的，从你改了工具调用输出后坏的" — I don't understand, it was fine before, it broke after you changed the tool output handling.
- "这么多轮都这样，你不要告诉我模型自那以后全部选择不调用工具" — This has been going on for so many rounds. Don't tell me the model chose not to call tools after that point.

**Historical scenario**: The user reported tool calls stopped after a "cleanup" commit that only removed debug logs. The real root cause was an EARLIER commit that switched `invokeLLM` from `chat()` to `stream()` — the `streamToolCallAssembler` didn't handle DeepSeek's flat format. The cleanup commit was blamed because it was most recent. **Lesson**: when investigating a regression timeline, check ALL commits in the window, not just the most recent one. The triggering change may have been several commits earlier, with the symptom only becoming visible after a subsequent cosmetic change.

**Evidence-first reporting**: When reporting findings to the user, lead with what you actually saw (command output, log lines, file contents — the raw evidence), not what you concluded from it. The user wants to see the same evidence you see. Only after presenting the evidence should you explain what it means. This was the user's most strongly reinforced debugging preference in this session.

The most common causes of "tool calls stopped" after a change that didn't touch the tool execution code:
- Streaming path being used instead of non-streaming `chat()` — the `streamToolCallAssembler` may not correctly handle DeepSeek's SSE format, while `chat()` with `normalize_response` works
- A seemingly unrelated `if` condition change caused events to be skipped
- An exception in a callback (`onStream`, `statusCallback`) was caught silently but prevented normal flow
- A log removal accidentally removed functional code (inline `console.error(...)` that was fused with logic)

### 8. Streaming vs Non-Streaming Tool Call Extraction

**Critical finding**: The streaming SSE path (`this.llm.stream()` → `streamToolCallAssembler` → `finalize()`) may NOT correctly extract tool_calls from DeepSeek's SSE format, even when the non-streaming path (`this.llm.chat()` → `parseResponse()` → `normalize_response()`) works perfectly.

**THREE distinct failure modes** (not just one):

| # | Issue | Root Cause | Fix |
|---|-------|------------|-----|
| 1 | Flat format | `delta.{name, arguments}` instead of `delta.function.{name, arguments}` | `addDelta` flat format fallback |
| 2 | **No `delta.tool_calls` at all** | DeepSeek doesn't emit incremental tool call deltas | Check `choice.message?.tool_calls` in `_parseStreamChunk` |
| 3 | `Promise.all` anti-pattern | Parallel stream+chat = 2x API cost, not Hermes-aligned | Fix #2 so ONE stream call suffices |

**⚠️ Real-world finding (2026-07-23)**: For DeepSeek streaming, failure mode #2 is the ONLY relevant mode. The `addDelta` flat format fix (failure mode #1) was **unnecessary** — DeepSeek never sends `delta.tool_calls` at all, flat or nested. The flat format only applies to the non-streaming `chat()` response, which `normalize_response()` already handles. Adding it to `addDelta` was **画蛇添足** (adding unnecessary things). See section "Failure Mode 2: No `delta.tool_calls` at All" for the correct fix.

#### Failure Mode 2: No `delta.tool_calls` at All

**This is the most fundamental failure mode and was discovered last, after the flat-format fix was already in place.**

DeepSeek's streaming API does NOT always emit `delta.tool_calls` incrementally across chunks. Instead, the **complete tool calls** arrive in the LAST SSE chunk's `message.tool_calls` field — the same format used in non-streaming responses:

```json
// Last SSE chunk (before [DONE]):
{"choices": [{"delta": {}, "message": {"tool_calls": [
  {"id": "call_xxx", "name": "read_file", "arguments": "{\"path\": \"/tmp/test\"}"}
]}, "finish_reason": "tool_calls"}]}
```

Notice: `choice.delta.tool_calls` is absent (delta is empty `{}`). The tool calls live at `choice.message.tool_calls`. Kexvim's `_parseStreamChunk` only checked `delta`, so it silently missed them.

**Diagnosis**: In `stream()`'s SSE loop, `choice?.delta?.tool_calls` is NEVER truthy for the entire run. `hadToolCalls` stays false. `finalize()` returns empty. The `[DONE]` handler yields no `tool_use` events. **But `choice?.finish_reason` = "tool_calls"** — confirming the LLM DID generate tool calls, they just weren't in the expected location.

**Fix**: Add `message.tool_calls` detection to `_parseStreamChunk`:

```typescript
// DeepSeek sends final tool_calls in message.tool_calls (not deltas).
// Feed them into streamToolCallAssembler so finalize() yields them.
if (choice.message?.tool_calls) {
  const msgToolCalls = choice.message.tool_calls as Array<Record<string, unknown>>;
  for (let i = 0; i < msgToolCalls.length; i++) {
    this.streamToolCallAssembler.addDelta(i, msgToolCalls[i] as Record<string, unknown>);
  }
}
```

This feeds the complete tool calls into the assembler at index 0, 1, 2... During `[DONE]`, `finalize()` yields these as `tool_use` events. The `addDelta()` method handles both nested and flat formats for `message.tool_calls` entries.

**Why Hermes (Python) works**: The OpenAI Python SDK's `stream()` internally accumulates BOTH `delta.tool_calls` (if present) AND the final `message.tool_calls` into a complete response object. Kexvim's custom TypeScript parser only handled the delta path.

**Why the `Promise.all` approach is an anti-pattern**:

```typescript
// WRONG — calls API twice, wastes tokens, not Hermes-aligned
const [streamTask, chatTask] = await Promise.all([
  this.llm.stream(req, signal),  // for interim text
  this.llm.chat(req, signal),    // for tool_calls
]);
```

The user explicitly rejected this: "直接抄hermes" means ONE API call with streaming, just like Python. The fix is making `_parseStreamChunk` handle `message.tool_calls`, NOT running parallel calls.

**Correct approach**: ONE `this.llm.stream()` call, with `_parseStreamChunk` populating the assembler from BOTH `delta.tool_calls` AND `message.tool_calls`. `finalize()` yields all tool_use events. `invokeLLM` accumulates them from stream events. No parallel calls, no two-API-waste.

#### Failure mode checklist (expanded)

When tool calls disappear after enabling streaming:
1. **Check `delta.tool_calls`** — add diagnostic counter in the SSE loop
2. **Check `message.tool_calls`** — add diagnostic in `_parseStreamChunk` for delta being empty but finish_reason = "tool_calls"
3. **Check `finish_reason`** — is it "tool_calls"? If yes but hadToolCalls=false, it's failure mode #2
4. **Check `addDelta` format** — if delta.tool_calls IS present but finalize() returns 0, it's failure mode #1 (flat format)
5. **If `[DONE]` never arrives** — stream may have timed out or connection dropped

**Most efficient debugging order**: Add `console.error("[DIAG] finish_reason:", choice.finish_reason, "delta:", JSON.stringify(choice.delta).slice(0,200))` to the SSE loop. A `finish_reason: "tool_calls"` with an empty delta immediately identifies failure mode #2.

### 9. Content Sanitization for Streaming

**Hex escape regex depth trap**: In TypeScript regex literals:
- `\\\\u` = matches `\\u` (single backslash + u)
- `\\\\\\\\u` = matches `\\\\u` (double backslash + u)

When tool results or file contents contain `\\u` followed by incomplete hex (e.g. `\\uD8`), JSON.stringify's double-escaped output is valid JSON. But the raw string in JavaScript needs sanitization before being sent to the API.

**Correct regex**: `/\\\\u(?![\\da-fA-F]{4}(?![\\da-fA-F]))/g`
- Matches `\\u` NOT followed by exactly 4 hex digits
- Replacement: `"\\uFFFD"` (U+FFFD replacement character)
- Run on ALL string values in the request body

Both the streaming path and non-streaming path need identical sanitization. The streaming path's `JSON.stringify` should use the same replacer function as the non-streaming path.

### 10. Logical Boundary Splitting for Interim Text

### 11. Concurrent Background API Calls Corrupt Streams

**Problem**: When a background task (e.g. BackgroundReviewer) fires an LLM API call concurrently with the main agent's streaming call, the main agent's stream can be corrupted — response truncated mid-sentence, tool calls lost, or agent appears to "只回一句就停."

**Root Cause**: Node.js's global `fetch()` uses `undici` with a shared HTTP connection dispatcher. Two concurrent `fetch()` calls to the same API host (`api.deepseek.com`) share the same TCP connection via the dispatcher. The streaming response reader and the background request's response reader fight over the connection, corrupting both.

**Python vs Node.js**: Hermes (Python) uses `threading.Thread` — each Python thread has its own `asyncio` event loop, and `httpx`/`aiohttp` clients created inside the thread bind to that thread's loop. HTTP connections are fully per-thread. Node.js has ONE event loop, and global `fetch()` shares one dispatcher. There is no way to create an isolated HTTP connection pool within a single Node.js process.

**Fix: Fork a child process.** `child_process.spawn('node', ['--import', tsxLoader, workerPath])` creates a completely separate Node.js runtime with:
- Its own event loop
- Its own HTTP connection pool
- Its own V8 heap
- Zero shared state with the parent

**Implementation pattern** (`spawnBackgroundReview` in AgentRuntime.ts):
```typescript
const child = spawn('node', ['--import', `file://${tsxLoader}`, workerPath], {
  stdio: ['pipe', 'pipe', 'pipe'],
  env: { ...process.env, SAGE_REVIEW_DATA: payload },
  timeout: 120_000,
});
child.stdout.on('data', d => stdout += d.toString());
child.on('close', () => {
  const parsed = JSON.parse(stdout.trim().split('\n').pop() || '{}');
  resolve(parsed.ok ? parsed.summary : '');
});
```

**Worker file** (review-worker.ts):
```typescript
const payload = JSON.parse(process.env.SAGE_REVIEW_DATA || '{}');
const llm = new OpenAIChatAdapter({ model, baseUrl, apiKey });
const result = await reviewer.review(messages);
process.stdout.write(JSON.stringify({ ok: true, summary }) + '\n');
```

**Edge case**: The main agent uses `stream()` (SSE streaming), the background task uses `chat()` (non-streaming). Even with separate adapter instances, both use Node.js's global `fetch()` — only a child process guarantees isolation.

**Alternative that didn't work**: `createReviewLLM` factory creates new adapter instances, but they share the same global `undici` dispatcher. AbortSignal + idle timer (30s delay + cancel on next user message) mitigated but didn't eliminate the concurrent API risk.

**Verification**: Background review no longer causes "只回一句就停" after switching to child process.


**Problem**: When the LLM returns a long text-only response (no tool calls), all text accumulates silently and is sent as one giant message to the user ("一股脑回"). Simple time-based flushing (every 200ms) creates arbitrary, meaningless chunks.

**Solution**: Use a `_findLogicalBoundary()` method that splits at the LAST complete semantic boundary within the buffer, keeping the remainder for the next flush interval. This ensures each chunk is a meaningful unit of text.

**Priority order** (defined in the method):
1. **Paragraph boundary** (`\n\n`) — strongest semantic unit, highest priority
2. **Sentence boundary** (period, 句号、感叹号、问号) — meaningful completion point
3. **Line break** (`\n`) — if within a paragraph, less ideal but still a natural break
4. **Punctuation** (comma, semicolon, colon) — weak boundary, used when nothing better exists
5. **60% fallback** — if no boundary in the latter 70% of buffer, send first 60% to prevent deadlock

**Threshold rule**: The boundary must be past the first 30% of the buffer (`boundary > text.length * 0.3`). This prevents sending micro-chunks of 1-2 characters when a boundary happens to exist early in the text.

**Buffer management**: After flushing, the buffer is NOT completely cleared — only the sent portion is removed. The remainder continues accumulating on the next text delta.

**Integration**: Called from the text handler of `onStream` callback, replacing the simple `_streamBuffer = ""` clear approach:

```typescript
// Before (dumb clear): 
if (now - this._lastInterimTime > 200) {
  this.statusCallback(this._streamBuffer.trim());
  this._streamBuffer = "";  // ← loses unsent remainder
}

// After (logical split):
if (now - this._lastInterimTime > 200) {
  const boundary = this._findLogicalBoundary(this._streamBuffer.trim());
  if (boundary > 0) {
    this.statusCallback(text.slice(0, boundary));
    this._streamBuffer = text.slice(boundary);  // ← keeps remainder
  }
}
```

**Reference implementation**: See `AgentRuntime.ts` in the kexvim codebase (search for `_findLogicalBoundary`).

### 12. `this.statusCallback` vs `cb` Bug — Text Events Never Send Interim Messages (Fixed 2026-07-25)

**Problem**: The text handler used `this.statusCallback` (class field, **never assigned** = undefined) while the tool_use handler correctly used the local `cb` variable. Interim text was silently accumulated but never sent.

**Root cause**:
```typescript
const cb = opts?.statusCallback ?? this.statusCallback;  // captures actual callback
this.agent.onStream = (event) => {
  if (event.type === "text") {
    if (this.statusCallback && ...) { // BUG: always undefined
```

**Fix (two stages)**:
1. Stage 1 — Changed `this.statusCallback` → `cb` in text handler
2. Stage 2 — Removed `_findLogicalBoundary` and timer-based flush entirely. Changed to **tool-boundary flush** (accumulate only, send on tool_use). This aligns with Hermes on QQ where SUPPORTS_MESSAGE_EDITING=False skip streaming deltas but interim_assistant_callback fires at LLM completion boundaries.

### 13. Diagnostic Question for "只回一句就停"

When a user reports "Kexvim only responds with one message and stops":
- **A (can't split into multiple messages)**: Tools are called, results are processed, final answer is complete — but ALL output arrives as one message per turn. Root cause: `this.statusCallback` vs `cb` bug above.
- **B (stops mid-response)**: Tools are NOT called, response is cut off mid-sentence. Root cause: guidance blocks missing (revert lost flags), or concurrent API call corruption.

The user clarified this distinction: "它一下子都能完整回答。只是不能分多次消息" — confirming scenario A. Without this, debugging went into wrong root cause (concurrent API calls, fork process, etc.).

## Debugging Checklist

When streaming returns empty content or missing tool calls:

1. **Check SSE first chunk**: Log the raw first SSE chunk. Does it have `content: ""`?
2. **Check event count**: How many events did the stream yield? If `events=1` (just done), `finalize()` never ran.
3. **Check `hadContent`**: Was it set to `true`? If the first chunk had empty content and `delta.content` was checked truthily, `hadContent` stays false.
4. **Check finish_reason ordering**: Did `_parseStreamChunk` yield done before `[DONE]`?
5. **Check tool_call_id**: Are the IDs in assistant's `tool_calls` and tool messages' `tool_call_id` identical?
6. **Check replacer function**: Does the streaming path's `JSON.stringify` have the same sanitizer replacer as the non-streaming path?

## Provider-Specific Notes

### DeepSeek
- Model mapped to `deepseek-v4-flash` via proxy
- Uses identical streaming SSE format as OpenAI
- Sends `finish_reason` in the choice JSON before `[DONE]`
- Rejects mismatched `tool_call_id` with 400 error
- First SSE chunk: role establishment with `content: ""`
- **Tool call delta format: FLAT** (`{name, arguments}` not `{function: {name, arguments}}`)

### OpenAI
- Same SSE streaming format as DeepSeek
- Also sends `finish_reason` before `[DONE]`
- Same `tool_call_id` matching requirement
- **Tool call delta format: NESTED** (`{function: {name, arguments}}`)

## Critical: `streamToolCallAssembler.addDelta` — Flat vs Nested Tool Call Format

**This is the #1 cause of tool calls work in chat() but not in stream(). However, for DeepSeek streaming specifically, both formats are irrelevant — DeepSeek never sends `delta.tool_calls` at all. See Failure Mode 2 above for the correct fix (`message.tool_calls` in `_parseStreamChunk`).**

OpenAI's SSE `tool_calls` delta uses a **nested** format:
```json
{"index": 0, "id": "call_xxx", "function": {"name": "get_weather", "arguments": "{\"city\":"}}
```

DeepSeek (and some other providers) use a **flat** format:
```json
{"index": 0, "id": "call_xxx", "name": "get_weather", "arguments": "{\"city\":"}
```

The difference: `delta.function.{name, arguments}` vs `delta.{name, arguments}`.

The original `StreamToolCallAssembler.addDelta()` only handles the nested format:
```typescript
const fn = delta.function as Record<string, unknown> | undefined;
if (fn) {
    if (fn.name) partial.name += fn.name;
    if (fn.arguments) partial.args += fn.arguments;
}
// ❌ delta.name / delta.arguments are silently dropped!
```

**Fix**: After handling the nested format with an early `return`, add a flat-format fallback:

```typescript
// OpenAI format: delta.function.{name, arguments}
const fn = delta.function as Record<string, unknown> | undefined;
if (fn) {
    if (fn.name) partial.name += fn.name;
    if (fn.arguments) partial.args += fn.arguments;
    return;  // ← DON'T fall through to flat format
}

// Flat format (DeepSeek, etc.): delta.{name, arguments}
if (typeof delta.name === "string") partial.name += delta.name;
if (typeof delta.arguments === "string") partial.args += delta.arguments;
```

**Diagnosis**: When tool calls work via `chat()` but not `stream()`:
1. Add a counter in `addDelta()` — is it being called?
2. Check `finalize()` output — how many partials does it have?
3. If `addDelta` is called but `finalize()` yields empty: the partial accumulated `id` but NOT `name`/`args` → format mismatch
4. Log the raw `delta` object to see if it has `function` wrapper or not

**Timeline of this bug**: A cleanup commit that only removed debug logs was blamed, but the real root cause was an earlier commit that switched from `chat()` (non-streaming, using `normalize_response` which handles both formats) to `stream()` (using `streamToolCallAssembler` which only handled nested format). The streaming path was never correctly extracting DeepSeek's tool calls.

## Verification

After implementing streaming:
1. Send a message that requires tool calls (e.g. "read a file")
2. Verify tool calls appear in logs with non-empty `id` matching LLM's original IDs
3. Verify the agent loop continues to a second iteration (tool results → LLM)
4. Verify interim text is flushed before tool execution
5. Verify no 400 errors about tool_call_id mismatch
6. Verify no "zero content chunks" errors
7. For logical boundary splitting: send a long text-only prompt (no tool calls) and verify interim text arrives in sentence/paragraph chunks, not arbitrary 200ms slices
