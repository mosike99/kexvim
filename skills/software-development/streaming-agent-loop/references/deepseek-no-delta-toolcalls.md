# DeepSeek Streaming: No delta.tool_calls

## Root Cause

DeepSeek's streaming API does NOT emit `delta.tool_calls` incrementally across SSE chunks. Instead, the COMPLETE tool calls arrive in the LAST SSE chunk's `message.tool_calls` field, the same format used in non-streaming responses.

This means all previous approaches relying on `delta.tool_calls` (OpenAI nested format handler, DeepSeek flat format handler in `addDelta`, `streamToolCallAssembler`) were working on data that never arrives.

## Diagnostic

In the SSE loop of `stream()`, `choice?.delta?.tool_calls` is NEVER truthy for the entire run. `hadToolCalls` stays false. `finalize()` returns empty.

But `choice?.finish_reason` = "tool_calls" - confirming the LLM DID generate tool calls, they just were not in the expected location.

```json
// Last SSE chunk (before [DONE]):
{"choices": [{"delta": {}, "message": {"tool_calls": [
  {"id": "call_xxx", "name": "read_file", "arguments": "{}"}
]}, "finish_reason": "tool_calls"}]}
```

## Fix

Add `message.tool_calls` detection to `_parseStreamChunk` in `OpenAIChatAdapter.ts`:

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

## Why Hermes (Python) Works

The OpenAI Python SDK's `stream()` internally accumulates BOTH `delta.tool_calls` (if present) AND the final `message.tool_calls` into a complete response object. Kexvim's custom TypeScript parser only handled the delta path.

## Historical Fix Timeline

1. Attempt 1: `addDelta` flat format fix (`delta.{name,arguments}`) - UNNECESSARY, DeepSeek never sends `delta.tool_calls`
2. Attempt 2: `Promise.all` with parallel stream()+chat() - ANTI-PATTERN, 2x API cost, user rejected
3. Final fix: `choice.message?.tool_calls` in `_parseStreamChunk` - CORRECT, single stream call

## Lesson

Always check whether the data actually flows through the path you are fixing. A diagnostic counter (`console.error("[DIAG] finish_reason:", finish_reason, "delta:", JSON.stringify(delta))`) in the SSE loop would have identified this immediately.
