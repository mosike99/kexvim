# Sage Streaming Agent Loop — Reference (Updated)

## Status: LIVE (since commit `75da66c`)

`agent.onStream` is set in `agentLoop()` before the while loop. The streaming path is active for all LLM calls.

## Architecture

The streaming agent loop aligns with Hermes' `_fire_stream_delta` pattern. Instead of waiting for `invokeLLM` to return a complete response, we intercept LLM stream events in real-time via `agent.onStream`.

## Flow

```
agentLoop() start
  ↓
this.agent.onStream = callback
  ↓
while (budget.consume()) {
  invokeLLM(req)                              ← streaming (agent.onStream is set)
    ↓
  LLM stream starts
    for each event from AsyncGenerator:
      text      → _streamBuffer += delta (accumulate thinking)
      tool_use  → flush non-empty _streamBuffer to user via statusCallback
                  (if empty: silent — no progress indicators)
      done      → stream ends
    ↓
  invokeLLM returns LLMResponse { content, toolCalls, finishReason }
        toolCalls use LLM's original id (NOT custom IDs)
    ↓
  extractToolCalls(response)
  if (!toolCalls.length) break                   ← final response
  execute tools
  continue                                        ← next LLM call
}
```

## Key Design Decisions

1. **Only flush on `tool_use`**: No periodic auto-flush. Accumulated text is either flushed on `tool_use` (interim thinking) or left in buffer.
2. **No flush on `done`**: When stream ends without tool_calls, this is the final response (Main.ts handles it).
3. **No tool-progress indicators**: `🔍 正在xxx...` removed per user preference. Only real LLM thinking text is shown.
4. **`_streamBuffer` cleared per-stream**: Reset in `invokeLLM` streaming path entry.
5. **Rate limiting**: 1s cooldown on tool_use text flush. Prevents QQ flooding.
6. **Old post-hoc interim logic removed**: The `if (this.statusCallback)` block after `if (!toolCallsFromLLM.length) break;` is deleted.

## Event Types

```typescript
export type LLMStreamEvent =
  | { type: 'text'; delta: string }
  | { type: 'thinking'; delta: string }
  | { type: 'tool_use'; name: string; args: string; id: string }  // ← id added (commit 87149db)
  | { type: 'done'; finishReason: string }
  | { type: 'error'; message: string };
```

## StreamToolCallAssembler Changes

`finalize()` now returns `id` alongside `type`, `name`, `args`:

```typescript
finalize(): Array<{ type: "tool_use"; name: string; args: string; id: string }> {
```

The `partial.id` was always accumulated by `addDelta` from `delta.id` but was **dropped** in `finalize()`. This caused DeepSeek 400 errors about mismatched `tool_call_id`.

## invokeLLM Streaming Path (Current)

```typescript
if (this.agent.onStream) {
  this._streamBuffer = "";
  let fullContent = "";
  const toolCalls: Array<{ id: string; name: string; args: string }> = [];
  let finishReason = "stop";
  for await (const event of this.llm.stream(req, signal)) {
    (this.agent.onStream as (e: LLMStreamEvent) => void)(event);
    if (event.type === "text") fullContent += event.delta;
    if (event.type === "tool_use") toolCalls.push({ id: event.id, name: event.name, args: event.args });
    if (event.type === "done") { finishReason = event.finishReason; break; }
    if (event.type === "error") throw new Error(`LLM stream error: ${event.message}`);
  }
  // Use LLM's original id — never generate custom IDs
  return {
    response: {
      content: fullContent,
      finishReason,
      toolCalls: toolCalls.length > 0
        ? toolCalls.map((tc) => ({
            id: tc.id,       // ← LLM's original id (e.g. "call_xxxx")
            name: tc.name,
            arguments: tc.args,
          }))
        : undefined,
    },
    error: null,
  };
}
```

## onStream Callback (Current)

```typescript
this.agent.onStream = (event) => {
  if (event.type === "text") {
    this._streamBuffer += event.delta;
  } else if (event.type === "tool_use") {
    // Flush accumulated thinking text before executing tool
    if (this.statusCallback && this._streamBuffer.trim()) {
      const now = Date.now();
      if (now - this._lastInterimTime > 1000) {
        this._lastInterimTime = now;
        try { this.statusCallback(this._streamBuffer.trim()); } catch {}
      }
    }
    this._streamBuffer = "";
  } else if (event.type === "thinking") {
    if (this.statusCallback && event.delta.trim()) {
      this._streamBuffer += event.delta;
    }
  }
};
```

**No tool-progress fallback**: When `_streamBuffer` is empty on `tool_use` (DeepSeek sends tool_calls before any text), we stay silent. Users found `🔍 正在xxx...` distracting.

## _parseStreamChunk: key fixes

### 1. Empty content is content

```typescript
// WRONG: if (delta.content) {  — "" is falsy
// RIGHT:
if (typeof delta.content === "string") {
  yield { type: "text" as const, delta: delta.content };
}
```

The first SSE chunk has `content: ""`. With the old check, no text event was yielded → `hadContent=false` → `[DONE]` guard fires error → streaming returns empty.

### 2. Don't yield done early

```typescript
// WRONG — yields done before [DONE] handler runs finalize():
// if (choice.finish_reason) {
//   yield { type: "done" as const, finishReason };
// }

// RIGHT — save for later:
if (choice.finish_reason) {
  this._streamFinishReason = choice.finish_reason;
}
```

### 3. Post-loop done yield

When reader returns `{ done: true }` without receiving `[DONE]`, the post-loop code still yields tools + done:

```typescript
// End-of-stream: emit remaining tool calls and final done
const toolEvents = this.streamToolCallAssembler.finalize();
for (const te of toolEvents) { yield te; }
this.streamDiagnostics.elapsedMs = Date.now() - this.streamDiagnostics.startTime;
yield { type: "done", finishReason: this._streamFinishReason };
return;
```

### 4. [DONE] handler uses saved finishReason

```typescript
yield { type: "done", finishReason: this._streamFinishReason };
// Not: yield { type: "done", finishReason: "stop" };
```

## Instance Variables

```typescript
statusCallback?: (message: string) => void;
private _lastInterimTime = 0;
private _streamBuffer = "";
private _streamFinishReason = "stop";  // added (commit a6e565a)
```

## Prerequisite: Agent onStream Setter

```typescript
// Agent.ts — was getter-only, now has setter
get onStream(): ((event: LLMStreamEvent) => void) | undefined { return this._onStream; }
set onStream(cb: ((event: LLMStreamEvent) => void) | undefined) { this._onStream = cb; }
```

## Main.ts StatusCallback Wiring

```typescript
const qqAdapter = gateway.adapters.get("qq");
if (qqAdapter) {
  const currentUserId = msg.userId;
  runtime.statusCallback = (progressMsg: string) => {
    qqAdapter.sendText(currentUserId, progressMsg).catch(() => {});
  };
}
```

**Crucial**: Must set per-message to capture the correct `currentUserId` closure.

## Debugging

1. Check `agent.onStream` is set: log before invokeLLM
2. Check stream events are firing: log in onStream callback
3. Check `statusCallback` is set
4. Check `_streamBuffer` contents
5. Log the returned LLMResponse from invokeLLM (especially toolCalls.length)
6. Check `toolCalls[0].id` — should be LLM's original id, not `tool_Date.now_0`
