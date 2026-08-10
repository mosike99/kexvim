# Sage Session Recovery — Messages Table Implementation

## Architecture

- `AgentRuntime.messages: MessageLike[]` — in-memory conversation, **resets on restart**
- `SQLiteSessionStore` (in `D:\kexvim-dev\src\memory\SessionStore.ts`) persists both sessions and conversation messages
- Session recovery happens in `AgentRuntime.chat()`: recover session via `findByQuery()` → call `getMessagesAsConversation()` → push into `s.messages[]`
- Each turn's user and assistant messages are persisted immediately via `appendMessage()` calls wired into the chat flow
- Conversation history is **no longer duplicated** in the `memories` table (FTS5). `BuiltinMemoryProvider.syncTurn()` is now a no-op.

## Messages Table Schema + FTS5

```sql
CREATE TABLE IF NOT EXISTS messages (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id    TEXT NOT NULL,
    role          TEXT NOT NULL,
    content       TEXT,
    timestamp     REAL NOT NULL,
    token_count   INTEGER,
    active        INTEGER NOT NULL DEFAULT 1,
    compacted     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_messages_session
    ON messages(session_id, id);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content, tokenize='unicode61'
);
```

The FTS5 virtual table enables cross-session full-text search of conversation history. It is used by `BuiltinMemoryProvider.prefetch()` to provide relevant past conversation context in the system prompt.

## Methods on SQLiteSessionStore

### appendMessage(sessionId, role, content, metadata?)

Synchronous INSERT + FTS5 sync.

```typescript
appendMessage(sessionId, role, content, metadata?): void {
  const now = Date.now() / 1000;
  this.db.prepare(`INSERT INTO messages (...) VALUES (?, ?, ?, ?, ?, 1, 0)`)
    .run(sessionId, role, content, now, metadata?.token_count ?? null);
  if (content) {
    try {
      this.db.prepare(`INSERT INTO messages_fts(rowid, content) VALUES (last_insert_rowid(), ?)`)
        .run(content);
    } catch { /* best-effort */ }
  }
}
```

### getMessagesAsConversation(sessionId, limit?)

Returns `MessageLike[]` in chronological order for session recovery. Filters `active = 1` rows.

```typescript
getMessagesAsConversation(sessionId, limit = 50): MessageLike[] {
  const rows = this.db.prepare(`
    SELECT role, content FROM messages
    WHERE session_id = ? AND active = 1
    ORDER BY id ASC LIMIT ?
  `).all(sessionId, limit);
  return rows.map(r => ({ role: r.role, content: r.content }));
}
```

### searchConversation(query, limit?)

Cross-session full-text search via FTS5. Used by `BuiltinMemoryProvider.prefetch()` for memory context injection.

```typescript
searchConversation(query, limit = 5): string {
  const safe = query.replace(/['"]/g, "").replace(/[^\w\u4e00-\u9fff]+/g, " ");
  const rows = this.db.prepare(`
    SELECT m.role, m.content FROM messages_fts f
    JOIN messages m ON m.id = f.rowid
    WHERE messages_fts MATCH ? AND m.active = 1
    ORDER BY m.id DESC LIMIT ?
  `).all(safe, limit);
  if (rows.length === 0) return "";
  return `<memory-context>\n${rows.reverse().map(r => `${r.role === "user" ? "User" : "Assistant"}: ${r.content}`).join("\n")}\n</memory-context>`;
}
```

Both `appendMessage`, `getMessagesAsConversation`, and `searchConversation` are on the **`SessionStore` interface** (declared in `Types.ts`), so no `as any` or duck-type guards needed at call sites.

## Wiring in AgentRuntime.chat()

### 1. Session Recovery

```typescript
if (s.sessionStore) {
  const pastMessages = s.sessionStore.getMessagesAsConversation(existing.id, 50);
  if (pastMessages.length > 0) {
    s.messages.push(...pastMessages);
  }
}
```

Replaces the old hack that parsed `"User: ..." / "Assistant: ..."` from the `memories` table.

### 2. User Message Persistence

Right after `msgList.push({ role: "user", content: userContent })`:
```typescript
if (s.session?.id && s.sessionStore) {
  const contentStr = Array.isArray(userContent) ? JSON.stringify(userContent) : userContent;
  s.sessionStore.appendMessage(s.session.id, "user", contentStr);
}
```

### 3. Agent Loop Assistant Persistence

After each `messages.push({ role: "assistant", content: ... })`:
```typescript
if (this.session?.id && this.sessionStore) {
  this.sessionStore.appendMessage(this.session.id, "assistant", response.content || "");
}
```

Tool messages are **not** persisted — they're ephemeral per-turn context.

### 4. BuiltinMemoryProvider: Dual-Source Prefetch

In `Main.ts`, the builtin provider receives the session store:
```typescript
const builtinProvider = new BuiltinMemoryProvider(stores.memory);
memoryManager.addProvider(builtinProvider);
if (stores.sessions) {
  builtinProvider.setSessionStore(stores.sessions);
}
```

`prefetch()` now searches **both** stores:
1. `memoryStore.searchSync(query, 5)` — factual memories (memories table FTS5)
2. `sessionStore.searchConversation(query, 5)` — conversation history (messages table FTS5)

## Pitfalls

- **Unified data source**: Conversation history is ONLY in the messages table now. `BuiltinMemoryProvider.syncTurn()` is a no-op — don't add conversation-backfill logic there.
- **FTS5 backfill**: Pre-existing messages (before FTS5 was added) won't be in `messages_fts`. Run the backfill script manually when needed. See SKILL.md "Backfill FTS5 for Existing Messages".
- **StoreWorker triple-wiring**: If the app is running in worker-thread mode (rare, but possible), any new SessionStore method must be registered in THREE places: `StoreWorkerEntry.ts` (switch case), `StoreWorker.ts` (proxy), and `Types.ts` (interface). Miss one and the call silently returns empty data. See SKILL.md "StoreWorker Triple-Wiring Requirement".
- **Compression/rotation**: When compression rotates to a new session ID, messages after the rotation point are persisted under the new session ID. Old session messages remain orphaned.
- **Multimodal content**: `userContent` may be an array for image messages. Must JSON-stringify before persisting.
- **appendMessage void return**: `appendMessage()` is synchronous (`void`), but `StoreWorker` proxy fires-and-forgets via `worker.call()` which returns a `Promise`. The Promise is discarded — errors from FTS5 sync inside the worker are swallowed silently. If FTS5 failures need monitoring, the method signature would need to become `Promise<void>` and the proxy would need to await.

## Debug / Verification

```bash
# Check session DB — sessions + messages counts
cd D:\kexvim-dev && node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/kexvim.db');
const s = db.prepare('SELECT id, substr(chat_id,1,40) as chat, last_activity FROM sessions ORDER BY last_activity DESC').all();
for (const r of s) {
  const cnt = db.prepare('SELECT COUNT(*) as cnt FROM messages WHERE session_id = ?').get(r.id).cnt;
  console.log(r.id.slice(0,8), r.chat, 'msg_count:', cnt);
}
"
# FTS5 health
cd D:\kexvim-dev && node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/kexvim.db');
const fts = db.prepare('SELECT COUNT(*) as cnt FROM messages_fts').get();
const msg = db.prepare('SELECT COUNT(*) as cnt FROM messages').get();
console.log('messages:', msg.cnt, 'fts indexed:', fts.cnt);
"
# View last 20 messages
cd D:\kexvim-dev && node -e "
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('data/kexvim.db');
const rows = db.prepare('SELECT id, role, substr(content,1,80) as preview, session_id FROM messages ORDER BY id DESC LIMIT 20').all();
console.table(rows);
"
```
