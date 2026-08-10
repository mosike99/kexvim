# Tool Call ID Persistence — API Error Fix

## Problem

LLM API (DeepSeek) returned:
```
400: {"error":{"message":"Failed to deserialize the JSON body into the
target type: messages[175]: missing field `tool_call_id`",...}}
```

## Root Cause

`getMessagesAsConversation()` only selected `role, content, timestamp`.
The returned `MessageLike[]` omitted `tool_call_id`. When a `role: "tool"`
message was sent to the API without `tool_call_id`, the request was rejected.

## Files Changed

| File | Change |
|------|--------|
| `src/memory/Types.ts` | `MessageRecord` — added `tool_call_id: string | null`, `tool_calls: string | null` |
| `src/memory/SessionStore.ts` | `getMessagesAsConversation()` — SELECT now includes `tool_call_id, tool_calls`; returned MessageLike includes both fields |
| `src/memory/SessionStore.ts` | `appendMessage()` — metadata type extended with `tool_call_id`, `tool_calls`; INSERT now writes these columns |
| `src/memory/Types.ts` | `SessionStore.appendMessage()` interface signature updated |

## Safeguard

`getMessagesAsConversation()` filters out `role === "tool"` rows that lack
`tool_call_id` — orphaned tool results from the old full-msgList dump.
Defense-in-depth even after the source of orphaned rows was removed.

## DB Auto-Migration

Constructor runs try/catch ALTER TABLE for each new column:
```typescript
try { this.db.exec(`ALTER TABLE messages ADD COLUMN tool_call_id TEXT`); } catch {}
try { this.db.exec(`ALTER TABLE messages ADD COLUMN tool_calls TEXT`); } catch {}
```
