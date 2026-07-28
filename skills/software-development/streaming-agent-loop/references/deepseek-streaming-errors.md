# DeepSeek Streaming Agent Loop: Error Reference

Session: 2026-07-22, Kexvim QQ bot (Node.js/TypeScript)
Updated: 2026-07-23 — added failure mode 2 (message.tool_calls)

## Error: `unexpected end of hex escape`

```
Error: LLM stream error: [unknown] 400: Failed to parse the request body as JSON:
messages[9].content: unexpected end of hex escape at line 1 column 6631
```

**Root Cause**: The `sanitizeHexEscapes` regex had wrong escaping level. TypeScript file wrote `\\\\u` which in a
JS regex literal matches `\\u` (double backslash + u), but the actual content has `\u` (single backslash + u).

**Fix**: Use `/\\\\u(?![\\da-fA-F]{4}(?![\\da-fA-F]))/g` in the regex literal — `\\\\u` in JS regex matches `\\u`.

**Also fixed**: The streaming path's `JSON.stringify(body)` had no replacer function. The non-streaming `chat()` path had:
```
JSON.stringify(body, (key, value) => typeof value === "string"
  ? value.replace(/[...surrogates...]/g, "\\uFFFD").replace(/\\u0000/g, "")
  : value
)
```
Applied the same replacer to the streaming path.

## Error: `lone leading surrogate in hex escape`

```
Error: LLM stream error: [unknown] 400: Failed to parse the request body as JSON:
messages[9].content: lone leading surrogate in hex escape
```

**Root Cause**: `stream()` method directly called `JSON.stringify(body)` without `sanitizeLoneSurrogates`.

**Fix**: Added `AdapterHelper.sanitizeLoneSurrogates(body)` before `JSON.stringify(body)` in the `stream()` method.

## Error: `insufficient tool messages following tool_calls message`

```
Error: LLM stream error: [unknown] 400: {"error":{"message":"An assistant message with 'tool_calls'
must be followed by tool messages responding to each 'tool_call_id'. (insufficient tool messages
following tool_calls message)"}}
```

**Root Cause**: `StreamToolCallAssembler.finalize()` returned `{ type, name, args }` but **dropped `id`**.
The `invokeLLM` streaming path generated custom IDs (`tool_${Date.now()}_${i}`), but the tool messages
referenced these custom IDs. DeepSeek checks that `tool_call_id` in tool messages matches the LLM's
original `id` in the assistant's `tool_calls` array.

**Fix**: Three changes:
1. `finalize()` return type includes `id: string`, uses `partial.id`
2. `invokeLLM` stores `toolCalls` as `Array<{ id, name, args }>` from `event.id`
3. `invokeLLM` return maps `id: tc.id` instead of `id: \`tool_${Date.now()}_${i}\``

## Error: `Stream stalled: no data`

```
Error: LLM stream error: Stream stalled: no data for Nms (timeout: Mms)
```

**Root Cause**: Stale detection in `stream()` method. Triggered when the interval between chunks exceeds
`staleTimeoutMs`. Not encountered in this session but a known DeepSeek issue with slow reasoning models.

## Symptom: 答非所问 (irrelevant replies)

**Root Cause**: `extractContent(messages)` searches backwards for the last non-empty assistant message.
When the streaming path returned empty content (`contentLen=0`), it found the PREVIOUS assistant message
from session history and returned THAT old content.

**Trigger Condition**: The stream yielded 0 text events (hadContent=false) but also no tool_use events.
The `[DONE]` handler's zero-chunk guard fired, yielding an error which was caught and returned as
`{ error, response: { content: "" } }`. The agent loop returned empty content.

**Fix**: Ensure the first SSE chunk (with `content: ""`) yields a text event so `hadContent=true`.
See the `typeof delta.content === "string"` fix in the main SKILL.md.

## Symptom: streaming returns `events=1` (just done, no content, no tool calls)

**Root Cause 1**: `_parseStreamChunk` yielded `done` on `finish_reason` (before `[DONE]`).
The consumer (`invokeLLM`) broke on the done event, never consuming the `[DONE]` handler's `finalize()` output.

**Root Cause 2**: `if (delta.content)` was falsy for `content: ""`, so the first SSE chunk
yielded nothing. `hadContent` stayed false. When `[DONE]` arrived, the zero-chunk guard fired.

**Root Cause 3 (NEW)**: DeepSeek sends complete tool_calls in `message.tool_calls`, NOT `delta.tool_calls`.
The SSE loop checks `choice?.delta?.tool_calls` which is NEVER truthy. `hadToolCalls` stays false.
`finalize()` yields nothing. The `[DONE]` handler sees `!hadContent && !hadToolCalls` and
fires the zero-chunk guard, OR yields `done` with no tool_use events.

## Symptom: streaming yields no `tool_use` events (toolCalls empty, `events=1`)

**Primary Root Cause (2026-07-23 update)**: DeepSeek does NOT emit `delta.tool_calls` at all.
The complete tool calls arrive in the LAST SSE chunk's `choice.message.tool_calls` field:

```json
{"choices": [{"delta": {}, "message": {"tool_calls": [
  {"id": "call_xxx", "name": "read_file", "arguments": "{\"path\": \"/tmp/test\"}"}
]}, "finish_reason": "tool_calls"}]}
```

Note: `delta` is empty, `message.tool_calls` has the complete data.

**Diagnosis**: `choice?.delta?.tool_calls` is NEVER truthy. `finish_reason === "tool_calls"`.
Add a diagnostic in the SSE loop to confirm.

**Fix**: In `_parseStreamChunk`, after setting `_streamFinishReason`, check `choice.message?.tool_calls`:

```typescript
if (choice.message?.tool_calls) {
  const msgToolCalls = choice.message.tool_calls as Array<Record<string, unknown>>;
  for (let i = 0; i < msgToolCalls.length; i++) {
    this.streamToolCallAssembler.addDelta(i, msgToolCalls[i] as Record<string, unknown>);
  }
}
```

**Secondary Root Cause** (pre-2026-07-23): `StreamToolCallAssembler.addDelta()` only handles OpenAI's nested format (`delta.function.{name, arguments}`) but DeepSeek uses a flat format (`delta.{name, arguments}`).

OpenAI format (works with `addDelta`):
```json
{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_xxx", "function": {"name": "get_weather", "arguments": "{\"city\":"}}]}}]}
```

DeepSeek flat format (silently dropped):
```json
{"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_xxx", "name": "get_weather", "arguments": "{\"city\":"}}]}}]}
```

**Key difference**: `delta.function` exists in OpenAI but is `undefined` in DeepSeek. The `if (fn)` check fails, and `partial.name`/`partial.args` are never populated. `finalize()` returns empty arrays.

Note: The flat-format-only issue is the SECONDARY root cause. The PRIMARY issue is that `delta.tool_calls` may be completely absent. Both fixes are needed.

**Diagnosis for the secondary issue**:
- Tool calls work via `chat()` (non-streaming) but not via `stream()` (streaming)
- `addDelta()` IS called (counter in the method shows it's invoked) but `finalize()` yields 0 events
- Log the raw `delta` object to see the format: `console.error("[sse] tc delta:", JSON.stringify(tc))`

**Fix**: After handling the nested format with an early `return`, add a flat-format fallback:
```typescript
// OpenAI format: delta.function.{name, arguments}
const fn = delta.function as Record<string, unknown> | undefined;
if (fn) {
    if (fn.name && typeof fn.name === "string") partial.name += fn.name;
    if (fn.arguments && typeof fn.arguments === "string") partial.args += fn.arguments;
    return;  // ← DON'T fall through to flat format
}

// Flat format (DeepSeek, etc.): delta.{name, arguments}
if (typeof delta.name === "string") partial.name += delta.name;
if (typeof delta.arguments === "string") partial.args += delta.arguments;
```

**Diagnostic counters for this specific bug**:
```typescript
// In addDelta():
let diag = this._diagCounter || (this._diagCounter = { flat: 0, nested: 0, total: 0 });
diag.total++;
if (delta.function) diag.nested++; else if (delta.name || delta.arguments) diag.flat++;
console.error("[diag] addDelta: total=" + diag.total + " nested=" + diag.nested + " flat=" + diag.flat);
// If flat > 0 and nested === 0, the nested-only code is silently dropping them
```

**Misleading signal**: A user may blame a log-removal commit because it coincided with the deployment that activated the streaming path. The streaming path was previously dormant (`agent.onStream` was never set), so removing debug logs didn't cause the regression — the earlier commit that set `agent.onStream` for the first time did.

## Useful Debug Logs

Add these temporarily when debugging:

```typescript
// In stream() SSE parser (OpenAIChatAdapter.ts):
if (this.streamDiagnostics.chunkCount === 1) {
  console.error("[sse] first chunk:", JSON.stringify(buffer.slice(0, 300)));
}

// In invokeLLM (AgentRuntime.ts):
console.error("[invokeLLM] USING STREAMING PATH");
// After stream:
console.error("[invokeLLM] stream done, events=" + eventCount +
  " toolCalls=" + toolCalls.length + " contentLen=" + fullContent.length);

// In onStream callback:
if (event.type === "text" && _streamBuffer.length === event.delta.length) {
  console.error("[stream] first text delta:", event.delta.slice(0, 40));
}

// NEW: Diagnostic for failure mode 2 — check finish_reason + delta emptiness:
// In stream() SSE loop, add after const choice = parsed.choices?.[0];
if (choice?.finish_reason === "tool_calls") {
  console.error("[DIAG] finish_reason=tool_calls, has delta.tool_calls=",
    !!choice?.delta?.tool_calls, "has message.tool_calls=",
    !!choice?.message?.tool_calls,
    "delta:", JSON.stringify(choice?.delta).slice(0, 100));
}
```
