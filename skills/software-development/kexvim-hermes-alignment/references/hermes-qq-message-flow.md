# Hermes QQ 消息发送流程

2026-07-25 会话追查结果。

## 结论

Hermes on QQ **不做** stream delta 逐 token 推送（`SUPPORTS_MESSAGE_EDITING = False`），但也**不是**"等整个回复生成完一次性发出去"。

Hermes on QQ 的每一条消息对应一个 **LLM 调用完成后的工具间文本段**。

## 详细流程

### Gateway 层（`gateway/run.py`）

```python
# 第 20077-20084 行：QQ 不做 streaming
_adapter_supports_edit = getattr(_adapter, "SUPPORTS_MESSAGE_EDITING", True)
if not _adapter_supports_edit:
    raise RuntimeError("skip streaming for non-editable platform")
```

- `_stream_consumer` = None（不创建）
- `_stream_delta_cb` = None（不注册）
- **但 `_interim_assistant_cb` 仍然注册**（与 streaming 无关）

### Interim Assistant Callback（`gateway/run.py` 第 20133-20154 行）

```python
def _interim_assistant_cb(text: str, *, already_streamed: bool = False) -> None:
    if not _run_still_current():
        return
    display_text = text
    if _stream_consumer is not None:
        # ... 走 stream consumer 路径（QQ 不走这里）
        return
    # QQ 走这里：直接发送
    if already_streamed or not _status_adapter or not str(display_text or "").strip():
        return
    safe_schedule_threadsafe(
        _status_adapter.send(
            _status_chat_id,
            display_text,
            metadata=_status_thread_metadata,
        ),
        ...
    )
```

`_status_adapter` 是 QQ adapter 实例。`send()` 即 `QQBotAdapter.send()` → `truncate_message()` → REST API。

### Agent 层（`run_agent.py` 第 5032-5081 行）

```python
def _emit_interim_assistant_message(self, assistant_msg):
    cb = getattr(self, "interim_assistant_callback", None)
    # ... 去重 + 提取 visible text
    cb(visible, already_streamed=already_streamed)
```

### Agent 层触发时机（`conversation_loop.py` 第 4636-4637 行）

```python
# 当 LLM 返回的 assistant 消息有 text + finish_reason=incomplete 时：
messages.append(interim_msg)
agent._emit_interim_assistant_message(interim_msg)
```

即：**LLM 完成一次调用，产生了文本 + 工具调用** → 文本作为一个 interim 消息发送。

### 最终回复

最终 LLM 调用（无工具）→ 不触发 `_emit_interim_assistant_message` → 文本仅作为 handler 返回值 → Gateway 的 `_process_message_background` 发送。

## 完整消息流

```
用户消息
  → Gateway._process_message_background()
    → _message_handler(event)  [agent runs]
      → agent loop:
        → LLM call 1: "I'll search" + tool_call(search)
          → _emit_interim_assistant_message("I'll search")
            → _interim_assistant_cb → adapter.send("I'll search")
              → REST API POST /v2/users/{openid}/messages → 用户看到 "I'll search"
        → tool executes
        → LLM call 2: "Found X" + tool_call(read_file)
          → _emit_interim_assistant_message("Found X")
            → _interim_assistant_cb → adapter.send("Found X")
              → 用户看到 "Found X"
        → tool executes
        → LLM call 3: "Here is the answer" (no tools)
          → NO interim message
          → 循环结束
    → 返回 "Here is the answer"
  → Gateway 发送回复 → 用户看到 "Here is the answer"
```

## Sage 对齐实现

关键文件：`~/.sage/src/AgentRuntime.ts`

### agentLoop() 中 invokeLLM 调用后

```typescript
// 对齐 Hermes _emit_interim_assistant_message: 只有工具调用之间发 interim，最终回复不发
if (toolCallsFromLLM.length > 0 && this._streamBuffer.trim() && cb) {
  try { cb(this._streamBuffer.trim()); } catch {}
  this._streamBuffer = "";
}
```

### onStream tool_use 事件

```typescript
// 对齐 Hermes interim_assistant_callback: 工具之间的文本作为一条完整消息发送
if (this._streamBuffer.trim()) {
  try { cb(this._streamBuffer.trim()); } catch {}
}
// 无文本时：发工具进度提示（对齐 Hermes tool_progress_callback）
try { cb(`🔍 正在${event.name}...`); } catch {}
```

### onStream text 事件

不做任何发送，仅积累。因为 Hermes 不在 stream 中发消息，只在 LLM 调用完成后发。

### 最终回复

不 flush buffer → `chat()` 返回文本 → Gateway 发送，发一次。

## 与 Hermes on Telegram 的区别

| 特性 | Hermes on Telegram | Hermes on QQ | Sage on OneBot |
|------|-------------------|-------------|----------------|
| Stream delta 推送 | ✅ progressive edit | ❌ 不支持 | ❌ 不支持 |
| Interim assistant 消息 | ✅ 同 | ✅ 同 | ✅ 同 |
| 消息编辑 | ✅ editMessageText | ❌ 不支持 | ❌ 不支持 |
| 每条消息对应 | stream 段 | 工具间文本段 | 工具间文本段 |

