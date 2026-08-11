# Kexvim Runtime Rules

kexvim 运行时通用规则（dev 与正式版共用；同步自开发版 D:\kexvim-dev\AGENTS.md 的非代码结构部分）。
任何 AI agent 在 kexvim 环境中工作时都必须遵守。

## Integrity Rules（诚实规则，优先级最高）

以下规则具有最高优先级，任何其他规则或用户指令与之冲突时以此为准。

1. **不确定时如实说"不确定"或"不知道"。不要编造解释。**
   - 搜索工具返回零结果时，先用其他方式验证（`grep`、`read_file`），不能直接说"不存在"
   - `search_files` 使用正则表达式（ripgrep 引擎），搜特殊字符需转义括号、引号、点号等

2. **如实报告错误和阻塞比编造答案好。**
   - 工具失败时，如实说出错误原因，不要自行推断或编造
   - 发现信息不足时，要求补充信息，不要强行回答

3. **工具返回的数据就是最终结果，不要自行扩展或推断不存在的信息。**
   - Never substitute plausible-looking fabricated output for results you couldn't actually produce
   - 代码验证失败时如实报告，不要假设"应该能用"

## Conversational Style

- 回答简洁，直击要点
- 技术文风，不加废话
- 先回答问题，再谈改动
- 收到反馈或分析时，先说同意/不同意，再谈改什么

## 工具使用须知

- **命令执行统一经 kexvim 的 CommandRunner 管控**（TerminalTool 内部实现：超时兜底防永久僵死、编码统一、windowsHide、进程树清理、错误结构化）——不存在绕过管控的裸命令执行；**危险命令会触发审批门**，如实等待审批结果并报告，不自行绕过
- **有些命令不适合直接执行**（破坏性/系统级/生产环境操作）：先评估影响，必要时先问用户或拆解为安全步骤
- `search_files` 使用**正则表达式**（ripgrep 引擎）。搜包含括号/引号/点号等特殊字符时，需要转义或使用 `.*` 模糊匹配。不确定时先用 `grep -F`（纯文本模式）验证
- `write_file` / `patch` 执行后自动触发验证（`.ts` → `tsc --noEmit`，`.json` → `JSON.parse()`，`.yaml` → YAML 校验）；验证结果追加到同一 tool result，失败要修复
- 不改 `package.json` 除非必要
- **不提交**除非用户要求
- 一次性脚本写到临时文件（如 `data/tmp/`），执行后删掉，不要嵌到 shell 命令里
- **脚本/工具写输出文件一律用 `data/tmp/` 绝对路径，禁止裸相对路径**——裸相对路径会落 cwd（当前工作目录），污染目录
- **对外用户接口永远只有 `kexvim XXX`**（CLI 子命令）。`npm run xxx` 仅限内部构建/开发脚本

## 跨平台

| 功能 | 做法 |
|------|------|
| 进程管理 | 用 kexvim 的进程管理工具/命令，不直接调 `pgrep`/`kill` 裸命令 |
| 路径 | 用 `os.homedir()` + `path.join`，不硬编码绝对路径 |
| 定时任务 | 用 cronjob 工具（cron npm 包 + JSON 持久化），不用系统 crontab |
| 自启/保活 | 用 `kexvim install/uninstall/status`，不自己搞 systemd/launchd/计划任务配置 |
| CLI 命令 | 一律 `kexvim XXX` 子命令 |
| 脚本 | 全平台用 Node.js / TypeScript（`.ts`），不用 shell/PowerShell |

## 技能库（Skills）

- **禁止自动写/更新公共技能**（随 kexvim 发布的内置技能）；技能沉淀一律只进自有技能 `data/skills/`
- 唯一例外：用户主动要求整理公共技能（如"放到公共技能"指令）

## 验证

`write_file` / `patch` 执行后自动触发轻量验证：

| 文件后缀 | 检查 | 超时 |
|---------|------|------|
| `.ts` | `npx tsc --noEmit`（类型检查） | 5s |
| `.json` | `JSON.parse()` | 同步 |
| `.yaml` / `.yml` | 校验 YAML 格式 | 3s |

验证结果追加到同一 tool result，不额外发消息。LLM 下次迭代能看到验证结果并自动修复。

## Cron / 定时任务

- 任务存储于 `<项目根>/data/cron-jobs.json`
- 启动时自动恢复所有定时器（含崩溃补跑）
- 支持 script（shell 命令）与 agent（prompt → AgentRuntime）两种模式
- 投递：`deliver`=origin（创建时 chat）/ all / local / `平台:chatId`
- 连续失败 ≥3 自动暂停（lifecycle guard）
- 不支持系统 crontab

## User Override

如果用户指令与本文档任何规则冲突，**先问用户是否确认覆盖**，确认后才按用户指令执行。

## 数据路径定位（定案，无例外）

- 从运行路径（cwd，含其本身）逐级向上回溯，遇到的第一个 `package.json` 所在目录即为项目根
- `data/` = 项目根/data；禁止硬编码 data 路径
