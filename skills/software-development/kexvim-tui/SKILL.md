---
name: kexvim-tui
description: Kexvim TUI（Terminal UI）设计 — Pi风格，独立于 Gateway，树导航 + 增量压实
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, tui, terminal-ui, pi-style, tree-navigation, compaction]
    related_skills: [kexvim-session, kexvim-session-runtime]
---

# Kexvim TUI

## 架构

TUI 是**独立运行模式**，不依赖 `config.platform.enabled`。与 Gateway 平级，共享同一个消息 handler。

```
agent Worker
  ├── handler（消息分发）
  │     ├── repair/ → GuardianAgent
  │     ├── /tree /fork /compact /label /model → SessionStore
  │     └── 其他 → runtime.chat()
  │
  ├── TUI（始终启动 ✅）
  │     └── stdin → handler → stdout 格式化输出
  │
  └── Gateway（可选，需 platform 配置）
        └── QQBot → handler → QQ API
```

## TuiAdapter（`packages/tui/src/TuiAdapter.ts`）

实现 `PlatformAdapter` 接口：
- `setMessageHandler(handler)` — 绑定消息处理器
- `start()` — 非阻塞，设置 readline 监听后立即返回
- 双模式：readline 常规模式 + raw mode 树导航模式

## 支持的斜杠命令

| 命令 | 功能 |
|------|------|
| `/tree` | 打印当前会话树 |
| `/fork <entryId>` | 在指定条目分叉 |
| `/compact` | 手动压实，LLM 生成结构化摘要 |
| `/label <entryId> <text>` | 标记条目 |
| `/model <provider> <modelId>` | 切换模型 |
| `/help` | 显示帮助 |
| `/exit` / `/quit` | 退出 |

## 树导航（`/tree` 交互模式）

在 TUI 中调用 `/tree` 会进入**交互式树导航模式**：
- `↑↓` 键选择节点
- `Enter` 确认选择
- `q` / `Esc` / `Space` 退出
- raw mode 处理键盘事件，readline 暂停

实现：
- `_enterTreeMode()` — 保存 raw mode，暂停 readline，绑定键盘监听
- `_treeKeyHandler` — ↑↓ 调整 cursor，Enter 确认，q/Esc 退出
- `_renderTree()` — 清除上次渲染，逐行绘制缩进树
- `_exitTreeMode()` — 恢复 readline，还原模式

## 增量压实（Pi 风格）

压实由 `src/memory/Compactor.ts` 实现：

| 函数 | 用途 |
|------|------|
| `buildCompactionPrompt(msgs)` | 首次压实提示词 |
| `buildUpdateCompactionPrompt(msgs, previousSummary)` | 增量压实（在已有摘要上合并新消息）|
| `buildBranchSummaryPrompt(msgs)` | 分叉时生成分支摘要 |
| `findCutPointInEntries(entries, startIdx)` | 在树条目中找到切割点 |
| `compact(sessionStore, sessionId, summarizer)` | 执行压实，插入压实条目 |
| `shouldCompact(tokenCount, threshold)` | 检查是否需要压实 |

自动压实：每轮对话后检查 token 数，超阈值（128K）后台异步压实。

## 关键代码位置

- TUI 启动：`src/Main.ts` → `new TuiAdapter()` + `tui.setMessageHandler(handler)` + `tui.start()`
- handler 创建：`src/Main.ts` → main() 中 `const handler = async (msg) => {...}`
- 会话树：`src/memory/SessionStore.ts` → `loadTree()`, `printTree()`, `fork()`, `appendEntry()`
- 压实：`src/memory/Compactor.ts`
- 类型：`src/memory/Types.ts` → `EntryType`, `SessionEntry`, `SessionStats`

## 后续规划（2026-08-04 定案：面向非编程用户）

**关键定位（用户定案）**：kexvim 面向的不只是编程用户——UI 参考系不能只抄编程 agent
（Claude Code/Codex 是终端技术向），要面向普通用户。

当前用户入口：TUI（终端，技术向）、平台适配器（QQ bot 等聊天）、CLI（运维向）。
**缺面向普通用户的图形化入口**（终端用户非技术不好上手）。

### UI 参考方向（用户定案，2026-08-04）

1. **Manus** — 任务步骤时间线 + 中间产物卡片：普通用户看 agent 干活的最佳范式
   （"正在做第 3/5 步：收集资料"，可随时插话改方向）
2. **豆包 / 腾讯元宝小程序** — 微信生态入口形态；用户有 uni-app 微信小程序经验，直接复用
3. **ChatGPT / Claude 对话** — 基础对话体验基准（无技术噪音、流式、极简输入框）

### 呈现层翻译原则（技术概念 → 普通用户语言）

| kexvim 技术概念 | 对普通用户呈现 |
|---|---|
| 斜杠命令 /tree /compact | 自然语言 + 按钮卡片（"继续上次的"/"重新开始"） |
| 会话树 | 微信式会话列表（树隐藏） |
| 工具调用 | "正在：搜索网页 / 处理文档"自然语言步骤 |
| 压实/分支 | 自动发生，用户无感知（最多一个摘要卡片） |
| 模型切换 | 设置页下拉框 |

技术内核（会话树、压实、工具链、handler 链）不动，只换呈现层。

### 启动前置问题（未决，启动时再定）

- 入口形态：Web / 微信小程序 / 双轨（用户已有 uni-app 经验，小程序是现实路径）
- 服务端口/鉴权
- 与 Gateway/handler 的消息通道（TUI 已是独立于 Gateway 的模式，新入口复用同一条 handler 链）
- 会话树/压实能力是否直接暴露给新入口

## 市场 UI 参考结论（2026-08-04 调研）

用户问"市面上哪家 agent 的 UI 可以参考"，已给出对照结论（方向仍未拍板，调研结论留档复用）：

- **终端交互基准**：Claude Code（审批流/compact/斜杠命令，行业事实标准）；细节补充看 Codex CLI
  （克制）、Aider（git diff 改动展示）、charmbracelet/crush（终端键盘交互，开源）
- **Web 结构参考**：OpenHands（开源可读码，plan/execute 双模式、任务卡片，最值得抄）；Devin/Manus
  （长任务过程时间线可视化）；Dify/Langflow/n8n（工具链/工作流图可视化编排）
- **可观测层**：LangSmith/Langfuse/AgentOps 的 trace 树可映射到 SessionStore 会话树
- **给 kexvim 的建议**：终端侧抄 Claude Code 交互、Web 侧抄 OpenHands 结构、双形态复用 handler 链
  参考 Gemini CLI（同套逻辑 `--web` 出 web 版）
- 调研备注：本机 `web_search` 当日 3/3 超时，上述结论基于已有认知、未在线核验，下次可补核验
