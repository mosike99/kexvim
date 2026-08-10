# SessionSearchTool — SQLite FTS5 Query Pattern

## Architecture

SessionSearchTool queries kexvim's conversation DB (`kexvim.db`) for past sessions matching a user query. Uses SQLite FTS5 for fast full-text search, with LIKE fallback.

## DB Path Resolution (avoiding process.cwd() trap)

Three-layer fallback:
1. Constructor parameter `sessionDbPath` (injected by AgentRuntime from `config.sessionDir`)
2. Auto-read from `config.json` `paths.session_dir` or `paths.sessionDir`
3. Final fallback: `process.cwd() + "/data/kexvim.db"`

```typescript
constructor(sessionDbPath?: string) {
  this.sessionDbPath = sessionDbPath || readSessionDbPath();
}
```

## Query Modes

### Browse Mode (no query)
Return most recent sessions:
```sql
SELECT s.id, COALESCE(s.summary, s.id) AS title, s.created_at,
       (SELECT content FROM messages WHERE session_id = s.id AND role != 'tool' ORDER BY id DESC LIMIT 1) AS last_msg
FROM sessions s
ORDER BY s.updated_at DESC
LIMIT ?
```

### Search Mode (with query)
Priority: FTS5 first, LIKE fallback:

```typescript
const ftsRows = db.prepare(
  `SELECT DISTINCT m.session_id
   FROM messages_fts f
   JOIN messages m ON f.rowid = m.id
   WHERE messages_fts MATCH ?
   ORDER BY m.id DESC
   LIMIT ?`
).all(sanitizedQuery, limit * 3);

if (ftsRows && ftsRows.length > 0) {
  sessionIdRows = ftsRows;
} else {
  // Fallback: LIKE search
  sessionIdRows = db.prepare(
    `SELECT DISTINCT m.session_id
     FROM messages m
     WHERE m.content LIKE ? AND m.role != 'tool'
     ORDER BY m.id DESC
     LIMIT ?`
  ).all(`%${query}%`, limit * 3);
}
```

### Session Info Fetch
After deduplicating session IDs, fetch full info using dynamic IN clause:

```typescript
const sessionSubset = sessionIds.slice(0, limit);
const placeholders = sessionSubset.map(() => "?").join(",");
const queryParams = [`%${query}%`, ...sessionSubset];

results = db.prepare(
  `SELECT s.id, COALESCE(s.summary, s.id) AS title, s.created_at,
          (SELECT content FROM messages WHERE session_id = s.id AND role != 'tool' ORDER BY id DESC LIMIT 1) AS last_msg,
          (SELECT content FROM messages WHERE session_id = s.id AND content LIKE ? AND role != 'tool' ORDER BY id DESC LIMIT 1) AS match_snippet
   FROM sessions s
   WHERE s.id IN (${placeholders})
   ORDER BY s.updated_at DESC`
).all(...queryParams);
```

**Critical**: The `?` placeholder in `content LIKE ?` (inside the correlated subquery) must be the FIRST parameter in `queryParams`. SQLite binds params by position — the LIKE binds to `%${query}%`, then `sessionSubset` items bind to the `IN` clause placeholders.

## Bug History

1. **s.name didn't exist** (first version) — sessions table has no `name` column. Fixed: COALESCE(summary, id) AS title.
2. **const ftsResults.push()** (second version) — can't `.push()` on `const` array from `.all()`. Fixed: use `let sessionIdRows` variable instead.
3. **FTS vs LIKE logic** — initial version tried `ftsResults.push(...likeResults)` on a const. Fixed: use if/else with `let` variable.
4. **process.cwd() hardcoded** — initially hardcoded relative to cwd. Fixed: config injection with three-layer fallback.
