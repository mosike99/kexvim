# DeepSeek Streaming: `message.tool_calls` Instead of `delta.tool_calls`

## The Real Root Cause (Discovered 2026-07-23)

After a full day of debugging, adding diagnostics confirmed that **DeepSeek's streaming API never sends `choice.delta.tool_calls`**. Sage's entire `streamToolCallAssembler.addDelta()` path was never receiving any data.

The `[DIAG]` log line placed right before `this.streamToolCallAssembler.addDelta(index, tc)` **never fired** — meaning `choice?.delta?.tool_calls` was always falsy for every SSE chunk from DeepSeek.

## How It Actually Works

DeepSeek sends complete tool calls in the **last SSE chunk** with `finish_reason: "tool_calls"`, but in the `message` field instead of `delta`:

```json
{
  "choices": [{
    "delta": {},
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_xxx",
        "type": "function",
        "function": { "name": "read_file", "arguments": "{}" }
      }]
    },
    "finish_reason": "tool_calls"
  }]
}
```

Sage's `_parseStreamChunk()` only handled `delta.content` and `delta.reasoning_content` — it never checked `choice.message?.tool_calls`.

## The Fix

In `OpenAIChatAdapter._parseStreamChunk()`, after the finish_reason handler:

```typescript
if (choice.message?.tool_calls) {
  const msgToolCalls = choice.message.tool_calls as Array<Record<string, unknown>>;
  for (let i = 0; i < msgToolCalls.length; i++) {
    this.streamToolCallAssembler.addDelta(i, msgToolCalls[i]);
  }
}
```

## Why Previous Attempts Failed

| Attempt | What | Why it didn't work |
|---------|------|-------------------|
| Fix `addDelta` for flat format | Added `delta.{name, arguments}` handling | `delta` never had `tool_calls` at all |
| `Promise.all` with stream+chat | Two parallel API calls | Works but wastes 2x tokens |
| Add `[DIAG]` logging | Confirm format | Confirmed `delta.tool_calls` never arrives |

## Key Lesson

Always use empirical diagnostics before theorizing about provider behavior. The `[DIAG]` log proved within one message what hours of code reading couldn't: DeepSeek simply doesn't send `delta.tool_calls`. Don't try to fix `addDelta` format handling if the data never reaches it.
