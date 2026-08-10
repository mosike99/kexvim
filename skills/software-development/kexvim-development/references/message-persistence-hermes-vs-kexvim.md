# Message Persistence: Hermes vs Sage Architecture Comparison

## Overview

Both Hermes and Sage persist conversation history to a SQLite `messages` table so that after restart the agent can remember what was said. But they diverge on **which roles** get persisted and **how tool messages** are handled.

## Schema (Both)

```sql
CREATE TABLE messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL,
    role        TEXT NOT NULL,
    content     TEXT,
    tool_call_id TEXT,
    tool_calls  TEXT,
    tool_name   TEXT,
    timestamp   REAL NOT NULL,
    token_count INTEGER,
    active      INTEGER NOT NULL DEFAULT 1,
    ...
);
```

## Key Difference: What Gets Persisted

### Hermes (writes everything)
- `append_message()` persists **user, assistant, AND tool** roles
- Tool messages carry `tool_call_id`, `tool_calls`, `tool_name` — all fields are populated
- On reload, `get_messages_as_conversation()` returns the **full message chain** including tool calls and results
- LLM sees: `user → assistant(tool_calls) → tool → assistant → tool → assistant(response)`

### Sage (writes only user/assistant)
- `appendMessage()` is called only for user and assistant roles (AgentRuntime.ts lines 443, 473, 803)
- **Tool messages are never persisted** — they're ephemeral per-turn context
- On reload, `getMessagesAsConversation()` returns only user/assistant messages
- LLM sees: `user → assistant → user → assistant` (no tool call artifacts)

### Why Sage's approach is valid

Sage's tool results are **reconstructable** — the assistant message's `tool_calls` field captures what was called, and tool results are deterministic per-call. Losing them on restart is acceptable because:
1. The new conversation turn will generate fresh tool calls as needed
2. The `tool_call_id` error chain (400) is avoided entirely — no orphaned tool rows
3. Simpler code — no need to serialize/deserialize tool call chains

## When Orphaned Tool Rows Appear (Debug History)

Tool messages in the sage messages table came from one source only — the **full msgList dump** block added during the i18n merge:

```typescript
// REMOVED — was in AgentRuntime.ts post-turn
if (s.sessionStore && s.session) {
  for (const msg of msgList) {
    s.sessionStore.appendMessage(s.session.id, msg.role, content);
  }
}
```

This loop persisted **every message in s.messages** including tool results, but the old `appendMessage` did not accept `tool_call_id` — so all tool rows had `tool_call_id = NULL`. When `getMessagesAsConversation()` loaded them and sent them to the LLM API, the API rejected `role: "tool"` messages without `tool_call_id`.

**Fix (two layers)**:
1. **Remove the source** — delete the full msgList dump (done). New sessions don't write tool rows.
2. **Filter on load** — `getMessagesAsConversation()` filters out `role === "tool" && !tool_call_id` (done). Existing orphan rows are harmless.

## Detecting Message Duplicates

```bash
cd D:\kexvim-dev && node -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync("data/kexvim.db");
// Duplicate (role, content) pairs per session
const dupes = db.prepare(`
  SELECT session_id, role, substr(content,1,60) as snippet, COUNT(*) as cnt
  FROM messages WHERE active = 1 AND content IS NOT NULL AND content != ""
  GROUP BY session_id, role, content HAVING cnt > 1 ORDER BY cnt DESC LIMIT 20
`).all();
console.log(dupes);
'
```

## Cleaning Up Duplicate Messages

If duplicates exist (from the full msgList dump bug or i18n merge), remove exact duplicates:

```sql
DELETE FROM messages WHERE id IN (
  SELECT m1.id FROM messages m1
  JOIN messages m2 ON m1.session_id = m2.session_id
    AND m1.role = m2.role AND m1.content = m2.content
    AND m1.id > m2.id
);
```

But be careful — this removes tool messages that are part of valid chains. The safer approach: just restore from a fresh DB and let `appendMessage()` rebuild the session's messages naturally.
