# OneBot v11 vs QQ Official API — Message Editing Capability

## OneBot v11 (Sage 当前使用的协议)

Sage 的 `QQAdapter.ts` 通过 OneBot v11 WebSocket 协议连接 QQ 机器人客户端（可能为 Lagrange、OpenShamrock 等）。

**标准动作：**
- `send_msg` — 发送消息 ✅
- `delete_msg` — 删除消息 ✅
- `edit_msg` — **不存在** ❌

OneBot v11 协议中没有任何编辑已发送消息的标准 action。部分 OneBot 实现可能通过自定义 action 支持编辑，但不是标准功能。

## QQ Official REST API (Hermes 使用的协议)

Hermes 的 `gateway/platforms/qqbot/adapter.py` 通过 Tencent QQ Bot 官方 REST API 连接：

- C2C: `POST /v2/users/{openid}/messages` — 发送 ✅，无编辑 ❌
- Group: `POST /v2/groups/{group_openid}/messages` — 发送 ✅，无编辑 ❌
- Guild: `POST /channels/{channel_id}/messages` — 发送 ✅
- Guild edit: `PATCH /channels/{channel_id}/messages/{message_id}` — 编辑 ✅（仅 Guild）

C2C 和 Group 消息在官方 API 上也没有编辑端点。

## 结论

| 平台 | 协议 | 编辑 C2C/Group 消息 | 
|------|------|-------------------|
| Telegram | Bot API | ✅ `editMessageText` |
| Discord | REST API | ✅ 编辑消息 |
| Slack | REST API | ✅ 编辑消息 |
| **QQ (OneBot v11)** | WebSocket | ❌ 不支持 |
| **QQ (官方 REST)** | HTTPS | ❌ 不支持 |

Sage 和 Hermes 在 QQ 上都不能做 progressive edit（发一条消息 → 持续编辑更新）。Hermes on QQ 一次性发完整个回复。Sage on QQ 用定时全量 flush（每 ~200ms 发全部 buffer）已经是 QQ 上最好的 streaming 效果。

**如果你换用 Telegram/Discord，就可以直接用 progressive edit，完全对齐 Hermes。**
