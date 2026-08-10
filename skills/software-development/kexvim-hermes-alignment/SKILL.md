---
name: kexvim-hermes-alignment
description: "对齐 kexvim 与 Hermes 功能实现（源码对照法）"
license: MIT
version: 2.1.0
author: agent
metadata:
  kexvim:
    tags: [kexvim, hermes, alignment, source-comparison]
    related_skills: [kexvim-development, kexvim-session, kexvim-system-prompt]
---

# kexvim-Hermes Alignment Audit

kexvim 是 Hermes 的 TypeScript 移植版（QQ Bot 场景）。当用户报告行为异常时，需要将 Hermes 作为参考实现进行对齐检查。

## 工作流

### 1. 问题确认

- 确认用户描述的症状（"session_search 不可用"、"技能不自动保存"、"子 Agent 不工作"）
- **如果用户提供了证据（聊天记录、错误输出、截图），先研究证据，再读代码。不要跳过证据去猜。**
- 如果是 kexvim 报错信息，直接从错误入手

### 2. 找到参考实现

移植/对齐时优先找以下参考源：

- **Hermes**（Python agent）：`~/.hermes/hermes-agent/`
- **Pi**（Coding agent TS）：NAS `/mnt/nas/pi-main.zip` → 解压到 `/tmp/pi-source/pi-main/`

**铁律：改 kexvim 之前，必须读参考源码。不读不猜不想象。**

### 3. 差异比较方法

1. **功能存在性** — kexvim 有对应模块吗？
2. **注册路径** — 功能在 AgentRuntime 的构造函数/工具注册中注册了吗？
3. **配置传递** — 配置项从 config.yaml → Config.normalizeConfig() → Main.ts → AgentRuntime 传递完整吗？
4. **系统提示注入** — 对应的 GUIDANCE 文本注入到 system prompt 了吗？
5. **条件守卫** — 注入条件（model 名匹配、工具存在性、配置开关）是否正确？

### 3b. 配置默认值对齐陷阱：config.yaml 显式值盖掉代码默认（2026-08-03）

用户报"iteration 13/20、hermes 是 90"实例——差异不在代码默认，而是 `data/config.yaml` 显式写了 `agent.max_iterations: 20`，显式配置优先级高于代码默认。对齐默认值流程：

1. **先查 data/config.yaml**：用户报的数值（迭代上限、max_tokens、超时等）先从运行时配置找，别急着改代码——显式值盖掉代码默认是最高频根因
2. **再 grep 代码默认全部来源点**（该实例一次改 5 处）：`Config.normalizeConfig()` 默认值、`AgentRuntime` 兜底 `?? N`、`InstallKexvim.ts` 安装模板（新装用户用）、过时注释（误导不报错，顺手修）
3. **对 hermes 参考值**：`run_agent.py:443` 主循环 `max_iterations=90`；delegate 委派子任务默认 50（kexvim DelegateTaskTool=50 ✅ 一致，勿动）
4. 改完 `tsc --noEmit` + `build:dev` 后，用 `findstr /c:"maxIterations: config.maxIterations ?? 90" dist\dev.mjs` 验证产物含新值（minify 保留字符串字面量，详见 kexvim-dev-build-restart）
5. `data/` 目录不被 git 跟踪（含密钥）：config.yaml 的本机改动重启才生效，提交信息里注明"运行时值需重启生效"，代码提交 ≠ 运行值已变

### 关键陷阱：system prompt 层级 vs AGENTS.md

**诚实规则（不编造、不胡说、搜索零结果要交叉验证）必须写在 `DEFAULT_AGENT_IDENTITY`（`PromptBuilder.ts:32`）**，不是只改 `AGENTS.md`。

- `DEFAULT_AGENT_IDENTITY` → 每次 LLM 调用都出现，最高优先级
- `AGENTS.md` → 注入到 Project Context 节，可选、优先级低
- 两者都要改，但 system prompt level 才是硬约束

### 诚实规则原文（copy-paste 到 `DEFAULT_AGENT_IDENTITY`）

```typescript
static readonly DEFAULT_AGENT_IDENTITY =
\`You are Kexvim — an intelligent AI agent for conversation, code, and task automation.
You are helpful, knowledgeable, and direct. You assist users with a wide
range of tasks including answering questions, writing and editing code,
analyzing information, creative work, and executing actions via your tools.
You communicate clearly, admit uncertainty when appropriate, and prioritize
being genuinely useful over being verbose unless otherwise directed below.
Be targeted and efficient in your exploration and investigations.

NEVER substitute plausible-looking fabricated output (made-up data, invented
file contents, synthesized API responses) for results you couldn't actually
produce. Reporting a blocker honestly is always better than inventing a result.

When a search tool returns zero results, do NOT conclude "not found" without
cross-validating first — use a different pattern, or read the target file
directly with read_file.\`;
```

对齐检查清单（逐项核对 Hermes 原版）：
1. `admit uncertainty when appropriate` ✓
2. `NEVER substitute plausible-looking fabricated output` ✓
3. `Reporting a blocker honestly is always better than inventing a result.` ✓
4. 搜索零结果时交叉验证 ✓

### 4. 核心对比映射

| Hermes 概念 | kexvim 等价物 | 对齐状态 |
|---|---|---|
| `agent_init.py` | `AgentRuntime` 构造函数 | ✅ 已对齐 |
| `system_prompt.py` | `PromptBuilder.build()` | ✅ 已对齐 |
| `prompt_builder.py` (MEMORY/SKILLS/SESSION_SEARCH) | `PromptBuilder.ts` | ✅ 已对齐 |
| `turn_finalizer.py` | `chat()` 末尾触发 | ✅ 已对齐 |
| `background_review.py` | `BackgroundReviewer.ts` | ✅ in-process 直接调用 |
| `background_review.py L779`（继承父 agent system prompt） | `parentSystemPrompt` 传参 | ✅ |
| `turn_context.py` (计数器恢复) | ✅ session 恢复时按 `%` 重建双计数器 |
| `conversation_loop.py` (_emit_interim_assistant_message) | `agentLoop()` 中 tool_use 事件 flush | ⚠️ QQ 上发 interim = 刷屏 |
| `run_agent.py` (_fire_stream_delta) | `invokeLLM()` 中 onStream 回调 | ⚠️ QQ 上需要关掉 |
| `run_agent.py:443` `max_iterations=90` | `AgentRuntime.ts` `config.maxIterations ?? 90`；delegate 默认 50 = `DelegateTaskTool` | ✅ 08-03 对齐（config.yaml 曾显式 20 盖掉代码默认，已归一 90） |
| `gateway/run.py` (_interim_assistant_cb) | `Main.ts` 中 `statusCallback` → `sendReply` | ❌ QQ 上 interim 变成聊天消息 |
| `memory.profiles.default.nudge_interval` | `agent.memory_nudge_interval` | ✅ |
| `skills.creation_nudge_interval` | `agent.skill_nudge_interval` | ✅ |
| `prompt_builder.py SKILLS_GUIDANCE` | `PromptDefaults.SKILLS_GUIDANCE` | ✅ |
| `paths.user_data_dir`（配置项） | `userDataDir` Config 字段 | ✅ `<项目根>/data/` 默认 |
| `config.yaml` snake_case → camelCase 映射 | `Config.normalizeConfig()` | ✅ 修复前读不到，已修 |
| 技能双目录：公共 + 用户 | `SkillManager(sharedSkillsDir?)` | ✅ |
| Pi 会话树（JSONL→SQLite 移植） | `SessionStore`树方法 + `Compactor` | **❌ 与 Hermes 线性模型冲突** |
| Pi 压实（切割点+LLM摘要） | `Compactor.ts` | ⚠️ compaction 条目 role=null 混入消息列表 |
| Pi 物化统计（computeStats） | `SessionStore.computeStats()` | ✅ 不影响运行时 |
| Pi 分支摘要（generateBranchSummary） | `buildBranchSummaryPrompt()` + fork 时调用 | ✅ 不影响运行时 |
| Pi 增量压实（update compaction） | `buildUpdateCompactionPrompt()` | ✅ 不影响运行时 |
| Pi TUI 交互式树选择器 | `TuiAdapter` raw mode（↑↓选节点） | ✅ |
| Pi 条目类型（label/model_change/thinking_level_change） | `EntryType` 完整实现 | **❌ 见"会话树冲突"章** |
| Pi 标签系统 | `SessionStore` label字段 + `/label`命令 | ✅ 不影响运行时 |
| Pi 模型/推理级别追踪 | `SessionStore` model_id/thinking_level字段 + `/model`命令 | ✅ 不影响运行时 |

### 5. 路径约定

| 变量 | 当前值 |
|---|---|
| 代码目录 | `<项目根>/` |
| 日志 | `<项目根>/data/kexvim.log` |
| Git 远程 | `gitee.com:moscowzk/kexvim-dev.git` / `kexvim.git` |
| Hermes 参考 | `~/.hermes/hermes-agent/agent/` |

### 7. 修复后验证

### 8. Critical: Interim Messages on Chat Platforms

**Hermes targets CLI/REPL where stderr messages are fine. kexvim runs on QQ where every message is visible.**

When Hermes' streaming pattern (`_fire_stream_delta` → `_emit_interim_assistant_message`) is mapped to `statusCallback` → `msg.sendReply`, **every interim thinking fragment becomes a visible chat message.** The user sees:

```
[kex] 关键发现！两条日志：...
[kex] 🔍 正在search_files...
[kex] 让我查 WorkerCoordinator...
[kex] <final reply>
```

**This creates three problems:**
1. **Wall of thinking** — 5-15 messages per turn, all self-referential analysis
2. **No conversation history for interim** — interim messages are NOT added to `messages[]`, so LLM doesn't know what it already said. User says "继续" → new turn starts from scratch → same analysis repeated
3. **No edit support** — QQ has no "edit last message" — each interim is a permanent chat message

**All interim paths must be disabled on chat platforms:**
1. `Main.ts` `statusCallback` → set to `undefined` (removes the `sendProgress` lambda)
2. `agentLoop` line 1064 (`flush stream buffer before tool calls`) — gated on `cb`, becomes no-op when cb is undefined
3. `AgentRuntime` line 864 (`onStream` tool_use callback that flushes buffer) — gated on `cb`

**If progress indicators are needed, implement a platform-level typing indicator** (QQBotAPI v2 has no native typing indicator; OneBot does with `send_msg` action "typing"). Never use text messages as progress indicators.

**Fix applied 2026-07-29**: Removed `statusCallback` from Main.ts. Bot goes silent while thinking, sends only the final reply.

### 9. Methodology: Study Evidence First

**Correction history:** When the user reported "kex is broken, duplicate replies, gets stuck after replying", I jumped into code analysis without first studying the actual conversation log the user provided. I spent many turns guessing at the root cause (streaming, session guard, tool timeout) when the conversation log already showed the exact symptoms — interim thinking sent as messages, bot repeating itself, getting stuck mid-analysis. The user had to say "先仔细研究下我跟她的对话" multiple times.

**Rule:** When the user reports a behavior anomaly and provides evidence (chat log, error output, screenshot), **study that evidence first**. Don't jump to code reading, don't guess. The evidence often reveals the symptom directly. Only after confirming what the user actually sees should you look at code.

### 10. Session Tree vs Hermes Linear Model — Architecture Conflict

**Root cause of "kex is broken":** Pi Agent's session tree (messages table with `parent_id`, `entry_type`, `active`, `compacted` fields) was integrated into kexvim's Hermes-based agent loop. This creates an architecture conflict that manifests as:

#### Conflict 1: Non-message entries leak into conversation recovery

`getMessagesAsConversation()` queries:
```sql
SELECT role, content, tool_call_id, tool_calls
FROM messages
WHERE session_id = ? AND active = 1
ORDER BY id DESC LIMIT ?
```

This loads ALL rows with `active=1`, including compaction entries (`entry_type='compaction'`, `role=null`), labels, model changes, branch summaries. These become `{role: null, content: null}` in the MessageLike array, polluting the LLM context.

**Hermes approach:** messages table is pure append-only — no entry_type/active fields, no compaction marker rows. When compression triggers, Hermes creates a CHILD session via `parent_session_id` and the old session is sealed. No inline markers.

#### Conflict 2: Compression rotation can return wrong session on recovery

`compressAndRotate()` updates old session A's `updatedAt`/`lastActivity`, then creates new session B. On process restart, `recover()` does `ORDER BY last_activity DESC LIMIT 1`. If A's timestamp is slightly newer than B's (because update happens after create), recovery returns A instead of B. Agent loads old session with compaction markers and stales messages.

**Hermes approach:** session metadata (`sessions` table) is purely metadata (source, chat_id, timestamps). Compaction creates a clean child session. No inline message-level markers.

#### Fix Direction

The tree functionality should be at **session level only** (via `parent_session_id`, same as Hermes), NOT at the message level. Specific changes:

1. **Remove `parent_id`, `entry_type`, `active`, `compacted` from `messages` table** — messages are pure append-only linear history
2. **Session forking creates a new session** with `parent_session_id` pointing to the fork point's session (already done, works correctly)
3. **Remove `WHERE active = 1` from `getMessagesAsConversation`** — no messages should ever be inactive
4. **Keep tree metadata in `sessions` table** — labels, model changes, summaries attached to the session, not as rows in messages

#### Pitfall: Don't Use Timeouts as a Crutch

When the bot gets stuck after tool calls, adding a 30s timeout (`Promise.race` with a timer) is a band-aid, not a fix:
- User said "最好不要主要用超时这种兜底，明显是有问题。这样兜底不能解决问题，而且体验会奇差"
- If the LLM isn't generating tool calls or the tools aren't executing, the root cause is in the message format/registration/session state
- Always find the actual broken path (wrong message format, missing registration, session tree corruption) before considering timeouts

#### Fix Applied 2026-07-29

Three commits on `kexvim-dev` (`eb75bd9` → `99f5838`):

1. **`appendMessage` sets `parent_id`** — links each new message to the current leaf (the latest message with no children), building a proper parent_id chain
2. **`getMessagesAsConversation` walks parent_id chain** — leaf-to-root walk collecting only `entry_type='message'` entries with valid roles
3. **Compaction jump** — when hitting a compaction entry, uses `firstKeptEntryId` to skip the compacted section (Pi Agent `getPathToRootOrCompactionEntries` pattern)

**Schema unchanged** — all tree metadata fields (parent_id, entry_type, active, compacted, etc.) remain. Only the query logic changed. Tree UI features (fork/label/printTree/loadTree) unaffected.

**See** `references/session-tree-pi-alignment-fix-2026-07-29.md` for code snippets and Pi Agent reference.

### 11. Methodology: No Band-Aids

When the bot gets stuck after tool calls, don't add timeouts as a first response. The user specifically rejected this: "最好不要主要用超时这种兜底，明显是有问题。这样兜底不能解决问题，而且体验会奇差" — timeouts are a band-aid, not a fix.

If the LLM isn't generating tool calls or tools aren't executing, find the actual broken path:
- Wrong message format in conversation history (compaction entries leaking in)
- Tool registration missing or incorrect
- Session tree structure causing context loss
- Role alternation violation (two consecutive user/assistant messages)

**Never add a timeout before finding the root cause.**

- 编译检查：`cd <项目根> && npx tsc --noEmit`
- 重启：`npm run restart`
- 检查日志 `tail -5 <项目根>/data/kexvim.log` 确认上线

## 参考文件

- `references/5s-delay-and-timer-cancel.md` — 同 key 限流 5 秒延迟计时器与取消逻辑
- `references/agent-tool-calls-fix.md` — Agent.ts `tool_calls` 缺失导致 DeepSeek 400 的根源与修复
- `references/alignment-cases-2026-07-24.md` — 2026-07-24 对齐案例集
- `references/correct-review-prompt.md` — 修正后的 COMBINED_REVIEW_PROMPT
- `references/hermes-qq-message-flow.md` — Hermes QQ 消息发送流程源码级走查
- `references/prompt-alignment-findings-2026-07-27.md` — 2026-07-27 prompt 对齐发现
- `references/session-tree-pi-alignment-fix-2026-07-29.md` — Pi Agent parent_id 链修复：appendMessage 设 parent_id、getMessagesAsConversation 沿链走、compaction 跳转
- `references/system-prompt-alignment-2026-07-28.md` — System prompt 层级对齐、诚实规则、search_files regex 陷阱、公开仓不发 skills
