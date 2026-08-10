# DeepSeek Interim Text Quirk (Streaming-Aware)

## Problem

Sage's streaming interim text callback (`agent.onStream`) pushes intermediate text to the user as the LLM generates it. But **DeepSeek-chat never outputs text + tool_calls in the same stream**. When it decides to call a tool, it emits a `tool_use` event with no preceding `text` events:

```
Stream order (DeepSeek):
  tool_use: { name: "read_file", args: "..." }
  done: { finishReason: "tool_calls" }

Stream order (Claude/OpenAI):
  text: "让我先看看代码..."
  text: "的结构..."
  tool_use: { name: "read_file", args: "..." }
  done: { finishReason: "tool_calls" }
```

This means `_streamBuffer` is empty when `tool_use` fires. The "text flush" branch is never hit for DeepSeek.

## Solution

In the `onStream` callback, check `_streamBuffer` on `tool_use`:

```typescript
if (event.type === "tool_use") {
  if (this._streamBuffer.trim()) {
    // Model thought aloud → show it (Claude/OpenAI)
    this.statusCallback(this._streamBuffer.trim());
  } else {
    // DeepSeek: no text → send brief progress
    this.statusCallback(`🔍 正在${event.name}...`);
  }
  this._streamBuffer = "";
}
```

This maps to Hermes' `tool_progress_callback` pattern: when the model jumps straight to tool calls without thinking aloud, the user still gets "🔍 正在read_file..." so they know something is happening.

## Why DeepSeek behaves this way

The OpenAI-compatible streaming API for function/tool calling treats `content` and `tool_calls` as mutually exclusive fields in a single chunk delta. When the model decides to call a tool, it sets `delta.tool_calls` and stops setting `delta.content`. DeepSeek-chat follows this pattern strictly.

Anthropic Claude, by contrast, returns text content AND tool_use blocks in the same response — the model literally "thinks aloud" before calling tools.

This is a provider-level difference, not a bug in kexvim.

## Effect on User Experience

With DeepSeek, the user sees:
1. 🔍 正在read_file...  (before tool starts)
2. Tool executes silently
3. Final response: "统计数据完成..."

With Claude/OpenAI, the user sees:
1. 让我先看看代码结构...  (while thinking)
2. 🔍 正在read_file...  (before tool starts)
3. Tool executes silently
4. 发现了bug...  (next thinking)
5. 🔍 正在patch...  (before next tool)
6. Tool executes silently
7. 修复完成。  (final response)

## Rate Limiting

Both paths (text flush and DeepSeek fallback) are rate-limited via `_lastInterimTime`:
- Text flush: 1s cooldown (faster since it's meaningful content)
- DeepSeek fallback: 2s cooldown (slower to avoid "🔍 正在read_file... 🔍 正在search_files..." spam)
- Periodic flush: 120-char threshold + 2s cooldown
