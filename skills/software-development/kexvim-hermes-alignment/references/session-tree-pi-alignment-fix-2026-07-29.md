# Pi Agent Session Tree Alignment Fix (2026-07-29)

## Problem

kexvim integrated Pi Agent's session tree (`parent_id`, `entry_type`, `active`, `compacted` on `messages` table) into an otherwise Hermes-aligned agent loop. Two bugs resulted:

1. **`appendMessage` didn't set `parent_id`** — all new messages were orphaned nodes, not linked into the tree
2. **`getMessagesAsConversation` used flat query** instead of walking the `parent_id` chain → non-message entries (compaction labels, model changes) with `role=null` polluted the LLM context

**Symptoms:** bot sends duplicate/rambling analysis, gets stuck mid-turn, repeats itself, appears "broken"

## Fix

### 1. `appendMessage` — Set `parent_id` to current leaf

```typescript
// Find current leaf (latest msg with no children)
const leaf = this.db.prepare(`
  SELECT id FROM messages
  WHERE session_id = ? AND active = 1
    AND NOT EXISTS (
      SELECT 1 FROM messages m2
      WHERE m2.session_id = messages.session_id AND m2.parent_id = messages.id
    )
  ORDER BY id DESC LIMIT 1
`).get(sessionId) as { id: number } | undefined;
const parentId = leaf?.id ?? null;

// Insert with parent_id
INSERT INTO messages (session_id, parent_id, role, content, ...)
VALUES (?, ?, ?, ?, ...)
```

This creates a linked chain: msg1 → msg2 → msg3 → ... (Pi Agent style).

### 2. `getMessagesAsConversation` — Walk `parent_id` chain

Instead of `WHERE active = 1 ORDER BY id DESC`:

```typescript
// Pi Agent getPathToRootOrCompactionEntries equivalent
// 1. Find leaf (same NOT EXISTS query as above)
// 2. Walk up parent_id chain to root
// 3. On compaction entry: use firstKeptEntryId to skip compacted portion
// 4. Skip entry_type != 'message' entries
// 5. unshift() into result array for chronological order

while (currentId && !seen.has(currentId) && entries.length < limit) {
  const row = db.prepare(`SELECT id, parent_id, entry_type, role, content,
    tool_call_id, tool_calls, first_kept_entry_id
    FROM messages WHERE id = ? AND session_id = ?`).get(currentId, sessionId);

  if (row.entry_type === 'compaction') {
    // Jump over compacted section
    stopAtId = row.first_kept_entry_id;
    currentId = row.parent_id;
    continue;
  }
  if (row.entry_type === 'message' && row.role) {
    entries.unshift({ role: row.role, content: row.content, ... });
  }
  currentId = row.parent_id; // walk up
}
```

### 3. Compaction handling for session-level rotation

`compressAndRotate()` (from `ConversationCompression.ts`) creates a new session, so the current session's messages don't include compaction entries. The in-session compaction walk is a safety net.

## Pi Agent Reference

Pi Agent's `getPathToRootOrCompactionEntries` (in `packages/storage/sqlite-node/src/sqlite/storage/index.ts`):

```typescript
private async getPathToRootOrCompactionEntries(leafId: string | null) {
  let current = await this.getEntry(leafId);
  while (current) {
    path.unshift(current);
    if (current.type === "compaction") {
      if (current.retainedTail) break;            // stop at compaction
      stopAtEntryId = current.firstKeptEntryId;   // jump over
    }
    if (!current.parentId) break;
    current = await this.getEntry(current.parentId);
  }
}
```

Key differences from the flat query pattern:
- Uses `active_leaf_id` from `sessions` table as starting point (not a SQL find-the-leaf query)
- `entry_seq` provides ordering within branches
- `branch_entries` table tracks branch membership for tree navigation
- All entry types stored with JSON `payload` (not separate columns)

## Testing

After fix:
1. `npx tsc --noEmit` — type check passes
2. `npm start` — bot starts, receives message, sends ONE final reply (no interim thinking)
3. Conversation history on restart should load complete context
