---
name: kexvim-development
description: "Develop kexvim: port Hermes features, fix bugs, deploy"
license: MIT
version: 3.0.0
author: agent
platforms: [linux, win32, darwin]
metadata:
  kexvim:
    tags: [kexvim, development, porting, build, debug, deploy]
    related_skills: [kexvim-deployment, kexvim-restart, kexvim-hermes-alignment]
---

# kexvim Development — Developing and Operating the kexvim Agent

kexvim (formerly "sage") is a TypeScript port of Hermes Agent running on a VPS. This skill covers the full lifecycle: developing features (porting from Hermes), fixing bugs, deployment, and restart.

## Repository

- **Private (dev)**: `git@gitee.com:moscowzk/kexvim-dev.git` (日常开发, .ts 源码, 分支 `main`)
- **拉取协议（Linux 本机，08-03 实测）**: SSH publickey 被 Gitee 拒（`~/.ssh/id_ed25519` 未注册，deploy key 在 /tmp 被重启清空）→ 必须 HTTPS+token：`git remote set-url origin "https://moscowzk:<token>@gitee.com/moscowzk/kexvim-dev.git"`。remote 曾被人改成 SSH 导致 fetch 失败；token 嵌在历史 pull URL 里，用 `git reflog | grep pull` 恢复。详见 references/gitee-ssh-troubleshooting.md（Windows/deploy key 场景）
- **Public (release)**: `https://gitee.com/moscowzk/kexvim.git` (公开, 分支 `main`, 含 kexvim.js + 管理脚本 + skills/)
- **Local**: `<项目根>/`, 分支 `main` (已从 `master` 迁移至 `main`)
- **Release 工作流**: [references/release-workflow.md](skill://kexvim-development/references/release-workflow.md)
- **Config**: `<项目根>/data/config.yaml`（⚠️ 从 `<项目根>/config.yaml` 迁移至此，缺此文件 kexvim 无法启动）
- **Secrets**: `$KEXVIM_DIR/data/.env`（⚠️ 从 `$KEXVIM_DIR/.env` 迁移至此，`RestartKexvim.ts` 会解析此文件传给子进程）
- **QQ Bot**: AppID
- **Sessions DB**: `$KEXVIM_DIR/data/`
- **Skills (user/auto-saved)**: `$KEXVIM_DIR/data/skills/` (gitignore)
- **TUI mode**: TuiAdapter（`packages/tui/`）始终通过 Gateway 注册，和 QQ Bot 同一进程运行
  - `npm start` 启动后，如有 TTY 会显示 `kexvim>` 提示符，可在终端直接输入
  - 非 TTY 环境（cron 触发、nohup 启动、systemd 服务）TuiAdapter 自动跳过（不崩溃）
  - `isTTY` 检查放在 `TuiAdapter.ts` 第 36 行 `this._isTty = process.stdout.isTTY`
- **平台适配器**（2026-08 起多平台）：`packages/platform/src/` 下 QQ/HTTP/Telegram/Discord
  适配器，`GatewayLauncher.ts` 的 `ADAPTER_FACTORIES` 工厂表注册，新增平台只加一行。
  测试陷阱（WS start() 勿 await、mock 需 apiBase 覆盖、worker+REPL stdin EOF）见
  [references/platform-adapter-testing-pitfalls.md](skill://kexvim-development/references/platform-adapter-testing-pitfalls.md)

## Build

### 开发版（esbuild）
```bash
npm start             # esbuild 编译 → node 运行（一步到位）
npm run build:dev     # tsc --noEmit（类型检查）+ esbuild 编译
```

- **tsc 只做类型检查**（`tsconfig.json` 中 `noEmit: true`）
- **esbuild 负责编译**：`esbuild src/Main.ts --bundle --platform=node --format=esm --outfile=dist/dev.mjs`
- 输出为 `dist/dev.mjs`（单文件 ESM bundle），约 1.8MB，141ms 完成
- 工具脚本（restart/stop/install）各自独立 esbuild 编译：`dist/dev-restart.mjs` 等
- **没有 tsx 运行时依赖** — `tsx` 已移出 production dependencies
- **不再运行 `.ts` 文件** — 所有运行时都是编译后的 `.mjs`

### 发布版打包（esbuild）

```bash
npm run build     # esbuild 直接打包 → kexvim.js (minified, 单文件)
```

esbuild 直接调用（不用 tsup），参数：
- 入口: `src/Main.ts`
- 格式: `--platform=node --format=esm`
- 输出: `kexvim.js`（根目录，单文件，没有 dist/ 目录）
- 压缩: `--minify`
- Shebang: `--banner:js='#!/usr/bin/env node'`（全局安装后 `kexvim` 命令直接运行）
- External: `cron`, `ws`, `js-yaml`, `@modelcontextprotocol/*`
- `node:` 前缀: esbuild 直接调用**不会**去掉 `node:sqlite` 的 `node:` 前缀（tsup 会去掉）
- **不产生 chunk 文件** — 单文件输出

### tsconfig 设置

```json
{
  "target": "ES2022",
  "module": "ESNext",
  "moduleResolution": "bundler",
  "strict": true,
  "noEmit": true,
  "skipLibCheck": true
}
```

- `tsc` 仅类型检查（`noEmit: true`），不产生输出文件
- esbuild 独立负责编译，不受 tsconfig 影响
- 发布版不受 tsconfig 影响（esbuild 独立）

### Import 约定

- 所有 import 使用**单引号**
- 本地 import **无后缀**（tsc 用 `moduleResolution: bundler` 自动解析 `.ts` 源文件，esbuild 编译时自动处理扩展名）
- npm 子路径 import 保留 `.js` 后缀（如 `@modelcontextprotocol/sdk/client/stdio.js`），因为 esbuild 对 npm 包不含 exports map 的路径需要显式扩展名

## 统一管理脚本（公开仓，三平台通用）

公开仓只保留三个脚本，每个支持 `{init|update|restart}` 子命令：

| 平台 | 脚本 | 命令示例 |
|------|------|---------|
| Windows | `kexvim.bat` | `kexvim.bat init` |
| Windows | `kexvim.ps1` | `.\kexvim.ps1 update` |
| Linux | `kexvim.sh` | `bash kexvim.sh restart` |

### 子命令

- **init** — 首次安装：自动检测 git（`git clone --depth 1`）或回退 zip 下载，提示输入 API Key，写入 `data/.env`
- **update** — 拉取最新 `kexvim.js`：有 `.git` 则 `git pull --ff-only`，无 git 则下载 zip 覆盖 `kexvim.js` → 自动调用 restart
- **restart** — 停止旧 kexvim 进程 → 启动新进程（后台 nohup / Start-Process）

所有旧脚本（`install.*` + `update.*` + `watchdog.*`）已全部删除，功能归一。

### 看门狗保障

`kexvim.sh restart` 用 `nohup` 启动，进程崩溃后不会自动重启。如需看门狗能力：

```bash
while true; do bash kexvim.sh restart; sleep 5; done
# 停止: touch <项目根>/.stop_watchdog && kill $(pgrep -f watch)
```

看门狗本质是启动循环，放在 `kexvim.sh` 里会让子命令含义不清，所以设计为三命令轻量脚本 + 用户自行包装循环。详见下方看门狗优雅停止模式。`

## 发布版 vs 开发版

| 模式 | 启动命令 | 说明 |
|------|---------|------|
| 发布版 | `node kexvim.js` | esbuild 单文件，304KB minified，无 `.ts` 源码依赖 |
| 开发版 | `npm start` | esbuild 编译到 `dist/dev.mjs` → `node` 运行，需要 `node_modules` |

发布版用户从公开仓获取，安装后直接 `node kexvim.js` 启动。开发版在私仓，日常修改用 `npm run build` 编译后 `node kexvim.js` 测试。

### Windows 开发注意事项

- Windows 上 `npm start` 同样有效（esbuild 编译后 node 运行），但首次需要安装 VS Build Tools 为 `node:sqlite` 编译原生插件
- 如果 esbuild 报错，先检查 `node_modules` 是否完整：`npm install`

### 公开仓含 skills/ 目录

公开仓新增 `skills/` 目录，包含 10 个公共技能。首次安装时：
- `kexvim.sh`/`kexvim.bat` 入口脚本自动 `git clone --depth 1` 并复制 `skills/`
- `InstallKexvim.ts`（`npm run install`）也会通过 git 下载
- 技能不打包进 `kexvim.js`（markdown 文件，esbuild 不会处理）

重启必须确保新进程启动成功再杀旧进程，否则服务中断。`RestartKexvim.ts` 包装此安全逻辑。

## 控制命令（dev 仓，发布版不可用）

```bash
npm run restart    # → esbuild 编译 + node dist/dev-restart.mjs
npm run stop       # → esbuild 编译 + node dist/dev-stop.mjs
npm run install    # → esbuild 编译 + node dist/dev-install.mjs
```

## 后台运行

重启由 `RestartKexvim.ts` 管理，不需要手动杀进程：

```bash
cd <项目根> && npm run restart
```

底层流程：
1. 读取 `<项目根>/data/.env` 获取 API Key
2. `findKexvimPids()` 查找旧进程
3. 后台启动新实例：`node kexvim.js`
4. 等待 `适配器已就绪`
5. 清理旧进程

旧版 `restart_sage.sh` 和 `/opt/sage/` 路径已废弃 — 所有操作通过 `RestartKexvim.ts` / `StopKexvim.ts` 完成，数据在 `<项目根>/data/`。

## .env 自动加载机制

`data/.env` 文件在 kexvim 启动时**自动加载**到 `process.env`，无需手动 export。

实现位置：`src/Config.ts` 的 `KexvimConfigLoader.load()` 方法最开头。

加载逻辑：
```
读取 <项目根>/data/.env → 按行解析 KEY=VALUE → 仅当 process.env[key] 未设置时注入
```

规则：
- 空行和 `#` 注释行跳过
- 仅第一行等号分隔（不支持行内注释）
- 不覆盖已有环境变量（`!process.env[key]` 检查）
- 支持任意环境变量名（`DEEPSEEK_API_KEY`, `QQ_APP_ID` 等）

这解决了安装脚本写入 `data/.env` 但 kexvim 启动时不识别的问题。以前必须手动 `export DEEPSEEK_API_KEY=xxx` 或设系统环境变量才能运行。

## 热修复

```bash
cd <项目根>
# 改代码 → 重新构建
npm run build
# 更新公开仓 — 同步 kexvim.js + 三个管理脚本 + 元文件
cp kexvim.js kexvim.sh kexvim.ps1 kexvim.bat /tmp/sage-public/
cd /tmp/sage-public && git add -A && git commit -m "fix: xxx" && git push
# 确认所有分支同步
git push origin main && git push origin 1.0
```

⚠️ **公开仓同步检查清单**：`kexvim.js` `kexvim.sh` `kexvim.ps1` `kexvim.bat` `package.json` `.gitignore` `LICENSE` — 缺任一文件对应平台的安装/更新就会出问题。

## 公开仓打包规则

发布到 `gitee.com:moscowzk/kexvim.git` (main 分支) 时：
- **没有 `.ts` 源码** — 只发布编译后的 kexvim.js
- **有 `skills/` 目录** — 10 个公共技能 markdown 文件，通过入口脚本/安装工具下载到 `<项目根>/skills/`
- **没有 node_modules** — 用户直接用 `node kexvim.js` 运行，无需 `npm install`
- **没有 package-lock.json** — `.gitignore` 屏蔽
- **没有 dist/ 目录** — `kexvim.js` 在根目录
- **没有 chunk 文件** — esbuild 单文件
- **没有 sqlite shim** — esbuild 保留 `node:sqlite` 前缀，Node.js 22 原生支持
- **只有三个管理脚本**：`kexvim.sh` `kexvim.ps1` `kexvim.bat`（每个支持 `init|update|restart`）
- **元文件**：`package.json` `.gitignore` `LICENSE` — 这些保留但公开仓用户不直接使用
- **Windows 安装命令**: `irm https://gitee.com/moscowzk/kexvim/raw/main/kexvim.ps1 | iex`（这是一个 .ps1 脚本，不是 zip）
- **运行**: `node kexvim.js`（不需要 tsx，Node 22+）
- **许可证**: MIT (`LICENSE`)

## 类型检查

```bash
npx tsc --noEmit        # 仅类型检查（不输出文件）
npm run build:dev       # 类型检查 + esbuild 编译到 dist/dev.mjs
```

## 开发流程变化（历史）

kexvim 的 TS 运行时方案经历过几次迭代，了解历史有助于理解当前选择。详细对比见 [references/build-workflow.md](skill://kexvim-development/references/build-workflow.md)。

| 方案 | 问题 | 当前 |
|------|------|------|
| `node --experimental-strip-types src/Main.ts` | 不支持 enum、构造器参数属性 | ❌ |
| `npx tsx src/Main.ts` | 依赖 tsx，Windows 上 node 22 会抢在 tsx 前拦截 .ts | ❌ |
| `tsc` 编译到 dist/ + `node dist/src/Main.js` | 需要改所有 import 为 `.js` 后缀，繁 | ❌ |
| **tsc --noEmit + esbuild 编译到 dist/dev.mjs** | import 无后缀，esbuild 141ms 完成 | ✅ 当前 |

**核心规则**：所有 `.ts` 文件从不直接运行。运行时只有编译后的 `.mjs`。

## 路径约定

| 变量 | 当前值 | 说明 |
|---|---|---|
| 代码目录 | `<项目根>/` | 硬性统一，所有设备一致 |
| Git 仓库 | `<项目根>/` | 运行目录就是 git 工作树 |
| 日志 | `<项目根>/data/kexvim.log` | |
| PID | `<项目根>/data/kexvim.pid` | |
| 数据库 | `<项目根>/data/kexvim.db` | |
| 配置 | `<项目根>/data/config.yaml` | |
| 环境变量 | `<项目根>/data/.env` | |
| 会话 | `<项目根>/data/sessions/` | session_search DB |
| 用户技能 | `<项目根>/data/skills/` | auto-saved skills, gitignore |
| 私仓 | `git@gitee.com:moscowzk/kexvim-dev.git` | |
| 公仓 | `git@gitee.com:moscowzk/kexvim.git` | |
| Hermes 参考 | `~/.hermes/hermes-agent/agent/` | 改前先看对应 Hermes 实现 |

## 用户偏好（中文界面，QQ Bot）

- **中文回复**
- **严格对齐 Hermes，不自由发挥**
- **先回滚验证根因，再修**
- **分析给根因链，不是直接给修法**
- **改完先验证再告知**
- **不要归因于 LLM**
- **路径一致性是硬性规定**
- **证据先行** — 报告结论前先给原始证据
- **参考源码优先取 NAS** — 移植功能时先解压 `/mnt/nas/pi-main.zip` 看 Pi 源码，不凭记忆实现
- **架构理解第一** — 用户会纠正错误的位置判断。写代码前先确认改哪里、路由怎么走
- **build 流程绑定当前方案** — 当前用 `tsc --noEmit` + esbuild，import 无后缀。改动前先看 [references/build-workflow.md](skill://kexvim-development/references/build-workflow.md) 了解历史。不要试图切回 tsc emit 或加回 `.ts`/`.js` 后缀
- **TUI 交互式树导航** — `/tree` 进入 raw mode，↑↓选节点，Enter 确认，q 退出

## 会话树（Pi 风格，已完全对齐）

从 Pi（NAS `/mnt/nas/pi-main.zip`）移植的树结构会话模型，完整支持分支、压实、标签、模型切换追踪。

### 实现范围

- `messages` 表加 `parent_id`/`entry_type`/压实字段/标签/模型字段
- `sessions` 表加 `parent_session_id`
- `EntryType`: `message` `compaction` `branch_summary` `label` `model_change` `thinking_level_change`
- `SessionStore` 加 `loadTree()`/`fork()`/`buildContext()`/`printTree()`/`appendEntry()`/`buildContext()`
- `Compactor.ts` 实现切割点查找 + token 估算 + LLM 摘要生成 + 压实条目插入
- `Main.ts` 消息路由拦截 `/tree` `/fork N` `/compact` `/label N text` `/model provider modelId`

### 关键规则

- **命令在消息路由层拦截**（Main.ts 的 message handler），不在 Guardian 里。Guardian 是 `repair/` 专用维修通道。
- **自动压实**：每条正常消息回复后检查上下文 token，超阈值则 fire-and-forget 异步触发压实。
- **压实不删除数据** — 完整会话在磁盘上，`/tree` 仍可回溯到压实前的点。
- **增量压实**（update compaction）：如果会话已有压实条目，下次压实用 `buildUpdateCompactionPrompt()` 把新消息合并到已有摘要，不从头生成。通过 `getSummary` 回调的 `previousSummary` 参数传入。
- **分叉时生成分支摘要**：fork 时在源会话插 `branch_summary`，子会话第1条也是 `branch_summary`，两端记录对方 ID。
- 详细实现参见 [references/pi-session-tree.md](skill://kexvim-development/references/pi-session-tree.md)

### DB Migration 踩坑

`CREATE TABLE IF NOT EXISTS` 对已存在表是空操作。如果旧表缺某些列，而 `CREATE TABLE` 语句里包含引用这些列的 `CREATE INDEX`，SQLite 会抛 `no such column` 异常，整个 `exec()` 失败。

**修复**：把 `CREATE INDEX` 拆到独立常量，在 ALTER TABLE migration **之后**才执行：

```typescript
this.db.exec(SCHEMA_MESSAGES);         // CREATE TABLE IF NOT EXISTS（不含索引）
for (const col of [...]) {             // ALTER TABLE ADD COLUMN
  try { this.db.exec(`ALTER TABLE messages ADD COLUMN ${col} TEXT`); } catch {}
}
try { this.db.exec(SCHEMA_MESSAGES_INDEXES); } catch {}  // 索引在列存在后才建
```

同理，`CREATE VIRTUAL TABLE` 的 FTS 定义也要拆开，因为 `messages_fts` 的 fts5 依赖 `messages` 表存在但与列迁移无关。

## References

- `references/agents-dot-md-template.md` — AGENTS.md 模板（Pi 派生最佳实践）
- `references/build-workflow.md` — build 流程说明（tsc --noEmit + esbuild）
- `references/debugging-empty-stream.md` — 空流调试（events=1, contentLen=0）
- `references/deepseek-interim-text-quirk.md` — DeepSeek interim 文本特性（流式感知）
- `references/deepseek-streaming-message-tool-calls.md` — DeepSeek 流式 `message.tool_calls`（非 delta.tool_calls）
- `references/esbuild-node-sqlite.md` — esbuild + `node:sqlite` 编译
- `references/features-2026-07-27.md` — 2026-07-27 新增功能清单
- `references/gitee-ssh-troubleshooting.md` — Gitee SSH 故障排查
- `references/hermes-progress-notification-architecture.md` — Hermes 中间进度通知架构（源码级参考）
- `references/kexvim-streaming-infrastructure.md` — 流式 agent loop 基础设施参考
- `references/memory-auto-save.md` — memory 自动保存（不等用户提示）
- `references/message-persistence-hermes-vs-kexvim.md` — 消息持久化 Hermes vs Sage 对比
- `references/onebot-vs-qq-api.md` — OneBot v11 vs QQ 官方 API（编辑能力）
- `references/pi-session-tree.md` — Pi 会话树架构（已实现）
- `references/platform-adapter-testing-pitfalls.md` — 平台适配器测试陷阱（2026-08 实测）
- `references/post-merge-cleanup.md` — 合并后清理模式
- `references/qq-4000-char-split.md` — QQ Bot API 4000 字符上限与拆分
- `references/release-build.md` — release 构建
- `references/release-workflow.md` — release 工作流
- `references/restart-procedure.md` — 重启脚本（历史）
- `references/restart-safety.md` — 重启安全性（先启后杀原因）
- `references/session-recovery.md` — 会话恢复（messages 表实现）
- `references/session-search-fts-pattern.md` — SessionSearchTool FTS5 查询模式
- `references/subagent-delegate-task.md` — 子代理/DelegateTask 架构
- `references/tool-call-id-persistence.md` — tool_call_id 持久化（API 400 修复）
- `references/unified-deployment.md` — 统一部署（SAGE_DIR，历史）
- `references/vps-maintenance.md` — VPS 日常维护
- `references/windows-tsx-compat.md` — Windows Node 22 TS 兼容性
