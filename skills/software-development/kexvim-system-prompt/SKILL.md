---
name: kexvim-system-prompt
description: "System Prompt 架构：PromptBuilder 分层、诚实规则"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, system-prompt, prompt-builder, honesty]
    related_skills: [kexvim-llm-provider, kexvim-session]
---

# Kexvim System Prompt

## 核心原则

用户明确要求"和 Hermes 对齐"。含义是：

- **诚实规则必须写死在 `DEFAULT_AGENT_IDENTITY`（`src/inference/PromptBuilder.ts:32`）**，每次 LLM 调用都会出现
- **AGENTS.md 不够**——它是可选的 context tier 注入，优先级低于 identity
- 搜索工具零结果时不得直接说"不存在"，先交叉验证

## PromptBuilder 架构（`src/inference/PromptBuilder.ts`）

`build()` 方法按固定层级组装 system prompt：

```
┌─ Identity（DEFAULT_AGENT_IDENTITY）      ← 核心身份 + 诚实规则   [最高优先级]
├─ Tool-use enforcement                     ← "必须用工具行动"
├─ Task completion guidance                 ← "一直做到完成"
├─ Parallel tool call guidance              ← "独立调用可并行"
├─ Memory / Skills / SessionSearch guidance ← 工具相关引导
├─ Skills prompt（从 skill 加载）
├─ Tool definitions                         ← 可用工具列表
├─ Environment hints
├─ Coding workspace snapshot
├─ Context files（AGENTS.md 等）            ← 项目目录扫描注入    [较低优先级]
└─ Memory snapshot（持久化记忆）
```

层级顺序固定，不可调换。高优先级层不被后续层覆盖。

### 诚实规则（DEFAULT_AGENT_IDENTITY）

**已和 Hermes 逐行对齐**，仅名称不同。当前内容（`PromptBuilder.ts:32`）：

```
You are Kexvim — an intelligent AI agent for conversation, code, and task automation.
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
directly with read_file.
```

### PITFALL：诚实规则放哪层

用户要求"system prompt 和 Hermes 对齐"时，**诚实规则必须写死在 `DEFAULT_AGENT_IDENTITY`**（`PromptBuilder.ts:32`），不是只改 `AGENTS.md`。

| 层级 | 文件 | 出现频率 | 优先级 |
|------|------|---------|--------|
| 系统 prompt 身份 | `PromptBuilder.ts:32` | 每次 LLM 调用 | 最高 |
| 项目上下文 | `AGENTS.md` | 注入到 Project Context | 较低 |

教训：第一次只改了 AGENTS.md，被用户纠正后才意识到要改源代码的 identity 常量。

### 对齐检查清单

| 提示段落 | 状态 |
|---------|------|
| Identity + 诚实规则 | `DEFAULT_AGENT_IDENTITY` ✓ |
| Tool-use enforcement | `TOOL_USE_ENFORCEMENT_GUIDANCE` ✓ |
| Task completion | `TASK_COMPLETION_GUIDANCE` ✓ |
| Parallel tool calls | `PARALLEL_TOOL_CALL_GUIDANCE` ✓ |
| Memory/Skills/SessionSearch | 三个 GUIDANCE ✓ |
| DeepSeek verification | `DEEPSEEK_VERIFICATION_GUIDANCE` ✓ |
| Mid-turn steer | `STEER_CHANNEL_NOTE` ✓ |
| Google model guidance | `GOOGLE_MODEL_OPERATIONAL_GUIDANCE` ✓ |
| Environment hints | `buildEnvironmentHints()` ✓ |
| Coding workspace | `buildCodingWorkspaceBlock()` ✓ |
| Context files | `buildContextFilesSection()` ✓ |
| Timestamp | `buildTimestampLine()` ✓ |

### PromptBuilder 平台/模型解耦（2026-08-07~08-10 架构铁律清理完成）

**src 不允许感知 platform 和 model**（用户铁律）——PromptBuilder 已移除：`PLATFORM_HINTS`
（qqbot 提示写死，无调用方死代码）、按模型名分支注入 guidance（如 DeepSeek 专属段
515-522，注释明写 "NOT to DeepSeek"）、模型家族判断表、enforcementModels。
终态接口：平台提示走 `BuildOptions.customPlatformHint`（适配层传入）；模型 guidance 走
`BuildOptions.executionGuidance`（AgentRuntime buildPrompt 传值，保持 openai/google 模型
原有 guidance 行为）；模型家族判断下沉 `packages/llm`（ReasoningTimeouts /
isReasoningModel / modelName 元数据），src 只读 adapter 暴露的能力字段，不持有模型名参与
决策。改 PromptBuilder 前先对照此边界：**不许再往 src 核心写具体平台/模型分支**。

### 调用链

`AgentRuntime.ts:724` → `buildSystemPrompt()` → `PromptBuilder.build()`

AgentRuntime 的 `this.systemPrompt`（`:259`）初始化为 `config.systemPrompt || "You are kexvim, an intelligent assistant."`，作为 `systemMessage` 参数传入 `build()`。

## AGENTS.md

项目根目录的 `AGENTS.md` 由 PromptBuilder 的 `buildContextFilesSection()` 自动扫描注入。优先级低于 identity，但高于 memory snapshot。

### Integrity Rules（在 AGENTS.md 中重复声明，与 identity 一致）

1. **不确定时如实说"不确定"或"不知道"。不要编造解释。**
   - 搜索工具零结果时先用其他方式验证（`grep`、`read_file`），不能直接说"不存在"
2. **如实报告错误和阻塞比编造答案好。**
   - 工具失败时如实说出错误原因
   - 发现信息不足时要求补充，不要强行回答
3. **工具返回的数据就是最终结果，不要自行扩展或推断不存在的信息。**

### search_files 使用须知

- 底层是 **ripgrep + regex** 模式（不是纯文本搜索）
- 搜特殊字符（括号、引号、点号）需转义：`\(`、`\"`、`\.`
- 不确定时先用 `grep -F`（纯文本模式）在终端验证
- 大文件（>300 行 / 40KB+）零结果尤其可疑，必须交叉验证

### 常用 Git 操作

- 仅 stage 本次改动的文件，显式列文件 `git add src/Foo.ts`
- 禁止 `git add -A` / `git reset --hard` / `git push --force`
- 提交格式：`{feat,fix,docs,clean,refactor}: <描述>`

## PITFALL：import 不加后缀在 Windows 上不工作

`tsx` 在 Linux 上会自动解析无扩展名的 import（`from "./Foo"` → `./Foo.ts`），但在 Windows 上 Node.js ESM resolver 会绕过 `tsx` 的钩子，导致 `ERR_MODULE_NOT_FOUND`。

**修复（2026-07-28）**：全部 68 个文件的 ~255 处 import 都加了 `.ts` 后缀。所有 tsconfig.json 加了 `allowImportingTsExtensions: true`。

详见 `references/windows-tsx-compat.md`。

### 5. Node 22 strip-only 模式冲突

```
SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript enum is not supported in strip-only mode
```

Node 22 内置的 strip-only TS 支持会拦截 `.ts` 文件，但它不支持 `enum`。

两个修复方案（本 session 用了方案 B）：

**A. `--no-experimental-strip-types` flag**（在 package.json scripts 加此参数，让 tsx 接管）：
```json
"start": "node --import tsx --no-experimental-strip-types src/Main.ts"
```

**B. 把 enum 改成 const 对象**（不依赖 tsx，Node 直跑）：

```diff
- export enum SubAgentStatus {
-   Idle = 'idle',
-   Busy = 'busy',
- }
+ export const SubAgentStatus = {
+   Idle: 'idle',
+   Busy: 'busy',
+ } as const;
+ export type SubAgentStatus = (typeof SubAgentStatus)[keyof typeof SubAgentStatus];
```

方案 B 的优势：不再依赖 `tsx` 加载器，Node 22 原生支持。3 个 enum 改完（SubAgentStatus、FailoverReason、MCPServerState`），`npx tsc --noEmit` 通过。

注意：JSDoc 注释必须保持与原 enum 一致——每条上的注释在 const 对象中同样有效。

**修复**：
1. `skills/` 目录加入公开仓，与 `kexvim.js` 一起发布
2. 入口脚本（`kexvim.sh`/`kexvim.bat`）首次安装时自动下载 `skills/`
3. `InstallKexvim.ts` 中添加技能下载逻辑（git clone --depth 1 后 cp）

---

**参考文件**: `references/multi-thread-optimizations.md` — 多线程优化记录（_chatQueue、Watchdog Map、并发控制）
**参考文件**: `references/windows-tsx-compat.md` — Windows tsx 兼容性修复（import 后缀、noEmit、strip-only）
