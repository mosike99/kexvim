# Alignment Cases — 2026-07-24

## Case 1: SessionSearchTool 不可用

**症状**: Sage 返回 "Session search unavailable: ..."

**根因**: SessionSearchTool 硬编码 `process.cwd() + "/sessions/sage.db"`，但 sessions 表无 `name` 列，SQL 直接报错。

**修复**:
1. 改用 `COALESCE(summary, id)` 代替 `s.name`
2. 优先 FTS (messages_fts MATCH) 降级 LIKE 搜索
3. const ftsResults 不可 push → 改为 let sessionIdRows + 条件分支
4. 路径从硬编码改为 config 注入（构造函数参数 + AgentRuntime 传入 sessionDir）

## Case 2: 技能不自动保存

**症状**: Sage 从不主动调 skill_manage 创建技能

**根因**: `buildSystemPrompt()` 调 `builder.build()` 时没传 `model` 参数，`_shouldInjectEnforcement(undefined, 'auto')` 匹配不到任何模型名（''.includes('deepseek') === false），TOOL_USE_ENFORCEMENT_GUIDANCE 不注入，agent 没有"必须用工具"的强制指令。

**修复**: 加 `model: this._modelName` 和 `toolUseEnforcement: 'auto'`

## Case 3: require() 在 ESM 项目崩溃

**症状**: Sage 启动报 "Fatal: require is not defined"

**根因**: package.json 有 `"type": "module"`，require() 不可用。

**修复**: 全局搜索 require("node:fs") / require("node:path")，改为 `import * as fs` / `import * as path`。

## Case 4: 路径统一

**变化**: Sage 路径从 `/opt/sage/` 统一到 `~/.sage/`
- SAGE_LOG: /tmp/sage.log → ~/.sage/sage.log
- config.yaml: skills_dir/session_dir 从绝对路径改为 ~/.sage 相对路径
- 每次代码更新后需 `cp src/*.ts ~/.sage/src/` 同步

## Case 5: 重复工具注册

**文件**: Main.ts
**问题**: ReadTool/WriteTool/SearchTool/TerminalTool 在 AgentRuntime 构造函数和 Main.ts 中重复注册
**修复**: 删除 Main.ts 中重复的 addTool 调用及对应 import

## Case 6: Const push 修复漏提交

**问题**: SessionSearchTool.ts 的 const push 修复改了文件但 git commit stat 只显示了 restart_sage.sh/install.sh——文件没被加进 commit。
**教训**: 每次 git 操作后检查 `git show HEAD --stat` 确认修改文件列表正确。

## Case 7: 身份提示词与工具强制引导冲突 (过时)

**状态**: 此 case 已过期。实际根因是 LLM 适配器共享（见 Case 8），不是身份提示冲突。回滚 `03f0e19` 后提示词保持 Hermes 原文。

## Case 8: BackgroundReviewer 共享 LLM 适配器

**症状**: Sage "只回一句就停" — 回复一条完整中文句子后进程卡死。进程存活但日志无活动。

**根因**: `BackgroundReviewer` 接收 `this.llm`（主 Agent 的 OpenAIChatAdapter 实例）。该适配器有可变内部状态（`streamToolCallAssembler`、`_streamFinishReason`）。后台审查 fork 和主 Agent 的 LLM 流并发访问同一实例，互相污染内部状态。

**Hermes 参考**: `background_review.py` → `_resolve_review_runtime()` → 创建独立的 provider 配置，fork 全新的 AIAgent 实例，不共享主 Agent 的运行时。

**初步修复** (`d07144b`): `AgentRuntimeConfig.createReviewLLM` 工厂方法。`spawnBackgroundReview()` 调用工厂创建独立 LLM 适配器实例。

**最终修复** (`2c032b3`): fork 子进程实现完全 HTTP 隔离（见 Case 17）。

**教训**: 任何后台 fork/sub-agent 都不能共享主 Agent 的可变状态对象。在 Node.js 中，即使创建独立 adapter 实例也共享 HTTP 连接池，需要子进程隔离。

## Case 9: Patch 改到错误路径

**症状**: `d2641f3` 提交内容只有 `config.yaml` 和 `sage.log` — 预期的代码改动没有提交。

**根因**: `patch` 工具写了 `/opt/sage/` 下的文件，但 git 仓库在 `~/.sage/`。两个路径的文件是独立的。

**修复**: `cp` 同步文件到 `~/.sage/` 后提交 (`d07144b`)。

**教训**: 改之前 `cd ~/.sage && pwd`。改完后 `git diff HEAD~1 --stat` 确认改动。

## Case 10: `.env` 中 SAGE_HOME 指向已删除路径

**症状**: Sage 启动报 `Fatal: EACCES: permission denied, mkdir '/opt/sage/memories'`。

**根因**: `.env` 文件有 `SAGE_HOME=/opt/sage`。`FileMemoryStore` 构造函数先检查 `SAGE_HOME` env var，命中后尝试创建 `/opt/sage/memories/` → 目录不存在 → 崩溃。

**修复**: 将 `.env` 中的 `SAGE_HOME` 改为 `$HOME/.sage`。

**教训**: 每次重启前检查 `.env` 中的 `SAGE_HOME`。迁移代码目录时必须同时更新 `.env`。

## Case 11: Guidance 布尔 flag → 工具存在性门控

**Hermes 模式** (`system_prompt.py`):
```python
if "memory" in agent.valid_tool_names:
    tool_guidance.append(MEMORY_GUIDANCE)
if "skill_manage" in agent.valid_tool_names:
    tool_guidance.append(SKILLS_GUIDANCE)
if "session_search" in agent.valid_tool_names:
    tool_guidance.append(SESSION_SEARCH_GUIDANCE)
```

**Sage 修复前**: `BuildOptions` 用 `memoryGuidance: true` 等布尔 flag，不管工具是否注册都注入。

**Sage 修复后** (`f84208c`):
- `ToolRegistry` 接口新增 `names(): string[]`
- `BuildOptions` 新增 `validToolNames?: string[]`
- `build()` 内用 `toolNames.includes("memory")` 替代布尔检查
- `buildSystemPrompt()` 传 `this._tools.names()` 替代三个布尔值

## Case 12: Config 传递链不完整

**问题**: `AgentRuntime` 构造函数有 `config.skillNudgeInterval ?? 10`，默认值正确所以功能看似正常。但配置链路不完整：yaml 的 `skill_nudge_interval` 从未传给 AgentRuntime。

**Hermes 模式**: `agent_init.py` 从 `agent.config` 读取 `skills.creation_nudge_interval` 直接设到 agent 上。

**Sage 修复** (`57ad9df`):
- `Config.normalizeConfig()` 新增 `skill_nudge_interval → skillNudgeInterval` 映射
- `AgentConfig` 接口新增 `skillNudgeInterval?` 和 `backgroundReview?` 字段
- `Main.ts` 显式传递这两个参数
- `config.yaml` 加入默认值

## Case 13: MEMORY/SKILLS/SESSION_SEARCH 文本对齐

**问题**: Sage 的自定义文本（含中文例子、Emoji 列表）与 Hermes 精确文本不一致。

**修复** (`fedf193`): 精确复制 Hermes 原文，包括 `declarative facts`、禁止记录 PR 号等细节。

## Case 14: 清理 104 个残留编译文件

**修复**: `find ~/.sage/src -name "*.js" -o -name "*.d.ts"` → 删除 104 个残留文件。这些文件是原始代码库遗留的旧编译产物，`tsx` 直接运行 `.ts` 不受影响，但会造成混乱。

## Case 15: 独立 memory nudge 双计数器

**Hermes 模式** (`turn_context.py` + `turn_finalizer.py`):
- `_memory_nudge_interval` (默认10) — turn-based 计数器，记录用户轮次
- `_skill_nudge_interval` (默认10) — iteration-based 计数器，记录工具调用轮次
- `_turns_since_memory` 和 `_iters_since_skill` 独立计数
- 任一 flag 为 true → 触发 background review，传 `review_memory`/`review_skills` flag

**修复** (`e0888f4`):
- `AgentRuntimeConfig` 加 `memoryNudgeInterval` 字段
- `Config.ts` 加 `memoryNudgeInterval` 映射
- `Main.ts` 加传递
- `config.yaml` 加 `memory_nudge_interval: 10`
- `BackgroundReviewer` 接受 `reviewMemory`/`reviewSkills` flag，调整审查指令

## Case 16: Session 恢复 nudge 计数器

**Hermes 模式** (`turn_context.py:458-466`): session 恢复时，从历史消息数重建 `_turns_since_memory`/`_user_turn_count`。

**修复** (`accc55f`):
- 在 `chat()` 中 session 加载后，过滤 user 角色消息数量
- `_userTurnCount = priorUserTurns`
- `_turnsSinceMemory = priorUserTurns % memoryNudgeInterval`
- `_itersSinceSkill = priorUserTurns % skillNudgeInterval`

## Case 17: BackgroundReviewer HTTP 隔离 — fork 子进程

**症状** (`d07144b` 后): 即使 `createReviewLLM` 创建独立 LLM 适配器，background review 仍然导致主 Agent 断流。

**根因分析**: 用 isolate 法（Case 18）逐个 revert 发现三处代码改动均无问题，根因是 `background_review: true` 本身触发了 review 的 API 调用。Node.js 的全局 `fetch()` 使用 `undici` 共享 HTTP 连接池，两条并发请求到 `api.deepseek.com` 走同一 TCP 连接，主 Agent 的流被破坏。

**Python vs Node.js 关键差异**:
- Python Hermes (`threading.Thread`): 每个线程有独立事件循环，HTTP client 绑定线程本地事件循环，HTTP 连接完全不共享
- Node.js 同一进程: 所有 `fetch()` 走全局 `undici` dispatcher，即使不同 adapter 实例也共享连接池
- 社区共识: `worker_threads` 仍在同一 V8 堆上，不隔离 HTTP 连接；真正隔离需要 `child_process`

**修复** (`2c032b3` / `9f2308a`): fork 子进程 (`child_process.spawn` + `tsx` loader) 运行 review

worker 文件: `scripts/review-worker.ts`
- 独立 Node.js 运行时、事件循环、HTTP 连接池
- `process.env.SAGE_REVIEW_DATA` 传递任务参数（messages + API 凭据）
- 输出 JSON 到 stdout: `{ ok, summary }` 或 `{ ok: false, error }`
- 2 分钟超时，崩溃/超时自动忽略

## Case 18: 回归定位 — 二分法验证

**场景**: 三处改动同时推送后断流，不知道哪一个是根因。

**过程**:
1. `git revert accc55f e0888f4 f84208c` → 问题消失
2. 逐个 `git cherry-pick <sha>` → 每个单独测试
3. validToolNames 正常 → 双计数器正常 → session 恢复正常
4. 最终发现三处代码改动本身都没问题，根因是 `background_review: true` 触发 review API 调用

**教训**: 不要猜。二分法 revert → 确认正常 → 逐个加回来。这是检验因果关系而非相关性的唯一方法。

## Git History (2026-07-24)

```
2c032b3 fix: review-worker.ts import 路径修正
9f2308a fix: BackgroundReviewer fork 子进程隔离 HTTP 连接池
6aa14b5 fix: review AbortSignal + idle
d4134c2 test: session 恢复计数器
330ecb2 test: 双计数器
cf71d0d test: validToolNames 门控
c4057c6 Revert "Guidance 按工具存在性门控注入"
6797bb7 Revert "独立 memory_nudge_interval 双计数器"
31fe541 Revert "session 恢复时重建 nudge 计数器"
accc55f fix: session 恢复时重建 nudge 计数器
e0888f4 feat: 独立 memory_nudge_interval 双计数器
f84208c fix: Guidance 按工具存在性门控注入
57ad9df fix: 配置传递链 — skill_nudge_interval + background_review
7b3b9a9 chore: skillNudgeInterval 从 10 降到 3
fedf193 feat: 对齐 MEMORY/SKILLS/SESSION_SEARCH 引导文本
d07144b fix: 补上 createReviewLLM 到 ~/.sage/
d2641f3 fix: BackgroundReviewer 不共享 LLM (只含 config.yaml/sage.log)
5cd0b86 Reapply "feat: 添加 BackgroundReviewer"
648ecd5 Revert "feat: 添加 BackgroundReviewer"
347b8df Revert "fix: 身份提示冲突"
03f0e19 fix: 身份提示冲突 (已回滚)
208f449 feat: 添加 BackgroundReviewer (原始版本)
662a9c8 chore: 删除重复工具注册
```

## Key Technical Insights

### Python threading.Thread vs Node.js 子进程

| 特性 | Python (Hermes) | Node.js (Sage) |
|---|---|---|
| 后台任务隔离 | `threading.Thread` → 独立事件循环 + 独立 HTTP client | `child_process.spawn` + `tsx` → 独立 OS 进程 |
| HTTP 连接池 | 每个 aiohttp/httpx 实例独立 | 全局 `undici` dispatcher（同一进程内共享） |
| 并发 API 调用 | 安全（不同事件循环） | 不安全（共享连接池，流式响应和请求争用同一 TCP 连接） |
| 状态共享 | `threading.local()` 隔离 | 完全无共享（不同进程） |
| 启动开销 | 毫秒级（线程） | 秒级（tsx 加载 + 进程 fork） |

### spawn 而非 fork

`child_process.fork()` 要求子进程是单独的 Node.js 文件。用 `spawn('node', ['--import', tsxLoader, workerPath])` 允许 tsx 加载 TypeScript 文件。

### 教训

- `createReviewLLM` 工厂创建的独立 adapter 实例并不真正隔离 HTTP 连接——它们共享 Node.js 全局 `fetch()` 的 `undici` dispatcher
- 两条并发请求到同一个 API 端点走同一 TCP 连接，流式响应被普通请求破坏
- 真正的 Node.js HTTP 隔离只有一条路：不同的 OS 进程
- tsx 子进程的 import 路径解析与主进程不同——worker 文件中的 `../` 相对于 worker 文件自身路径，不是相对于 cwd
