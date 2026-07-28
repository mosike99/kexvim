# Hermes Streaming Agent Loop — Architecture Reference

> Source analysis of ~16K lines across `agent/conversation_loop.py`, `agent/chat_completion_helpers.py`, `run_agent.py`, `agent/tool_executor.py`, `gateway/run.py`

---

## 1. Stream Initialization

**Key code:** `conversation_loop.py:1407` → `chat_completion_helpers.py:2235`

```python
# conversation_loop.py — decide streaming
_use_streaming = True
if agent._disable_streaming:
    _use_streaming = False
elif agent.provider in {"copilot-acp"}:
    _use_streaming = False
elif agent.provider == "moa" and not agent._has_stream_consumers():
    _use_streaming = False
elif not agent._has_stream_consumers():
    if isinstance(getattr(agent, "client", None), Mock):
        _use_streaming = False
```

`_has_stream_consumers()` checks `stream_delta_callback or _stream_callback (TTS)`.  
The actual stream is created in `chat_completion_helpers.py` line 2682:

```python
stream_kwargs = {**api_kwargs, "stream": True, "timeout": httpx.Timeout(...)}
stream = request_client.chat.completions.create(**stream_kwargs)
```

Streaming is **always preferred**. Non-streaming only happens when explicitly disabled (ACP, MoA w/o consumer, Mock tests).

---

## 2. Text Chunk Accumulation

**Key code:** `chat_completion_helpers.py:2759-2843`

```python
content_parts = []         # accumulates all text delta.content
reasoning_parts = []       # accumulates reasoning_content
tool_calls_acc = {}        # accumulates tool_call deltas by index
tool_gen_notified = set()  # fire "tool_started" once per tool
finish_reason = None

for chunk in stream:                           # line 2759
    if not chunk.choices:                      # usage-only chunk (line 2800)
        ukexvim_obj = chunk.usage if hasattr(chunk, "usage") else None
        continue

    delta = chunk.choices[0].delta             # line 2808

    # Reasoning content
    reasoning_text = getattr(delta, "reasoning_content", None) or getattr(delta, "reasoning", None)
    if reasoning_text:                         # line 2814
        reasoning_parts.append(reasoning_text)
        _fire_first_delta()
        agent._fire_reasoning_delta(reasoning_text)  # → reasoning_callback(text)

    # Text content (suppressed when tool_calls present)
    if delta and delta.content:                # line 2820
        content_parts.append(delta.content)
        if not tool_calls_acc:                 # no tool calls → stream to user
            _fire_first_delta()
            agent._fire_stream_delta(delta.content)
        elif agent.stream_delta_callback:      # tool calls active → suppressed,
            agent.stream_delta_callback(delta.content)  # but reasoning tags still pass through
```

**`_fire_stream_delta()` runs through:** (run_agent.py:5158)  
1. Single-writer guard (discard if superseded by retry)  
2. Prepend `\n\n` break after tool iteration  
3. Think scrubber → Context scrubber → sanitize  
4. Fire both `stream_delta_callback` and `_stream_callback`  
5. `_record_streamed_assistant_text(text)` for de-dup comparison  

---

## 3. Tool_use Chunk Handling

**Key code:** `chat_completion_helpers.py:2845-2918` (OpenAI), `3065-3182` (Anthropic)

### OpenAI-compatible (tool_calls delta):

```python
if delta and delta.tool_calls:                         # line 2845
    for tc_delta in delta.tool_calls:
        raw_idx = tc_delta.index or 0
        delta_id = tc_delta.id or ""

        # Ollama fix: same index, different id → allocate new slot
        if delta_id and raw_idx in _last_id_at_idx and delta_id != _last_id_at_idx[raw_idx]:
            new_slot = max(tool_calls_acc, default=-1) + 1
            _active_slot_by_idx[raw_idx] = new_slot
        idx = _active_slot_by_idx.get(raw_idx, raw_idx)

        if idx not in tool_calls_acc:
            tool_calls_acc[idx] = {"id": "", "type": "function",
                                   "function": {"name": "", "arguments": ""}}

        entry = tool_calls_acc[idx]
        if tc_delta.function:
            if tc_delta.function.name:             # assignment, not += (some providers resend name)
                entry["function"]["name"] = tc_delta.function.name
            if tc_delta.function.arguments:
                entry["function"]["arguments"] += tc_delta.function.arguments  # append!

        # Fire tool_gen_callback once per tool when name is known
        name = entry["function"]["name"]
        if name and idx not in tool_gen_notified:
            tool_gen_notified.add(idx)
            _fire_first_delta()
            agent._fire_tool_gen_started(name)     # → tool_gen_callback(name)
```

### Anthropic (event-based):

```python
if event_type == "content_block_start":
    if block.type == "tool_use":
        agent._fire_tool_gen_started(block.name)
elif event_type == "content_block_delta":
    if delta.type == "text_delta" and not has_tool_use:
        agent._fire_stream_delta(delta.text)
    elif delta.type == "thinking_delta":
        agent._fire_reasoning_delta(delta.thinking)
```

---

## 4. Flush Timing

Text reaches the user at these points:

| When | What | Code |
|------|------|------|
| **Each text delta** (no tool_calls) | `stream_delta_callback(chunk.content)` | chat_completion_helpers.py:2822 |
| **Before tool execution** | `stream_delta_callback(None)` closes response box | conversation_loop.py:5055 |
| **After tool execution** | `_stream_needs_break = True` → next text gets `\n\n` | conversation_loop.py:5097 |
| **Stream end** | Scrubber flush tail, clear `_current_streamed_assistant_text` | run_agent.py:4874 |

---

## 5. Tool Execution

**Key code:** `conversation_loop.py:5061` → `run_agent.py:6186` → `tool_executor.py`

```python
# In run_conversation after getting assistant_msg with tool_calls:
messages.append(assistant_msg)
agent._emit_interim_assistant_message(assistant_msg)    # line 5013 — mid-turn text for non-streaming platforms
agent.stream_delta_callback(None)                        # line 5055 — close stream display
agent._execute_tool_calls(assistant_message, messages, ...)  # line 5061
agent._stream_needs_break = True                         # line 5097
continue   # → next API call with tool results
```

### Dispatch strategy (run_agent.py:6186):
- **1 call** → sequential
- **2+ parallel-safe** → concurrent (ThreadPoolExecutor, max_workers=8)
- **Mixed batch** → segment planner splits into parallel/sequential groups

### tool_progress_callback lifecycle:

```python
# tool.started — before execution
agent.tool_progress_callback("tool.started", name, preview, display_args)

# tool.completed — after execution
agent.tool_progress_callback("tool.completed", name, None, None,
    duration=tool_duration, is_error=bool, result="...")
```

### interim_assistant_callback (for non-streaming platforms):
Fired at line 5013 (conversation_loop.py) — delivers mid-turn tool-call narration to Telegram/Discord/etc.  
Checks `already_streamed=True` to avoid duplicating content already delivered via stream delta.  
Registered in gateway at `gateway/run.py:20133` as `_interim_assistant_cb` — sends via `adapter.send()` or `_stream_consumer.on_commentary()`.

---

## 6. Done / Final Handling

**Key code:** `conversation_loop.py:5160-5683`

```python
# No tool_calls → this is the final response
final_response = assistant_message.content or ""

# If only think blocks, no visible content:
#   1. Try partial stream recovery (use already-streamed text)
#   2. Try prior-turn content with housekeeping tools
#   3. Post-tool-call empty response nudge
#   4. Thinking-only prefill continuation
#   5. Empty response retry (×3)
#   6. Fallback provider
#   7. Terminal: "(empty)"

# On success:
final_response = agent._strip_think_blocks(final_response).strip()
final_msg = agent._build_assistant_message(assistant_message, finish_reason)
messages.append(final_msg)
break

# Post-loop:
from agent.turn_finalizer import finalize_turn
return finalize_turn(agent, final_response=final_response, api_call_count=api_call_count, ...)
```

Return dict shape: `{"final_response": str, "messages": list, "api_calls": int, "completed": bool, "interrupted": bool, "failed": bool, "partial": bool, "error": str}`

---

## 7. Error Handling

### Stream-level errors (chat_completion_helpers.py:2925-3040):

```python
# Empty stream (no finish_reason, no content, no tools)
raise EmptyStreamError("...")

# Tool args truncated, no finish_reason → mid-tool-call stream drop
return _build_partial_stream_stub(..., dropped_tool_names=[...])

# Text-only stream drop, no finish_reason
return _build_partial_stream_stub(...)
```

### Retry loop (conversation_loop.py:1227-2426):

```python
while retry_count < max_retries:
    try:
        response = _perform_api_call(...)
        if response_invalid:
            retry_count++; jittered_backoff(); continue
        if finish_reason == "content_filter":
            try fallback provider once, else return refusal
        if finish_reason == "length":
            continuation retry (×4) or truncated tool_call retry with boosted max_tokens
        break  # success
    except InterruptedError:
        save already-streamed text; return partial
    except Exception as api_error:
        classify → local processing error? → break; else retry/fallback
```

### Error classification (conversation_loop.py:5685-5778):
- Traceback module analysis: local processing errors (`_LOCAL_PROCESSING_MODULES`) vs API errors
- Local errors → deterministic, break immediately (no retry)
- API errors → retry with fallback chain

### Single-writer guard (run_agent.py:5100-5157):
- `_claim_stream_writer()` bumps `_stream_writer_token` on each retry
- `_fire_stream_delta()` checks `_stream_writer_superseded()` — drops stale stream deltas
- Prevents interleaved tokens when retry spawns a new stream while old one is still producing

---

## Callback Map

```
stream_delta_callback(text)        — each text chunk (no tool_calls)
stream_delta_callback(None)        — close stream display before tools
_stream_callback(text)             — TTS (parallel to stream_delta)
reasoning_callback(text)           — reasoning_content chunks
tool_gen_callback(name)            — first time tool name arrives in stream
tool_progress_callback("tool.started", name, preview, args)     — before tool exec
tool_progress_callback("tool.completed", name, ..., duration, is_error, result)  — after
interim_assistant_callback(text, already_streamed=False)  — mid-turn via adapter
status_callback(event_type, message)  — lifecycle (compression, retry, fallback)
```
