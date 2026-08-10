# Debugging Empty Stream (`events=1, contentLen=0`)

## Symptom

Log shows:
```
[invokeLLM] USING STREAMING PATH for deepseek-chat
[sse] first chunk: "data: {...delta:{\"role\":\"assistant\",\"content\":\"\"},...finish_reason:null"
[invokeLLM] stream done, events=1 toolCalls=0 contentLen=0
[gateway] > user:...: <old cached reply from session>
```

Sage sends an OLD message from session history instead of a fresh LLM response.
User reports "答非所问" (nonsensical replies).

## Root Cause: `if (delta.content)` Skips Empty Content

**`_parseStreamChunk()` (`OpenAIChatAdapter.ts:1580`) uses `if (delta.content)`:**

```typescript
// ❌ Empty string is falsy — skips role-establishment chunk
if (delta.content) {
  yield { type: "text" as const, delta: delta.content };
}
```

Many non-OpenAI providers (DeepSeek, etc.) send an initial SSE chunk with
`delta: { role: "assistant", content: "" }` to establish the role before
sending actual content or `tool_calls` deltas. Since `""` is falsy, this
chunk yields **zero events** and `hadContent` stays `false`.

### Failure Chain

1. Role-establishment chunk: `content: ""`, `finish_reason: null`
2. `_parseStreamChunk` yields **zero events** (both `""` and `null` are falsy)
3. `hadContent` stays `false`, `hadToolCalls` stays `false`
4. Tool_call deltas arrive → `hadToolCalls = true`, accumulated by assembler
5. `[DONE]` arrives:
   - Guard `!hadContent && !hadToolCalls` → `false` (hadToolCalls is true)
   - `finalize()` yields assembled tool_use events
   - `done` yielded
6. `invokeLLM`: `fullContent=""`, `toolCalls` populated
7. Agent loop: toolCalls extracted → tools executed

**However**: if tool_calls deltas arrive in a DeepSeek-specific format where
`StreamToolCallAssembler.addDelta()` creates entries with empty `name`/`args`,
the `finalize()` still returns them — `invokeLLM` gets non-zero `toolCalls`.
But if `hadToolCalls` was set by an **empty array** (`[]` is truthy in JS),
`finalize()` returns empty → stream yields only `done` → agent loop sees
0 toolCalls + empty content → `break` → `extractContent(msgList)` finds the
LAST non-empty assistant message from session history → sends old cached reply.

### Second-Order Effect: extractContent Fallback to Session History

`AgentRuntime.extractContent()` searches backwards through `msgList` and
returns the LAST assistant message with non-empty content. When the current
turn's assistant message has `content: ""`, the function skips it and finds
the PREVIOUS assistant message loaded from the session DB. This causes kexvim
to parrot an old reply verbatim.

## Fix: `typeof delta.content === "string"`

In `_parseStreamChunk()` (`OpenAIChatAdapter.ts:1580`):

```typescript
// ❌ Empty string is falsy
if (delta.content) {
// ✅ Yield even empty string to signal content presence
if (typeof delta.content === "string") {
```

This ensures:
- Empty string `""` → text event yielded (with empty delta) → `hadContent=true`
- `undefined` / `null` → still correctly falsy
- Real content → works as before

After the fix, the role-establishment chunk yields `{ type: "text", delta: "" }`
which sets `hadContent=true`, allowing the zero-chunk guard to pass and
`[DONE]` to properly finalize tool calls.

## Second Critical Bug: Premature `done` Yield Before `finalize()`

After fixing `if (delta.content)`, `toolCalls=0` may still appear in logs.
**This is a separate bug** - `_parseStreamChunk` yields `done` on `finish_reason`
BEFORE the `[DONE]` handler calls `finalize()`.

### Root Cause

`_parseStreamChunk()` also yields `{ type: "done" }` when `choice.finish_reason`
is truthy (line 1594-1601):

```typescript
// ❌ Yields done BEFORE [DONE] handler calls finalize()
if (choice.finish_reason) {
  yield { type: "done" as const, finishReason };
}
```

DeepSeek sends `finish_reason: "tool_calls"` in a regular SSE chunk (before
`[DONE]`). When this chunk arrives:

1. Tool call deltas from earlier chunks → accumulated by `streamToolCallAssembler`
2. `_parseStreamChunk` yields `{ type: "done", finishReason: "tool_calls" }`
3. **`invokeLLM` breaks on this done event** (`if (event.type === "done") break;`)
4. For-await loop stops consuming the generator
5. Subsequent yield events from the generator are **discarded**
6. `[DONE]` handler runs `finalize()` → yields tool_use events → yields ANOTHER done
7. But `invokeLLM` already returned with empty `toolCalls` → agent loop sees 0 tools → breaks

### The Fix

Three changes in `OpenAIChatAdapter.ts`:

**1. Add instance field** (near `streamToolCallAssembler`, line ~479):
```typescript
private _streamFinishReason = "stop";
```

**2. Reset at stream init** (line ~632):
```typescript
this._streamFinishReason = "stop";
```

**3. Save instead of yield** (line ~1594-1601):
```typescript
if (choice.finish_reason) {
  let finishReason = choice.finish_reason;
  if (typeof finishReason === "number") finishReason = String(finishReason);
  this._streamFinishReason = finishReason;
  // Was: yield { type: "done" as const, finishReason };
}
```

**4. `[DONE]` handler uses saved reason** (line ~677):
```typescript
yield { type: "done", finishReason: this._streamFinishReason };
// Was: yield { type: "done", finishReason: "stop" };
```

**5. Post-while-loop also emits tools + done** (after line ~709):
```typescript
// After while(true) loop finishes (reader done, no [DONE])
const toolEvents = this.streamToolCallAssembler.finalize();
for (const te of toolEvents) { yield te; }
yield { type: "done", finishReason: this._streamFinishReason };
return;
```
This goes BEFORE the `catch` block.

### Edge Cases

- `[DONE]` IS received → `[DONE]` handler emits tools + done → `return` → post-loop never runs
- `[DONE]` NOT received → while loop exits normally → post-loop emits tools + done → `return`
- Stream aborted → catch block yields `{ done, finishReason: "cancelled" }` → no double-done

### Verification

After fix, logs should show:
```
[invokeLLM] stream done, events=<N> toolCalls=<M> contentLen=<L>
```
Where `N` > 1 and `M` > 0 for messages requiring tools.

## General Pattern

`if (delta.content)` is an **OpenAI-centric assumption**. OpenAI's streaming
API never sends an empty content delta as the first chunk. Other providers
(DeepSeek, Kimi, etc.) may send role-establishment chunks with empty content
before the actual data. Always use `typeof delta.content === "string"` when
parsing SSE delta content in provider-agnostic code.

Additionally, yielding `done` from `_parseStreamChunk` on `finish_reason`
is unsafe because `finalize()` hasn't run yet. The `[DONE]` handler (or
end-of-stream) is the only place that should yield `done`.

## Debugging Approach

### 1. Log the first SSE chunk

Add after `buffer += decoder.decode(value, ...)` in `OpenAIChatAdapter.ts`:

```typescript
if (this.streamDiagnostics.chunkCount === 1)
  console.error("[sse] first chunk:", JSON.stringify(buffer.slice(0, 300)));
```

### 2. Log event count + finishReason from invokeLLM

```typescript
console.error("[invokeLLM] stream done, events=" + eventCount
  + " finishReason=" + finishReason
  + " toolCalls=" + toolCalls.length
  + " contentLen=" + fullContent.length);
```

### 3. Interpret the data

| SSE first chunk | events= | Likely cause |
|---|---|---|
| `content: ""`, `finish_reason: null` | 1 (just done) | `if (delta.content)` skipped empty content → **fix #1** |
| `content: ""`, tool_calls present | > 1, toolCalls=0 | Premature `done` yield → **fix #2** |
| `data: [DONE]` immediately | error thrown | Empty response from API (zero-chunk guard) |
| Empty body (reader done immediately) | 0 | API returned 200 with empty body |
| Normal data | > 5, toolCalls>0 | ✅ Everything working |

## Related

- See `references/kexvim-streaming-infrastructure.md` for streaming implementation
- See SKILL.md "Streaming Agent Loop" section for architecture details
