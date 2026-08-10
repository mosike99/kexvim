# Pi 会话树架构（已实现）

已从 Pi（`/mnt/nas/pi-main.zip`）移植到 kexvim。将平铺消息列表改为带 parentId 的树结构，支持分支、压实、标签、模型切换追踪。

## 数据模型

**messages 表新增列**（`SessionStore.ts`）：

| 列 | 类型 | 说明 |
|----|------|------|
| `parent_id` | INTEGER | 父条目 ID（null=根节点） |
| `entry_type` | TEXT DEFAULT 'message' | 条目类型 |
| `summary` | TEXT | 压实摘要 |
| `first_kept_entry_id` | INTEGER | 压实后保留的起始条目 |
| `tokens_before` | INTEGER | 压实前 token 数 |
| `estimated_tokens_after` | INTEGER | 压实后估计 token 数 |
| `details` | TEXT | JSON 扩展数据 |
| `label` | TEXT | 标签文字 |
| `target_id` | INTEGER | 标签目标条目 ID |
| `provider` | TEXT | 提供商名 |
| `model_id` | TEXT | 模型 ID |
| `thinking_level` | TEXT | 推理级别 |

**sessions 表新增列**：
- `parent_session_id` TEXT — 分叉的父会话 ID

**EntryType**（`Types.ts`）：
- `"message"` — 普通对话消息
- `"compaction"` — 压实摘要
- `"branch_summary"` — 分叉记录
- `"label"` — 条目标签/书签
- `"model_change"` — 模型切换
- `"thinking_level_change"` — 推理级别切换

## 核心方法（`SessionStore.ts`）

### `appendEntry(sessionId, entryType, parentId, role?, content?, extra?) → number`
Pi 的 `sessionManager.appendEntry()` 等价。插入树节点并自动同步 FTS 索引。

### `loadTree(sessionId) → { entries, currentId }`
从叶子节点沿 parent_id 链走到根，返回有序数组。等价于 Pi 的 `buildSessionPath()`。

### `buildContext(sessionId) → MessageLike[]`
压实感知的上下文构建。如果路径上有 compaction 条目，从 `firstKeptEntryId` 开始保留，之前的用 compaction 摘要替换。等价于 Pi 的 `buildContextEntries()` + `sessionEntryToContextMessages()`。

### `fork(sessionId, forkEntryId) → ForkResult`
创建新会话，设 `parent_session_id`，在原会话插入 `branch_summary`，在新会话插入对应的 `branch_summary` 作为第一个条目。等价于 Pi 的 `branchWithSummary()` + `createBranchedSession()`。

### `printTree(sessionId) → string`
递归遍历树，格式化输出缩进树形文本，含 emoji 图标：
- 🧑 用户消息
- 🤖 助手回复
- 📦 压实条目
- ⤴ 分支摘要
- 🏷️ 标签
- 🤖 模型切换
- 🧠 推理级别切换

### `computeStats(sessionId) → SessionStats`
遍历所有条目计算物化统计：消息数、token 用量、当前模型/推理级别、标签。

## 压实（`Compactor.ts`）

参照 Pi 的 `packages/coding-agent/src/core/compaction/compaction.ts`。

### `entryToMessage(entry: SessionEntry) → MessageLike | null`
将树条目转换为 MessageLike，用于 token 估算和摘要提示构建。处理 message/compaction/branch_summary 三种类型。

### `findCutPointInEntries(entries, startIdx) → index`
在树条目数组中从后往前遍历，从 `startIdx` 开始查找切割点。累积 token（chars/4 启发式），超 `KEEP_RECENT_TOKENS`（20K）后返回。不切在 tool 消息处。等价于 Pi 的 `findCutPoint()`。

### `compact(store, sessionId, getSummary?) → CompactionPlan | null`
1. 调用 `buildContext` 获取当前上下文
2. 调用 `findCutPointInEntries` 找到切割点
3. 用 `getSummary` 回调（或默认统计摘要）生成摘要，支持 `previousSummary` 增量压实
4. 调用 `appendEntry` 插入 compaction 条目

### `shouldCompact(contextTokens, contextWindow?) → boolean`
检查是否应触发压实：`tokens > contextWindow - 16384`。

### Token 估算
- 字符→token：`Math.ceil(chars / 4)`（同 Pi 的 `estimateTokens()`）
- 图片：80 chars 估一个
- 默认上下文：128K tokens
- 保留 token：16K（reserve）+ 最近 20K（keep_recent）

### LLM 摘要提示

**常量**：`SUMMARIZATION_SYSTEM_PROMPT = "你是一个对话摘要助手。请根据用户提供的对话生成结构化中文摘要。"`

**初始压实** — `buildCompactionPrompt(messages)`：Pi 风格的 `## Goal / ## Progress / ## Key Decisions / ## Next Steps`。

**增量压实（update compaction）** — `buildUpdateCompactionPrompt(messages, previousSummary)`：Pi 的 `UPDATE_SUMMARIZATION_PROMPT` 等价。在已有摘要基础上合并新消息，RULES：保留已有信息、添加新进展、更新进度状态、保留精确路径/函数名/错误信息。

**分支摘要** — `buildBranchSummaryPrompt(messages)`：分叉时生成，格式 `## Goal / ## Progress (Done/Unfinished) / ## Key Decisions / ## Next Steps`。

### 压实摘要器在 Main.ts 中的使用

```typescript
const summarizer = async (msgs: MessageLike[], previousSummary?: string) => {
  const prompt = previousSummary
    ? buildUpdateCompactionPrompt(msgs, previousSummary)
    : buildCompactionPrompt(msgs);
  const adapter = registry.resolve("deepseek", "deepseek-chat");
  const result = await (adapter as any).chat([
    { role: "system", content: SUMMARIZATION_SYSTEM_PROMPT },
    { role: "user", content: prompt },
  ], undefined, 50, 0.3);
  return result?.choices?.[0]?.message?.content?.trim();
};
```

## 命令路由（`Main.ts`）

在消息路由层拦截（不用 Guardian），`repair/` 检查之后、`runtime.chat()` 之前：

| 命令 | 动作 |
|------|------|
| `/tree` | 显示当前会话树 |
| `/fork N` | 在条目 N 处分叉 |
| `/compact` | 手动压实（LLM 摘要） |
| `/label N text` | 标记条目 N |
| `/model provider modelId` | 记录模型切换 |

自动压实：每条正常消息回复后 fire-and-forget 异步触发。

## TUI 交互式树导航

`TuiAdapter` 在用户输入 `/tree` 时进入 raw mode：

1. `process.stdin.setRawMode(true)` 捕获上下键
2. `buildFlatTree()` 从 `printTree()` 的文字输出解析成 `FlatTreeNode[]`
3. ↑↓ 移动光标（`this.treeCursor`）
4. Enter 退出树模式，返回普通 readline
5. q / Esc 退出
6. `renderTree()` 使用 `>` 指示器

关键文件：`packages/tui/src/TuiAdapter.ts`

## DB Migration 模式

### 问题：CREATE INDEX 依赖新增列

当旧表通过 `CREATE TABLE IF NOT EXISTS` 加载（空操作），而表内 `CREATE INDEX` 引用了旧表没有的列时，SQLite 抛 `no such column`，整个 `exec()` 失败，后面的 ALTER TABLE migration 根本跑不到。

### 修复

把 `CREATE INDEX` 从 `SCHEMA_MESSAGES` 中拆出，在 ALTER TABLE 之后单独执行：

```typescript
const SCHEMA_MESSAGES = `CREATE TABLE IF NOT EXISTS messages (..., parent_id INTEGER, ...);`;  // 不含索引
const SCHEMA_MESSAGES_INDEXES = `CREATE INDEX IF NOT EXISTS idx_messages_parent ON messages(session_id, parent_id);`;

// constructor:
this.db.exec(SCHEMA_MESSAGES);
for (const col of [...]) { try { this.db.exec(`ALTER TABLE ... ADD COLUMN ${col} TEXT`); } catch {} }
try { this.db.exec(SCHEMA_MESSAGES_INDEXES); } catch {}  // 列存在后才建
```

同理，`CREATE VIRTUAL TABLE messages_fts` 的 FTS 定义也要拆开，避免依赖不存在的表结构。

## 与 Pi 的差异

| 方面 | Pi（JSONL 文件） | kexvim（SQLite） |
|------|------------------|-----------------|
| 存储 | 每行 JSON 的 `.jsonl` 文件 | 单一 `kexvim.db` 的 `messages` 表 |
| Entry ID | UUIDv7 字符串 | SQLite auto-increment 整数 |
| 消息格式 | 嵌套 `AgentMessage` 对象 | 平铺列（role, content, tool_calls 等） |
| 加载 | `loadEntriesFromFile()` 全文件解析 | `loadTree()` SQL 查询叶子→根 |
| 上下文构建 | `buildSessionContext()` 内存遍历 | `buildContext()` SQL 层遍历 |
| 迁移 | v1→v2→v3 JSON schema 升级 | ALTER TABLE ADD COLUMN + `_migrateParentIds()` |
| 分支摘要 | `generateBranchSummary()` LLM 生成 | 简单文字 `branch_summary` |
| 物化统计 | — | `computeStats()` |
| 树选择器 | TUI 上下键交互式选择 | `TuiAdapter` raw mode（同 Pi） |
| 标签 | `LabelEntry` 可清空 | `appendEntry("label")`（同 Pi） |

## 关键设计决策

1. **SQLite 不是 JSONL** — Pi 的 JSONL 文件适合 CLI 单用户，kexvim 是多平台 QQ Bot，SQLite 更适合并发和 FTS5
2. **命令在 Main.ts 路由，不在 Guardian** — Guardian 是 `repair/` 专用维修通道
3. **压实不删除数据** — 完整会话在磁盘上，`/tree` 仍可回溯到压实前的点
4. **Entry ID 用整数** — SQLite auto-increment 比 UUIDv7 更高效
