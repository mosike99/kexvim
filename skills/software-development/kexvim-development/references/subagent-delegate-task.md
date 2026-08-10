# Sage Subagent / DelegateTask Architecture

## Overview

Ported from Hermes `tools/delegate_tool.py`. Sage's implementation went through three phases:

**Phase 1 (initial)**: Hand-written lightweight loop in `DelegateTaskCore.ts` — manually called `parent.llm.chat()`, parsed tool calls, executed tools, and collected results.

**Phase 2 (createSubagent existed but was dead code)**: `AgentRuntime.createSubagent()` was added but `DelegateTaskCore.runSubagent()` still used the hand-written loop. Found during code review (2026-07-23).

**Phase 3 (current, Hermes-aligned)**: `runSubagent()` calls `parent.createSubagent()` (from `SubagentParentRuntime` interface) to build a full `AgentRuntime`, then calls `child.chat()`. The hand-written loop is removed.

## Key Files

| File | Purpose |
|------|---------|
| `src/tool/DelegateTaskTool.ts` | Tool handler — parameter schema, task normalization, depth/concurrent limits |
| `src/tool/DelegateTaskCore.ts` | Subagent runner — calls `parent.createSubagent()` + `child.chat()` |
| `src/inference/SubagentManager.ts` | Singleton for background async subagent lifecycle |
| `AgentRuntime.ts` | `createSubagent()`, `injectSubagentResults()`, `subagentMode`/`skipTools` config |

## AgentRuntime Config for Subagents

```typescript
skipTools?: string[];     // filter tools (leaf agents exclude delegate_task)
subagentMode?: boolean;   // skip memory/session/skills/planner/curator
```

## AgentRuntime.createSubagent()

```typescript
static createSubagent(parent, goal, context, depth, isLeaf): AgentRuntime {
  const childPrompt = isLeaf
    ? `leaf subagent at depth ${depth}. CANNOT delegate.`
    : `orchestrator subagent at depth ${depth}. Full tools including delegate_task.`;
  const skipTools = isLeaf ? ["delegate_task"] : [];
  return new AgentRuntime({
    llm: parent.llm,
    systemPrompt: childPrompt + `\n\nGoal: ${goal}\n${context}`,
    maxIterations: 15,
    skipTools,
    subagentMode: true,
  });
}
```

## SubagentParentRuntime Interface (bridge between AgentRuntime and DelegateTaskTool)

Defined in `DelegateTaskCore.ts`:

```typescript
export interface SubagentParentRuntime {
  llm: { chat(req: any): Promise<any> };
  tools: { all(): ToolHandler[] };
  /** Factory: create a full AgentRuntime subagent instance. */
  createSubagent(
    goal: string, context: string | undefined, depth: number, isLeaf: boolean,
  ): { chat(input: string): Promise<{ content: string; toolCalls: any[] }> };
}
```

`getSubagentParentRuntime()` in `AgentRuntime.ts` bridges to `AgentRuntime.createSubagent()`.

## Execution Flow

### Async (Top-Level, depth=0)

parent LLM → delegate_task goal/context → DelegateTaskTool.execute()
  → depth check → normalize tasks
  → SubagentManager.execute() per task (fire-and-forget promise)
  → return handle immediately
    ↓
  subagent runs via AgentRuntime.createSubagent() + child.chat()
    → result → SubagentManager.completed[]
    ↓
next AgentRuntime.chat() turn
  → injectSubagentResults() → pollSession() → inject as user message (via push, not unshift)
  → parent LLM sees result

### Sync (Nested, depth>0 — orchestrator subagents)

Same flow but synchronous — Promise.all(), results returned directly.

## Code Review Findings (2026-07-23)

The Phase 2 implementation had `createSubagent()` as dead code. The hand-written loop in `runSubagent()` was never replaced. Code review identified:

1. **[Critical] `createSubagent()` was dead code** — `runSubagent()` still used hand-written loop. Fixed by refactoring `runSubagent()` to call `parent.createSubagent()`.
2. **[Medium] `injectSubagentResults()` used `unshift`** — injected results at the BEGINNING of msgList, breaking message timeline. Fixed to `push`.
3. **[Minor] `_cap_delegate_task_calls` hardcoded `DEFAULT_MAX_CHILDREN=3`** — not reading from config. Fixed to read `config.json delegation.max_concurrent_children`.
4. **[Style] `require("node:fs")`** — inconsistent with ESM import style. Fixed to `import * as fs`.

## Hermes Alignment

| Feature | Hermes | Sage |
|---------|--------|------|
| Child instance | `AIAgent(quiet_mode=True)` | `AgentRuntime.createSubagent()` — actually called |
| Leaf tool filter | `enabled_toolsets` | `skipTools: ["delegate_task"]` |
| Async dispatch | `dispatch_async_delegation_batch` | `SubagentManager.execute()` |
| Result re-entry | `completion_queue` → forge new turn | `pollSession()` → inject as user msg (push, not unshift) |
| Depth limit | `max_spawn_depth` | config.json `delegation.max_spawn_depth` |
| Concurrent limit | `max_concurrent_children` | config.json `delegation.max_concurrent_children` |
| String tasks recovery | `_recover_tasks_from_json_string` | inline in DelegateTaskTool |
| Call capping | `_cap_delegate_task_calls` | inline in agentLoop, reads from config |
| Background param | DEPRECATED/IGNORED | same |
| Session tracking | per-child session_id | injected via currentSessionId |
