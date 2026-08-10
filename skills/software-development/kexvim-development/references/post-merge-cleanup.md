# Post-Merge Cleanup Patterns

When merging external branches into sage (e.g., i18n language packs, parallel feature branches), always perform these checks after rebase.

## 1. Broken Imports

Merge commits can introduce imports from modules that don't exist in the target tree.

**Example**: `c1ff108` merged i18n branch which added `guardian/QQAdapter.ts` with:
```typescript
import { QQError, ALL_INTENTS, ... } from "../ErrorDefs";
```
`../ErrorDefs` didn't exist anywhere. Fix: if the symbols are defined locally in the same file (QQError class, ALL_INTENTS const), just remove the import line.

**Check**: `npx tsc --noEmit` immediately after rebase.

## 2. Duplicate Table Definitions

If two schema constants (`SCHEMA` + `SCHEMA_MESSAGES`) both have `CREATE TABLE IF NOT EXISTS messages (...)` with different columns, the first `IF NOT EXISTS` wins silently. The second definition's columns (`timestamp`, `token_count`, `active`, `compacted`, FTS5) are never created.

**Fix**: Merge all columns into one definition. Search for all `CREATE TABLE IF NOT EXISTS <tablename>` across ALL schema strings.

**Symptoms at runtime**: Methods write to columns that don't exist → SQL error on INSERT.

## 3. Duplicate Recovery/Redundant Logic

After merge, check for duplicated try/catch blocks that do the same thing (e.g., loading messages into `s.messages[]` at two points in AgentRuntime.chat()). The duplicate block that runs later is usually guarded by `if (s.messages.length === 0)` making it dead code — but it's still clutter.

## 4. QQError Merged Declaration

QQAdapter.ts has `export class QQError extends Error` locally defined. If a merge also adds `import { QQError } from "../ErrorDefs"`, TSC errors: "Individual declarations in merged declaration 'QQError' must be all exported or all local."

**Fix**: Remove the import line.

## 5. Duplicate Full-Buffer Persists

After merge, check for redundant message persistence loops (full msgList dump in post-turn handler) that run on every turn and duplicate all rows. The fix is to use per-message appendMessage calls (user/assistant/planner) only.

## Checklist

```bash
# After rebase
cd D:\kexvim-dev && npx tsc --noEmit
# If errors, check:
grep "Cannot find module\|not all exported or all local\|Missing.*from type" -
# Also grep for duplicate table definitions:
grep -n "CREATE TABLE IF NOT EXISTS" src/memory/SessionStore.ts
# Run the search tool:
search_files(pattern="ErrorDefs|ErrorConstants|_sessionStore", path="D:\kexvim-dev\src", file_glob="*.ts")
```
