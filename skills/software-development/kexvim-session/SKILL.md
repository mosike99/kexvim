---
name: kexvim-session
description: Kexvim 会话持久化模型 — Hermes 线性对齐，扁平消息查询，无 tree 污染
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, session, persistence, sqlite, hermes-alignment]
    related_skills: [kexvim-session-runtime, kexvim-hermes-alignment]
---

# Kexvim Session Model

## 核心原则

Hermes 对齐：**线性 append-only 消息列表，不走 parent_id 链。**

```
session (SQLite sessions 表)
  └── messages (SQLite messages 表)
        ├── msg 1 (role: user)
        ├── msg 2 (role: assistant)  
        ├── msg 3 (role: tool)
        └── ...
```

**显示层标注表（2026-08-11 加，不影响上下文模型）**：web 任务级会话树新增 `task_nodes` 表（startTaskNode/completeTaskNode/getTaskTree，AgentRuntime.chat 运行时打标，仅 web 会话）——**它是显示层注解，不进 `getMessagesAsConversation`、不污染 LLM 上下文**；消息级 parent_id 链仍只由 web 渠道写（fork 用，详见 kexvim-web-ui「任务级会话树」节）。

## LLM 上下文查询

**唯一正确做法** — `getMessagesAsConversation()`:

```sql
SELECT role, content, tool_call_id, tool_calls
FROM messages
WHERE session_id = ? AND entry_type = 'message' AND role IS NOT NULL AND active = 1
ORDER BY id DESC
LIMIT ?
```

3 个过滤条件的含义：

| 条件 | 作用 |
|------|------|
| `entry_type = 'message'` | 排除 compaction/label/model_change 等非消息条目 |
| `role IS NOT NULL` | 排除 entry_type 未正确设置的非消息条目 |
| `active = 1` | 排除已标记为非活动路径的条目（当前无人设置 active=0，为未来预留） |

**不要做**：
- ❌ 走 parent_id 链从叶子走到根（旧数据链断裂，只返回 1-2 条消息）
- ❌ 用 `ORDER BY id` 不反转（返回顺序不对）
- ❌ 不加 entry_type 过滤（非消息条目带 role=null 混入上下文）

## getMessagesAsConversation 后处理（2026-08-10 增强，恢复安全关键）

SQL 之后、返回给 LLM 之前有两步后处理（旧会话数据自愈；重启后恢复上下文不再 400/退化）：

1. **闭合工具链**：assistant 带 tool_calls 须被后续 role=tool 消息按序闭合——孤立 tool 丢弃；末尾未闭合的 assistant 剥离 tool_calls（content 空则整条删）。防「回合中断残留（assistant 已落库、tool 结果未落库）→ DeepSeek 400: assistant message with tool_calls must be followed by tool messages」
2. **合并连续 assistant**：相邻无 tool_calls 的 assistant 用 \n\n 拼接为一条——防「非空连续 assistant → 模型退化为纯对话模式零工具调用 → 回合提前退出」（重启后前 1-2 回合高频）

⚠️ **中间残留漏洞（2026-08-11 修复，实锤 400）**：闭合逻辑原实现只在**末尾未闭合**时剥离 tool_calls——若中断残留 assistant（带 tc）后面又跟了 **user 消息**（中断后用户继续发消息），user 分支清空 pending 时不剥离已 push 残留的 tool_calls → 恢复上下文 `...assistant(带tc), user×N` → LLM 400。修复：**清 pending 前先剥离该残留 assistant 的 tool_calls**（content 空则整条删）。实锤会话 aef6c395（13183 残留 + 6 条 user）；验证 = 模拟脚本复刻 + 全库扫描未闭合点=null。恢复后 400 复现时先查这个分支，别只看"末尾"形态。

配套（落库侧，缺一不可）：assistant 工具轮落库必须带 tool_calls；tool 结果落库必须带 tool_call_id。bundle 特征 `pendingLeft`。排查「重启后第一回合不调工具 / 400」先确认这三处是否齐。

## appendMessage

简单插入，不设 parent_id：

```sql
INSERT INTO messages (session_id, role, content, tool_call_id, tool_calls, timestamp, token_count, active, compacted)
VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0)
```

**不要做**：找当前叶子设 parent_id。旧消息没有 parent_id，链会断。

## 压缩旋转（compressAndRotate）

Hermes 模式：创建新 session，写入压缩消息，更新 system prompt。

```
旧 session A ──parent_session_id──→ 新 session B
                                      ├── system (压缩摘要)
                                      ├── msg 1 (保留的最新消息)
                                      └── ...
```

关键：压缩消息要用 `appendMessage` 写入新 session，否则重启后 B 有 0 条消息，上下文全丢。

## 已移除的会话树功能

| 功能 | 问题 | 替代方案 |
|------|------|---------|
| `parent_id` 链 | 旧消息无 parent_id，链断裂；与 Hermes 线性模型冲突 | 扁平 `ORDER BY id DESC` |
| `appendEntry()` | 插入非消息条目（compaction/label），污染 `getMessagesAsConversation` | 用 session 级别字段存元数据 |
| `loadTree()` / `printTree()` / `fork()` | 依赖 parent_id 链，且 LLM 不感知分支切换 | 不实现 |
| `computeStats()` | 遍历所有 entry_type | 用 session 表的字段直接取 |

## 关键信号：LLM 上下文被污染

当 bot 出现以下表现时，优先检查 `getMessagesAsConversation`：

- 前言不搭后语（context 断裂/缺失）
- 重复同一句话（LLM 只看到最新 1-2 条消息）
- 不执行工具（context 不足或格式错误）
- 内容全是"明白我停住了是我的问题"等模板回应（context 为空时 LLM 的默认输出）

诊断方法：
```bash
sqlite3 <项目根>/data/kexvim.db "SELECT id, entry_type, role, substr(content, 1, 40) FROM messages WHERE session_id = '<session-id>' ORDER BY id DESC LIMIT 5;"
```

正常结果应该全是 `entry_type=message` 且 `role` 不为 null。如果看到 compaction/label/model_change 等条目，context 被污染了。

## 会话列表与切换（CLI：kexvim sessions / kexvim session &lt;id&gt;，2026-08-08）

新增两个 CLI 命令（commit 78e4832 / 2205018）：`kexvim sessions` 列出全部会话；`kexvim session &lt;id&gt;` 切换历史会话。

- **机制（事件驱动，零常驻）**：CLI 进程写一次性标记文件（data/ 下），daemon 收到**下一条消息**时消费标记执行 resumeSession 后删除标记——不常驻轮询、不发明端口/通道（符合用户哲学，见 kexvim-windows-daemon）
- **标记消费插入点**：GatewayLauncher 里必须在**会话解析之后**（需要 source/chatId）、recover 之前——插在 repair/ 路由后拿不到 source/chatId，是错误位置
- **输出格式铁律（用户 2026-08-08 反馈「输出的会话列表看不懂，这样给会话id-会话标题」）**：`序号. 会话id前8位 - 标题 [来源]`。禁止 raw 技术标识堆叠（旧格式 `id — source:chatId（时间戳）` 被用户否掉）
- **`/sessions` QQ 内置分支（GatewayLauncher）必须与 CLI 输出同格式**——两处独立实现易漂移，改一边必同步另一边（曾出现 CLI 是新格式、QQ `/sessions` 还是旧格式的不一致）
- **Session 类型没有 msgCount 字段**：硬拼 `${s.msgCount ?? ""}` 报 TS2339——列表想带消息数需子查询，别假设字段存在
- **esbuild 坑**：命令文件里动态 `require('node:sqlite')`（或 `import()`）→ esbuild bundle 直接失败/打不进产物（CLI 无输出）→ 一律顶层 import（AGENTS.md 本就禁止动态 import）
- **无标题用第一条用户消息填充（2026-08-08 用户「无标题的用第一句话填充」，commit 6fbbe0a）**：标题优先级 = `summary` → 首条 user 消息 → "(无标题)"。共用函数 **`SessionStoreHelper.displayTitle(summary, firstUserMsg)`**（JSON 内容块清洗成纯文本 + 截断 30 字），**三个调用点必须同步用**：①`kexvim sessions`（CLI 自己 SQL 子查询 firstUserMsg）；②`listRecent`（Session 类型新增 `firstUserMsg` 可选字段 + rowToSession 映射）；③GatewayLauncher `/sessions`（复用 listRecent 已带字段）——三处任一仍用旧 `(s.summary || "(无标题)").slice(0,30)` 就会漂移。首条 user 消息子查询条件：`role='user' AND (entry_type='message' OR entry_type IS NULL) AND content IS NOT NULL AND content != '' ORDER BY id ASC LIMIT 1`（过滤空内容块；entry_type NULL 兼容 ALTER 老数据，与 loadMessages 过滤同源）
- 测试标记会劫持用户下一条消息：写完标记测试后记得删，否则用户下一条真实消息被切到测试会话
- **全量显示 + 当前会话标记（2026-08-11 用户「最近10条是不是少了，全给会有什么问题吗？还有，当前会话标记一下」，commit 2af1f10）**：
  - daemon 每次 chat/resume/new 后持久化 `data/.current_session`（SessionMixin 的 ensureSession/startNewSession/resumeSession 末尾调私有 persistCurrentSession；data 路径用 `KexvimConfigLoader.findProjectRoot()`——AgentRuntimeCore 无 projectRoot 方法；SessionMixin import Config 无循环依赖，Config 只 import memory/Types type-only）
  - CLI `kexvim sessions` 与 GatewayLauncher `/sessions` 读标记，当前会话行尾标 `◀ 当前`
  - 全量显示：listRecent 从最近 10 条改为 limit 100。**QQ 文本长度上限约 4000 字节**：27 会话 × 每行约 30 字符 ≈ 1000+ 字符安全；会话数 100+ 时 QQ 端可能截断，CLI（终端）无此限制——会话很多时再议分页，不提前做
  - `.current_session` 是运行产物（data/ 下），不进 git；手动写标记测试后必须删（同测试标记劫持教训）
  - 用户问"全给会有什么问题吗"类取舍问题时：直接给量化分析（字节数 vs 平台限制 + 何时需要兜底），不要只说"没问题"

## 用户偏好

- zk 用户：中文交流，直接给修复，不要分析架构
- 禁止：反复问同一个问题、走弯路分析、用超时当兜底
- 优先：拉最新代码测试 → 出问题直接查 `getMessagesAsConversation` 查询结果
