# Agent.ts `tool_calls` 缺失 — DeepSeek 400 根源

## 症状

BackgroundReviewer 子 Agent 调用 DeepSeek API 时返回 400。

**根源**：DeepSeek 返回 `invalid_request_error` 原因是消息序列中 `tool` role 消息没有前面对应的 `assistant[tool_calls]`。

## 根因

`Agent.ts:227-230` 的 `run()` 方法每次 LLM 调用后 push assistant 消息时，**没有带上 `tool_calls` 字段**：

```typescript
// ❌ 修复前：没有 tool_calls
messages.push({
  role: "assistant",
  content: response.content || "",
});
```

即使 `response.toolCalls` 有值，这个消息也不包含 `tool_calls`。当后续 `tool` role 消息被 push 时，DeepSeek 看到：

```
user: "..."
assistant: ""        ← 没有 tool_calls！
tool: "result1"      ← 孤立！没有对应的 tool_calls
```

DeepSeek 要求 `tool` 消息前面必须有一个 `assistant` 消息包含匹配的 `tool_calls` 数组。否则返回 400。

## 修复

```typescript
const responseObj = response as LLMResponse & { toolCalls?: LLMToolCall[] };
let toolCallsFromLLM: LLMToolCall[] = responseObj.toolCalls || [];
messages.push({
  role: "assistant",
  content: response.content || "",
  tool_calls: toolCallsFromLLM.length > 0
    ? toolCallsFromLLM.map(tc => ({
        id: tc.id || tc.call_id || `call_${apiCallCount}_${random().slice(2, 8)}`,
        type: "function" as const,
        function: {
          name: tc.name || tc.function?.name || "",
          arguments: typeof tc.arguments === "string" ? tc.arguments
            : typeof tc.function?.arguments === "string" ? tc.function.arguments
            : JSON.stringify(tc.input || tc.arguments || tc.function?.arguments || {}),
        },
      }))
    : undefined,
});
```

关键：`tool_calls` 字段只在有工具调用时设置（`length > 0 ? [...] : undefined`）。无工具时不传。

## 涉及文件

- `src/inference/Agent.ts` — `run()` 方法

## 验证

编译通过后发一条测试消息让 Agent 调工具 → DeepSeek 不再返回 400。
