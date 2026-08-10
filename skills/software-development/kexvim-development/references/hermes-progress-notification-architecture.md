# Hermes 中间进度通知架构（源码级参考）

## 文件结构

| 文件 | 职责 |
|------|------|
| `agent/conversation_loop.py` (~5800行) | 主 agent 循环，触发所有 callback |
| `agent/tool_executor.py` (~1800行) | 工具执行器，调用 `tool_progress_callback` |
| `agent/agent_init.py` | 注册所有 callback 到 AIAgent |
| `run_agent.py` (~6650行) | `AIAgent` 类，包含 `_emit_interim_assistant_message` |
| `gateway/run.py` (~23181行) | gateway 主文件，注入 callback 实现 + 异步 drain |
| `gateway/stream_consumer.py` (~1983行) | 流式文本消费（on_delta → edit_message） |
| `gateway/display_config.py` (~299行) | 平台显示配置解析 |
| `gateway/status_phrases.py` (~227行) | 通用状态短语生成 |
| `gateway/platforms/base.py` | 平台适配器基类（`set_status_text`, `send_typing`） |

## 通道 A: interim_assistant_callback

### 注册（gateway/run.py line 20444）
```python
agent.interim_assistant_callback = _interim_assistant_cb if _want_interim_messages else None
```

### Callback 实现（gateway/run.py line 20133-20154）
```python
def _interim_assistant_cb(text: str, *, already_streamed: bool = False) -> None:
    if not _run_still_current():
        return
    display_text = text
    if _stream_consumer is not None:
        if already_streamed:
            _stream_consumer.on_segment_break()   # 已有流式内容，只是分界
        else:
            _stream_consumer.on_commentary(display_text)  # 新评论
        return
    # 无 stream consumer → 直接发消息
    safe_schedule_threadsafe(
        _status_adapter.send(_status_chat_id, display_text, ...),
        ...
    )
```

### Agent 端触发（run_agent.py line 5032-5081）
```python
def _emit_interim_assistant_message(self, assistant_msg):
    cb = getattr(self, "interim_assistant_callback", None)
    if cb is None: return
    visible = self._interim_assistant_visible_text(assistant_msg)  # 去 think 标签
    # 去重
    if self._interim_text_was_delivered(visible): return
    cb(visible, already_streamed=already_streamed)
    self._record_delivered_interim_text(visible)  # 记录已发
```

### 调用时机（conversation_loop.py）
- Codex incomplete 有内容时: line 4637
- 普通工具调用循环有助手文本时: line 5013
- Codex ack 续写时: line 5464
- 最终响应发出时: lines 5536, 5607
- 去重：计算可见文本 hash 比对 `_delivered_interim_texts` set，相同则不重复发送

## 通道 B: tool_progress_callback

### 注册（gateway/run.py line 20428-20436）
```python
agent.tool_progress_callback = progress_callback if (needs_progress_queue or log_mode_enabled or _live_status_adapter) else None
```

### Callback 实现（gateway/run.py line 19220-19420）
关键逻辑：
1. **Live status**（Slack 状态栏）: `_live_status_adapter.set_status_text(source.chat_id, phrase)` — line 19241
2. **_thinking 文本转发**（gateway/run.py line 19290-19301）：通过 `thinking_progress` 独立配置
3. **tool_progress 气泡**：enqueue 到 `progress_queue` → 由 `send_progress_messages()` 异步 drain
4. **中断保护**：检测 `agent.is_interrupted` 后静默丢弃事件（line 19320-19327）
5. **`new` 模式**：仅当 tool_name 变化时才发送（line 19329-19332）

### Queue drain（gateway/run.py line 19540-19860）
```
send_progress_messages() 协程:
  while True:
    raw = progress_queue.get_nowait()
    if edited-in-place 模式: edit_message(progress_msg_id, full_text)
    else: send(chat_id, msg)  // 发新消息
    throttle: 1.5s 之间不重复编辑 (line 19563)
    overflow: 超适配器消息长度限制时分割新气泡
```

### Agent 端触发（tool_executor.py line 567-571）
```python
if agent.tool_progress_callback:
    display_args = _redact_tool_args_for_display(name, args) or args
    preview = _build_tool_preview(name, display_args)
    agent.tool_progress_callback("tool.started", name, preview, display_args)
```

### _thinking 特殊路径（conversation_loop.py line 4525-4543）
```python
# 子代理 → 仅第一行前80字符
agent.tool_progress_callback("_thinking", first_line)
# 主代理 → 最多500字符推理文本
agent.tool_progress_callback("reasoning.available", "_thinking", _think_text[:500], None)
```

## 通道 C: long_running_notifications（心跳）

### 启动（gateway/run.py line 21396-21500）
```python
_NOTIFY_INTERVAL_RAW = _float_env("HERMES_AGENT_NOTIFY_INTERVAL", 180)  # 默认3分钟
_NOTIFY_INTERVAL = _NOTIFY_INTERVAL_RAW if _NOTIFY_INTERVAL_RAW > 0 else None
# 若配置了 display.long_running_notifications: off 则禁用
if _long_running_mode == "off":
    _NOTIFY_INTERVAL = None
# 启动心跳任务
_notify_task = asyncio.create_task(_notify_long_running())
```

### 心跳内容（line 21438-21472）
```python
_elapsed_mins = int((time.time() - _notify_start) // 60)
# busy_ack_detail 控制是否包含迭代/工具信息
if _want_iteration_detail:
    _parts.append(f"iteration {_a['api_call_count']}/{_a['max_iterations']}")
_action = _a.get("current_tool") or ...
if _action:
    _parts.append(str(_action))
# generic mode → 随机短语，否则 "⏳ Working — N min"
_heartbeat_text = (
    _generic_status_phrase("status")
    if _long_running_mode == "generic"
    else f"⏳ Working — {_elapsed_mins} min{_status_detail}"
)
```

### 发送策略：先 edit 再 send（line 21473-21498）
```python
if _heartbeat_msg_id:
    try:
        _notify_res = await _notify_adapter.edit_message(...)  # 优先原地编辑
    except Exception:
        _notify_res = None
if not (_notify_res and _notify_res.success):
    _notify_res = await _notify_adapter.send(...)  # 编辑失败 → 新消息
    if _notify_res.success and _notify_res.message_id:
        _heartbeat_msg_id = _notify_res.message_id  # 记录 id 方便下次 edit
```

### 停止条件（line 21434-21436 + _should_emit_long_running_notification line 6482-6501）
```python
def _should_emit_long_running_notification(self, session_key, agent, executor_task):
    if agent is None: return False
    if executor_task is not None and executor_task.done(): return False
    if session_key and self._running_agents.get(session_key) is not agent: return False
    return True
```

## 配置项一览

| 配置路径 | 默认值 | 说明 |
|----------|--------|------|
| `display.tool_progress` | `"all"` | off/new/all/verbose/log |
| `display.tool_progress_grouping` | `"accumulate"` | accumulate(同一气泡)/separate(各消息) |
| `display.interim_assistant_messages` | `true` | 模型中间评论 |
| `display.long_running_notifications` | `true` | 长时间运行心跳（可设为 `"generic"`） |
| `display.busy_ack_detail` | `true` | 心跳包含迭代数和工具名 |
| `display.busy_steer_ack_enabled` | `true` | mid-turn 转向确认 |
| `display.cleanup_progress` | `false` | 成功后删除进度气泡 |
| `display.live_status` | `"full"` | full/verb/off（Slack 状态栏） |
| `display.thinking_progress` | `false` | 转发模型推理文本 |
| `display.tool_preview_length` | `0` | 工具参数预览截断长度 |
| `display.reasoning_style` | `"code"` | code/blockquote/subtext |
| `agent.gateway_notify_interval` | `180` | 心跳间隔（秒），0=禁用 |
| `display.platforms.<name>.*` | 按平台 tier | 各平台的独立覆盖值 |

## 平台 Tier 默认值（display_config.py）

| Tier | 平台 | tool_progress | interim | heartbeat | busy_ack |
|------|------|-------------|---------|-----------|----------|
| 1 (高) | Telegram, Discord | all/off | true | true | true |
| 2 (中) | Slack, Mattermost, Matrix | off/new | true | true | true |
| 3 (低) | Signal, WhatsApp Cloud, BlueBubbles, Weixin | off | false | false | false |
| 4 (极小) | Email, SMS, Webhook | off | false | false | false |

## 核心 Callback 注册一览（gateway/run.py）

```python
# ~line 20428
agent.tool_progress_callback = progress_callback
agent.tool_start_callback   = voice_ack_callback  # Discord voice 专用
agent.step_callback         = _step_callback_sync  # hooks
agent.stream_delta_callback = _stream_delta_cb     # token 流
agent.interim_assistant_callback = _interim_assistant_cb
agent.status_callback       = _status_callback_sync
agent.notice_callback       = _notice_callback_sync
agent.event_callback        = _event_callback_sync
```

所有 callback 都是同步函数，从 agent 工作线程直接调用 → gateway 通过 queue / safe_schedule_threadsafe 异步处理后发送到平台。
