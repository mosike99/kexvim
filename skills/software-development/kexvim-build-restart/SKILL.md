---
name: kexvim-build-restart
description: "kexvim 构建-重启闭环：产物、kexvim restart、自重启、验证、cmd 陷阱"
license: MIT
version: 1.0.0
author: agent
platforms: [win32, linux, darwin]
metadata:
  kexvim:
    tags: [kexvim, build, restart, daemon, dev, dist]
    related_skills: [kexvim-development, kexvim-restart]
---

# kexvim 构建-重启闭环

> 2026-07-31 起多轮实测沉淀。本技能覆盖 kexvim 开发/运维的"改码→构建→重启→验证"全闭环：
> 重启机制终版、全局命令定位原理、产物验证陷阱、会话自重启红线、cmd 环境陷阱。
> 公共技能（随 kexvim 发布）。

## 总纲铁律（用户定案）

**kexvim 自身的一切功能一律写成 src/ 正式代码或主进程内建逻辑，禁止任何独立脚本形态**
（外部 watcher、data/scripts/*.mjs、_restart_*.mjs 一次性脚本、RestartOnce 一次性入口
等——全部是历史弯路，作废）。功能迭代先问"能不能进 src/"，写独立脚本 = 直接否。

## 重启机制现状（终版）

**单入口定案（2026-08-06 用户最终版，覆盖所有旧机制）**：重启唯一入口 = `kexvim restart` CLI
（Bootstrap.ts → CliHandler.restart → `src/commands/RestartKexvim.ts` 的 `restartKexvim(root)`；
`npm run restart` 已删除 2026-08-04）。**daemon 重启一律由用户终端跑 `kexvim restart`**——
agent 会话内 terminal 直跑必失败（2026-08-11 实锤：restart 命令进程是 daemon 直接子进程，
`taskkill /T` 树杀把执行者自己一起杀 → spawn 新 daemon 没执行 → 旧死新不启，见诊断清单 7）；
**任务进行中禁止重启**（杀树丢回合，2026-08-06 二次实锤）。
⚠️ **旧内部机制已全部删除（2026-08-06）**：IPC 8790 端口、文件轮询、
worker parentPort 通道——**别再造内部文件/端口/通道（写了无效）**；自重启不用
任何内部通道，直接跑命令；WebRestarter 由 restartKexvim 一并重启 web(8787)。

**`kexvim restart` 内部实现要点**：

1. **版本无关**：`findRunningKexvim()` wmic 枚举 node 进程，CommandLine 匹配
   `dev.mjs|kexvim.js|Main.ts` 提取**实际在跑的入口**，谁在跑就用谁；无运行实例才兜底
   `resolveDaemonEntry`（dist/dev.mjs → kexvim.js → src/Main.ts）
2. **平台识别**：process.platform 分支（win32 → wmic 枚举 + taskkill /F（**无 /T**，见诊断清单 7）；非 win32 →
   pkill / adapter.killProcess），命令形态无需区分平台
3. **拉起**：`spawn(process.execPath, [entry, "--daemon"], { cwd: root, detached: true })`，
   并补 data/.env 缺失 key 到 env——用户终端进程无 job object 约束，detached 有效
   （WMI 已移除，"依赖外物，违反用户哲学"）
4. 就绪检测 = 轮询 `data/kexvim.log` 的 "Guardian agent 已就绪"/"kexvim 已就绪"（20s 超时）
5. 杀旧 = 只杀启动前记录的 PID（`taskkill /PID <pid> /F`，**无 /T**——daemon 树内 watchdog/agent/guardian 全是 worker_threads 线程，/T 只会把正在执行 restart 的命令进程（daemon 直接子进程）树杀，见诊断清单 7），跳过新 PID
6. **顺序铁律（2026-08-10 用户改序，commit 41810d5）**：**先杀旧进程树再启新 daemon**——
   避免 QQ 网关单连接抢占（旧实例还活着时新实例连不上 QQ 网关）。⚠️ 与早期「先拉新再杀旧」
   相反，以 RestartKexvim.ts 当前代码（杀旧 → spawn 新 → 等就绪）为准

## 全局命令 vs 动态定位（两层机制）

用户问"全局 kexvim 命令怎么定位到程序入口"时的完整链路，**全局命令是静态路标，动态定位只发生在 restart 内部**：

- **第一层：全局 `kexvim` = 静态启动器，不做动态定位**。`kexvim init` →
  `CliHandler.setupPath(home)`（CliHandler.ts:20-53）创建启动器 `kexvim.cmd`
  （内容 `@echo off\r\nnode "%~dp0kexvim.js" %*\r\n`；Unix 为 sh 版）并加 PATH。
  `%~dp0` = 启动器同目录 → **永远只跑同目录的 kexvim.js**（安装版单文件），不查运行
  实例、不分 dev/release。本机佐证：`where kexvim` → `D:\kexvim-dev\kexvim`
  （sh 启动器，指向同目录 `dist/kexvim.mjs`）
- **第二层：动态定位只发生在 restart 内部**。`kexvim restart` → kexvim.js 收到
  `restart` 参数 → Bootstrap.ts:124 识别子命令 → `CliHandler.handleCliCommand(cmd,
  userDataDir)`（homeDir = `path.resolve(userDataDir, "..")`）→ `restartKexvim(homeDir)`。
  入口由 `findRunningKexvim()` wmic 枚举提取；无运行实例才 `resolveDaemonEntry()` 兜底
- **参数区分**：`restart` = 用户敲的 CLI 子命令；拉新实例用 `--daemon` 哨兵参数
- **文件名事实**（常见误解）：dev 产物 = `dist/dev.mjs`（不是 dev.js）；release =
  `kexvim.js`（不是 release.js，release 目录无 src）；源码直跑 = `src/Main.ts`

### kexvim 全局命令安装（Windows 启动器，2026-08-11 实测）

- **Windows 必须有 `.cmd` 扩展名**：旧 `kexvim` 是 sh 脚本（无扩展名，`#!/bin/sh`），
  PowerShell/cmd 不认 → `无法将"kexvim"项识别为 cmdlet`（`where kexvim` 找得到但执行不了）。
  修复：`InstallKexvim.setupPath`（InstallKexvim.ts:50-83）Windows 分支生成 `kexvim.cmd`
  （dev.mjs 优先、release 兜底），且 **init 已初始化也补装**（原 `data/.env` 存在即 return，
  永不生成启动器——本机 kexvim.cmd 缺失的根因）
- ⚠️ **setx 1024 字符硬限制会截断 PATH**（2026-08-11 实锤破坏）：setupPath 曾用
  `setx PATH <process.env.PATH 拼接>` → 用户 PATH 1338 字符被截到 1024 → 注册表损坏、尾部
  条目全丢。**PATH 写入一律用 PowerShell API** `[Environment]::SetEnvironmentVariable('Path',
  $newPath, 'User')`（无 1024 限制）；恢复被截断的 PATH = 从 setx 前启动的进程内存 env 拿
  完整值重写（当前进程 PATH 若完整可救）
- **任意目录可用**：`resolveUserDataDir` 用 cwd 回溯找 package.json，在
  `C:\Users\Administrator` 等非项目目录跑失败 → 修复：cwd 回溯失败后回退到**入口文件
  （dist/dev.mjs）所在目录**回溯定位项目根。用户期望 `kexvim restart` 从任何目录可跑
- ⚠️ **regex 盲区**：`findRunningKexvim` 匹配 `dev\.mjs|kexvim\.js|Main\.ts`，
  **不匹配 `kexvim.mjs`**——release bundle 形态 `dist/kexvim.mjs` 若在跑会被漏检，
  重启走兜底 dev.mjs。本机 `D:\kexvim-dev\kexvim` 恰好指向 kexvim.mjs，属潜在雷

## dev 运行形态

- 构建产物：`dist/dev.mjs`（esbuild 单文件 bundle）
- 主进程：`node dist/dev.mjs`
- 源码入口：`src/Main.ts`（`npx tsx src/Main.ts` 可直跑，正常形态跑 bundle）

## 改码 → 生效闭环

```
改 src/*.ts → npx tsc --noEmit（类型检查过才继续）→ npm run build:dev → 重启
```

## restart 自动构建（2026-08-07 用户「每次重启不会自动构建吗」后实现）

**`kexvim restart` 现在自动检测源码变更并构建**（`src/commands/RestartKexvim.ts`）：

- 检测：`needsRebuild(root, distFile)` = `src/` + `packages/` 的 `.ts` 最新 mtime 是否晚于 `dist/dev.mjs`（跳过 node_modules/dist/data/.git 目录）；dist 不存在 = true
- 有变更 → 自动 `npm run build:dev`（tsc 类型检查 + esbuild，timeoutMs 120000，走 CommandRunner 带 cwd）→ 构建成功才继续重启
- **构建失败 → `process.exit(1)` 中止重启**（绝不拿旧产物重启后误以为新代码生效）
- 无源码变更（release 部署无 src、连续 restart）→ 跳过构建，秒级重启
- 效果：**改码闭环简化为一句话——改 src → `kexvim restart`（或 `node dist/dev.mjs restart`）一步构建+重启生效，不用再手动 `npm run build:dev`**
- ⚠️ 范围边界：restart 自动构建只覆盖 daemon 入口的 dist 产物；**web 进程（`node dist/dev.mjs web`）改动仍需 build:dev 后手动重启 web 进程**（web 是独立进程，restart 虽经 WebRestarter 一并拉起，但自动构建时机在 restartKexvim 开头，产物是新的——web 进程重启本身仍按「重启语义」节处理）
- 验证（needsRebuild 单元级）：dist 最新→false / touch 源文件→true / dist 再更新→false

- `npm run build:dev` = `tsc --noEmit && esbuild → dist/dev.mjs`（dev 唯一正确构建）
- `npm run build` = esbuild → `dist/kexvim.mjs`（**release 产物，dev 进程不加载**）——
  误跑它只更新 kexvim.mjs，`dist/dev.mjs` 不动，构建成功却以为已生效（2026-08-03 实测踩坑）
- 类型检查过滤（cmd）：`npx tsc --noEmit 2>&1 | findstr /c:"error TS" | findstr /v /c:"node_modules"`
  （无匹配 = 无类型错误；用 `&& echo TSC_OK` 确认 tsc 退出码）
- ⚠️ 核心陷阱：**运行中的 kexvim 加载的是旧产物**——源码改动后不重建/不重启，实例行为不变
- ⚠️ 重启范围（2026-08-05 实测 → **2026-08-10 已根治**）：旧行为 `kexvim restart` **只重启 daemon**——独立进程 `node dist/dev.mjs web`（Web UI，8787）若在跑则继续用内存里旧 IndexHtml。**现 WebRestarter 已改名 `restart` 且"无论是否在跑都拉起"**（在跑 = 杀旧换新 bundle；没跑 = 主动 spawn，修复 `restartIfRunning` 的 no-op：web 未在跑时 restart 后 web 保持消失）——`kexvim restart` 现在**同时覆盖 daemon + web**。改动涉及 `src/web/*` 时仍可用三件套（build:dev + 重启 daemon + 重启 web 进程），但 `kexvim restart` 一步已够；验证 = 对比 web 进程 CreationDate ≥ 构建时间 + **restart 后 8787 必须 LISTENING（缺 web = WebRestarter 调用链断了，别默认 daemon 起来了就收工）**

## 拉取远端更新 → 重建 → 重启

1. `git fetch origin && git status`（看 behind 几个 commit，确认可快进）
2. `git pull --ff-only`（本地有未提交改动会拒绝，先处理）
3. `npm run build:dev`
4. 产物新鲜度：`findstr /c:"<新代码独有标识符>" dist\dev.mjs`
5. 重启 = 用户终端跑 `kexvim restart`（agent 会话内 = terminal `node dist/dev.mjs restart`，见诊断清单 7）

git pull 失败排查：behind 且本地有改动时 `--ff-only` 拒绝 → 先 `git status` 看未提交改动，
工作区干净才拉；拉完必看 `git log --oneline -5` 确认合入范围。

## 提交推送（改码完成后）

1. `git status --short` 先看改动范围
2. **提交前先 `npm run build:dev` 验证**（tsc + esbuild 全过才提交，绝不推送坏构建）
3. 只 add 相关文件（如 `git add src/AgentRuntime.ts src/runtime/`），不 `git add -A` 兜底
4. 提交风格（仓库惯例）：conventional 前缀 + 一行中文描述，括号补细节——
   `refactor: AgentRuntime 按领域拆分为 AgentRuntimeCore + 4 个 mixin（...）`
5. `git commit -m "..."` 与 `git push` 用 `&&` 串联
6. 同步验证：`git status -sb` 无 ahead/behind + `git log origin/main..HEAD --oneline` 空输出 = 已推齐
7. push 被拒 = 远端有本机外新提交：`git fetch origin` → 看两边 diff 范围 →
   `git pull --rebase origin main`（本地有新 commit 时不能用 --ff-only）→ 再 push
   （rebase 后本地 hash 会变，属正常）

## 「restart 很少成功」诊断清单（2026-08-11 用户提问沉淀）

用户问"`kexvim restart` 到底有什么问题，很少成功过"时按序排查（全部代码级证据）：

1. **先验证 restart 是否真正执行过**（头号原因，2026-08-11 多轮实锤）：
   对比 daemon/web 进程 StartTime vs 声称的"执行重启"时间——**PID/StartTime 未变 = 没真执行**。
   本次会话多轮陷入"说了没做"循环（说「执行重启」但无工具调用），daemon 42000 是 16:54
   遗留、web 46320 是 19:14 手动 PowerShell 拉起的——**"web 没重启成功"的真相常常是
   restart 根本没跑，不是代码 bug**。实锤手法：`(Get-Process -Id <pid>).StartTime` 对比
   dist mtime 与声称的重启时间点。
2. **daemon 内存旧代码 ≠ dist 新代码**：dist mtime 晚于 daemon StartTime = daemon 跑旧内存。
   本次：WebRestarter 源码 15:26 改、dist 19:04 构建，但 daemon 16:54 启动 → 此时跑 restart
   走的仍是旧 no-op 逻辑 → web 没被拉起。**改源码 ≠ 修复生效，daemon 必须重启过才加载新代码**；
   用户报"web 重启失败"时先查 daemon 是否真的重启到了新 dist。
3. **顺序铁律 = 先杀旧再启新（2026-08-10 用户改序，RestartKexvim.ts:179-196）**：
   杀旧(taskkill /F 无 /T) → spawnFreshDaemon → 等就绪(30s 仅告警) → WebRestarter.restart。
   **杀旧后 spawn 失败（返回 null → process.exit(1)）= 空窗无 daemon、无回滚兜底**。
4. **findRunningKexvim regex 盲区**（RestartKexvim.ts:87）：匹配 `dev\.mjs|kexvim\.js|Main\.ts`，
   **漏 `kexvim.mjs`**（release bundle）→ 重启走兜底 dev.mjs，dev/release 混淆。
5. **就绪检测 30s 超时仅告警**（waitReadyFromLog）：超时不算失败但**不杀新进程**、无自动恢复。
6. **RestartLoopGuard 断路器**：60s 内 >3 次启动 → TRIPPED → 停止拉起，需 `kexvim clear-loop`
   手动解除——反复重启 = 假"失败"。
7. **agent 会话内跑 restart = 自杀且新 daemon 起不来（2026-08-11 实锤根因，用户亲眼确认）**：
   agent terminal 命令进程是 daemon 的**直接子进程**（进程树实测：cmd.exe ← Parent=daemon
   PID），`taskkill /PID <daemon> /F /T` 递归杀树 → **把正在执行 restart 的进程自己一起杀掉**
   → `spawnFreshDaemon`（RestartKexvim.ts:196）根本没执行 → 旧 daemon 死、新 daemon 不启。
   用户观察："你做了，成功杀死了自己，但没启起来"。**用户跑必成功**：用户终端不在 daemon
   树内，taskkill /T 杀不到 restart 进程 → 完整跑完 spawn。差异一句话：**我的命令进程是
   daemon 的子进程，你的不是**。用户追问「restart 命令不是起的独立进程吗」时答：restart
   进程本身确实是独立 node 进程（代码逻辑不依赖 daemon），但「独立」只决定**代码逻辑**，
   不决定**进程树归属**——树归属看**父进程**，与进程自身无关；taskkill /T 杀整棵进程树，
   不区分「这个进程是不是独立的 restart 命令」。**修复（2026-08-11 已落地并实测成功，用户确认「成功了」）**：
   RestartKexvim 杀 daemon 改为 `taskkill /PID ${pid} /F`（**去掉 /T**）——daemon 树内
   watchdog/agent/guardian 全是 **worker_threads 线程**（WorkerLauncher.ts:203），不是独立
   进程，`/T` 没有可清理的对象，只会把正在执行 restart 的命令进程（daemon 直接子进程）一起
   树杀 → spawnFreshDaemon 没执行。去掉 /T 后 agent 会话内跑 `kexvim restart` 也成功：
   kill 只杀 daemon 本体，restart 命令进程存活 → spawn 新 daemon。⚠️ **agent 跑时回合仍会断**
   （agent 线程随 daemon 一起死，属预期），新 daemon 起来后等新消息；用户终端跑 restart
   依旧最稳（无回合中断）。
8. **EPIPE 递归刷屏（kexvim.log GB 级 + 某 node 进程 CPU 100%，2026-08-11 实锤）**：
   restart 残留进程 stderr = 用户终端管道，用户跑完/等不及**关终端窗口** → 读端断 → 后续
   console.warn/log 写 stderr 抛**异步 EPIPE** → uncaughtException handler（Main.ts）→ handler
   里 console.error → 又异步 EPIPE → **无限递归**（try/catch 抓不住异步 EPIPE——流写入错误
   异步抛出，同步 catch 无效）。后果：kexvim.log 刷到 1.55GB + 进程 100% CPU 满负荷 → 整机
   卡 → daemon 消息处理变慢/回合中断 → 用户看到"任务又断"。**诊断**：
   `Get-Process -Id <pid> | Select CPU,StartTime`——递归者 CPU 秒 ≈ 墙钟时间（实测 restart
   36032 CPU 438s vs daemon 46424 12.3s）。**止血**：taskkill /F 杀递归进程（非 daemon 可安全
   杀）+ 删 GB 级 kexvim.log。**修复**：①handler 内彻底移除 console.error（只 appendFileSync
   同步写文件）；②waitReadyFromLog 用 readFileSync 读**全文件**，大文件每次读取阻塞数秒 →
   30s 超时形同虚设、restart 挂死 → 改只读文件尾部（最后 N KB）；③**restart 末尾显式
   `process.exit(0)`**——残留句柄（日志 fd、定时器）挂住 → restart 进程永不退出（实测 36032
   残留 121MB 一直在）→ 用户关终端断 stderr 管道 = EPIPE 递归的**入口**；④**GB 级 kexvim.log
   被 daemon worker 的 stdout/stderr fd 持有，运行期 `del` 不释放磁盘**（2.53GB 删除后文件
   仍在、磁盘未释放）——释放时机 = daemon 重启（旧 fd 关闭，新 daemon 重建空日志，实测
   2.53GB → 0 MB）。**完整修复三件套验证**：`process.exit(0)`（dist 搜 `process.exit(0)`）、
   tailLog readSync 尾部读取、handler 内无 console。

## 重启后三重验证

**先判别场景**：用户说"重启了"时，先 `git log -3 --oneline` + `git status` 看有没有
**待验证的改码**（改了 src 未验产物/未确认加载）——有才跑验证；没有（工作区干净、纯例行
重启）则简短确认就绪即可，别为不存在的改动跑验证。session_search 重启后第一搜常返回
空/旧会话，近期工作主题以 git log 为准。

**验证全过后立即收尾**（2026-08-05 用户质问"一个任务为什么一直不会结束"）：报告 = 改动
内容 + 已验证项（构建过/特征串在 bundle/新 daemon 起来了）+ **剩余动作一句话**（如"Web UI
进程还是旧代码，需重启才生效，要我重启吗"）。不要为次要细节无限扩查（追父进程、启动来源、
端口拓扑等）——验证核心闭环即停。

⚠️ **收尾铁律（2026-08-05 task-tree 三连报障修订）**：剩余动作**若是修复本身且 agent 已实测可做**（如重启 web 进程，见「后台进程拉起」——agent 可直接做）→ **直接执行完毕再报告，不问「要我重启吗」**。上轮事故：agent 停在"看重启方式后重启："就断，8787 旧 web 进程一直没换，用户连报三次「还是看不到」。**用户报"还是看不到 XX"时第一动作 = 查该端口进程 StartTime 是否 ≥ dist 构建时间**，旧进程在 = 重启承诺未兑现，直接执行 kill + Start-Process 重启闭环，不再回头查代码。只有需要用户决策或环境外动作（换机、装依赖）才询问。

⚠️ **删除类改动后的「还能看到」变体（2026-08-05 task-tree 第二轮实锤）**：用户报「为什么我还能看到 修复 tool_definition goal:analysis_complete」——UI 删了用户却仍看到内容。两因素叠加：①**dist 未重建 + web 进程跑旧 bundle**（面板标记 tt-name/task-tree 还在产物里），判据同「还是看不到」：web 进程 StartTime 早于构建时间；②**可见字符串是 DB 数据不是 UI 代码**：task_graphs 表按 chat_id 存 graph_json，节点名 = buildTaskGraph 规则模板「修复 {entity} goal:{field}」拼接（LLM 只在规划层，节点名非 LLM 生成），当前会话跑过 run_state_driven_goal 就必有数据——UI 删除后数据仍在表里属**预期**（持久化保留），别误判「代码没删干净」。修复闭环 = build:dev → 杀旧 web PID → PowerShell Start-Process 拉起 → 新 PID StartTime ≥ dist mtime。**用户报障内容形如规则/LLM 生成文本时，先查 task_graphs 表确认字符串来源（数据），再验 bundle（代码）——两层都要在报告里讲清**。bundle 删净验证：`powershell -Command "$c=Get-Content 'dist\dev.mjs' -Raw; 'tt-name in dist: ' + $c.Contains('tt-name'); 'task-tree in dist: ' + $c.Contains('task-tree')"`（PowerShell -Raw Contains 比 findstr 直观，仅 ASCII 标识符可靠）。

**最新提交是否已生效（回答"现在还有哪些可以做/还有哪些没生效"时先查这个）**：
`dir dist\dev.mjs` mtime 对比 `git log -1 --format="%h %ad" --date=iso` 提交时间——
**dist mtime < 提交时间 = 最新提交未打包**，运行实例必是旧代码；再
`wmic process where "processid=<pid>" get creationdate` 看 daemon 启动时间。
⚠️ **daemon 重启过 ≠ 加载了新提交**（2026-08-04 实测：daemon 12:50 启动但 dist 12:28
构建、最新 commit 12:50 → 实例跑的是旧构建，需重新 build:dev + 重启）。
中文特征串在 bundle 里因 esbuild charset:ascii 转义永远 `includes()` false，别用中文
当存在性判据；可靠判据 = dist mtime 对比提交时间 + ASCII 标识符。

全过才算加载新代码：

1. 进程：`wmic process where "name='node.exe'" get ProcessId,CommandLine | findstr /i "dev.mjs"`
2. 产物：`dir /o-d dist\dev.mjs` mtime 晚于**提交时间**（`git log -1 --format="%h %ci %s"`）——
   别用 src 文件 mtime（2026-08-02 实测：改动不在 Main.ts 时其 mtime 显示旧日期，不可靠）
3. 特征串：`findstr /c:"<新代码独有标识符>" dist\dev.mjs` +
   `powershell -Command "(Get-Process -Id <PID>).StartTime"` 启动时间 ≥ 构建时间

特征串选新函数名/字段名/字符串字面量；**不选注释**（esbuild 剥离）、**不选 emoji**
（findstr 通配陷阱）。

**当前会话 = 新实例判定**（2026-08-02 实测）：会话开始时间（Conversation started 的
UTC 时间 +8）≈ 进程 StartTime（±1 分钟内）→ 当前会话本身就是重启后的实例，修复是否
生效可直接在会话内让用户确认。

## 产物新鲜度验证陷阱（esbuild + cmd findstr）

- **esbuild 默认移除注释** → 不能用注释文本当特征串搜 bundle（得到 OLD_BUNDLE 假阴性）
- **cmd findstr 对 emoji 匹配不可靠**：`findstr /c:"⚙️"` 把 emoji 转成 `??` 通配，
  误匹配代码里的 `??` 运算符 → 永远显示 STILL_IN_BUNDLE。别用 emoji/非 ASCII 做锚点
- 可靠验证法（删了字段搜字段名期望不存在，加了逻辑搜新标识符期望存在）：

  ```
  findstr /c:"_lastInterimTime" dist\dev.mjs >nul 2>&1 && echo STALE_BUNDLE_HAS_FIELD || echo FRESH_BUNDLE_FIELD_GONE
  ```

## esbuild 不支持动态 import（新命令/新文件必踩，2026-08-08 实锤）

新加 CLI 命令时若写 `await import('node:sqlite')` / `require('node:sqlite')` → esbuild bundle 失败或产物里没有该命令（跑 `node dist/dev.mjs sessions` 无输出、dist 里搜不到命令标识符）。**一律顶层 import**（AGENTS.md 铁则：禁止动态 import，本就该如此）。新增 src/commands/ 命令后验证产物：`findstr /c:"<命令类名>" dist\dev.mjs`，查不到 = bundle 失败或 tree-shake，先查动态 import。

## esbuild charset:ascii — 产物非 ASCII 全是 \uXXXX 转义

esbuild 默认 `charset: ascii`，bundle 里中文/emoji 都被写成 `\u2705` 这类转义序列
（文件原文就是反斜杠+u+hex，不是解码后的字符）。后果：

- 搜**解码后的**中文/emoji 必然找不到（`includes('✅ Kexvim 已重新上线')` = false）——
  正常现象，不是字符串丢失，**不要据此误判"没打进 bundle"**
- 正确验证法：搜转义片段本身——`d.includes('u5DF2')`（node 字符串里 `\uXXXX` =
  单反斜杠+uXXXX，恰好匹配文件原文的转义序列）
- 先确认方法标识符在不在 bundle 里（esbuild 可能 tree-shake 未引用的导出），
  区分"没打进"和"被转义"
- **最稳 = 直接搜 ASCII 代码特征，别搜中文/注释（2026-08-12 实测）**：中文**注释**
  被 esbuild 剥离（不在 bundle）；中文**文案**被转义成 \uXXXX（hex 大小写以产物为准，
  node includes 大小写敏感，猜错大小写必假 NO）——两坑叠加时中文搜索必失败。可靠做法 =
  搜赋值语句/标识符/class 字符串等 ASCII 代码特征（实测
  `treeSelectedId = Number(el.getAttribute('data-task'))` 一次命中），或先 read 产物
  确认转义 hex 实际写法再搜

## 会话自重启红线：dev 实例 = 当前会话进程

⚠️ 改 agent 自身工具代码（skill_manage 等）时，dev 实例 PID 往往就是当前会话进程本身
（2026-07-31 实测 PID 26340 = `node dist/dev.mjs`，即 agent 自己）。会话内 taskkill /
杀树 = 自杀断线，修复无法收尾。

**2026-08-06 二次实锤（同日再犯）**：改的是 **daemon 侧代码**（/new 切会话在
GatewayLauncher + SessionMixin）需要重启 daemon 生效——第一反应却是 terminal 敲
`node dist/dev.mjs restart`（`kexvim` 不在 PATH 时用等价入口替代，机制完全一样）：
16:04:49 执行 → findRunningKexvim 找到 agent 自己 → taskkill /T 杀树 → 16:04:49→16:09:45
空窗 5 分钟、当前回合任务丢失（DB 实锤：期间无 assistant 落库）。**当时结论 = terminal 敲
`kexvim restart` / `node dist/dev.mjs restart` 一律禁止**；**2026-08-11 移除 taskkill /T 后
已可跑**（见诊断清单 7），但 **agent 跑时回合必断 + 当回合任务丢失**——需要重启生效的改动
仍放**任务交付完成后**执行，或交给**用户终端**跑（无回合中断）。注意区分：**web 进程
（`node dist/dev.mjs web`，独立进程）可以 taskkill + PowerShell Start-Process 重启，
只杀 web 不杀自己**；不能杀的是 daemon（= 当前会话进程）。

**guardian 能重启 ≠ agent 能自重启**（2026-08-03 用户质疑"guardian可以重启，按说你也
可以了吧"时的定论）：不是能力问题，是**存活要求不同**——guardian 是可丢弃组件（定位
"最小可用性"，杀树时自己也在树里，一起死是预期，靠外部机制拉起），而主 agent = 当前
会话进程本身，自重启必须"活着把当前回合回完"。**"自杀式 kill + 等外部保活拉起" =
断线 + 回复丢失 + 空窗**，等价手动重启且不可控，无意义。

**三连实锤（agent terminal 工具链场景）**：任何经 terminal 工具链（cmd → node）spawn
的后台进程（含 `detached: true`）都逃不出 **job object**——命令链退出瞬间被连带清理
（launcher 落盘 "launcher spawned detached worker" 后 worker 段从未执行）。**在 agent
terminal 里自重启必然失败，别真去试**；内部轮询机制已删（2026-08-06），
**agent 无任何自重启通道 → daemon 重启由用户终端跑 `kexvim restart`**（用户终端无 job
object 约束，spawn detached 有效）。

**RestartLoopGuard 断路器**：`src/daemon/RestartLoopGuard.ts` 是 60s 窗口内 >3 次启动即
TRIPPED 的断路器，WorkerLauncher 每次启动都 recordBoot。ad-hoc 自重启失败重试 2-3 次 =
TRIPPED → 自动拉起全部停止，需 `kexvim clear-loop`（CliHandler.ts:162）手动解除。
ad-hoc 自重启 = TRIPPED + 断线双杀，禁止。

自重启失败判定手法：`wmic process where "name='node.exe'" get ProcessId,CreationDate,CommandLine`
对比 CreationDate——重启时间点后长时间无新实例 = spawn 未执行（taskkill /T 递归杀树，
脚本自己先死）或新实例立即死亡；直接表现就是查不到任何 `node dist/dev.mjs` 实例、
会话死寂，直到用户手动拉起。

**不重启的验证法（改 agent 自身代码时）**：改完 → tsc + 重建 → 写临时 `verify-<x>.ts`
（直接 import 源码类，`npx tsx` 可跑 TS）断言"修复前必失败的操作现在成功" → 跑通删除 →
正式验证交给重启后的端到端复核。不依赖会话自杀。

## cmd 环境陷阱（terminal 工具默认 cmd，非 PowerShell）

- `Select-Object`/`head`/`tail`/`grep`/`wc` 都是 PowerShell/Unix 命令，cmd 下不存在 →
  过滤/截取一律用 `findstr`（`/c:"A" /c:"B"` = OR；`/v` 反向排除）
- findstr 无匹配返回 1，会掩盖上游命令失败——先单独跑上游确认成功，或 `&& echo OK` 串联；
  **同族陷阱：`git config <未设置项>` 返回 exit 1 也断 `&&` 链**（2026-08-11 实锤：查
  core.excludesfile 未设置 → 后续 git status 没跑，误以为 untracked 为空）——读配置前先确认
  有值，或用 `;` 不行（cmd 不分号）只能换 `||` 兜底或分两步跑
- **`timeout /t N` 在此环境必失败**（exit 1、"错误: 不支持请求的操作"）且**断 `&&` 链** →
  等待一律用 `ping -n N+1 127.0.0.1 >nul`（N+1 次 ping ≈ N 秒）
- **cmd 下 `;` 不是命令分隔符**（会被当参数，报 TS6231）→ 串联用 `&&`（失败即停）
- 别用 `node -e` / `npx tsx -e` 传嵌套引号（必失败 + 留下怪文件名垃圾文件）→
  写临时 `.ts` 脚本文件跑完 `del`；收尾 `git status -s` 清理
- 垃圾文件（git status 的 `?? %d`、`?? 1785609600`、`?? $null` 等：cmd 下未定义变量
  展开为空/重定向失误的 0 字节产物）→ 软删除送回收站（不硬删）：

  ```
  powershell -NoProfile -Command "$shell = New-Object -ComObject Shell.Application; $item = $shell.Namespace((Get-Location).Path).ParseName('<文件名>'); if ($item) { $item.InvokeVerb('delete'); Start-Sleep 2; Write-Output 'sent to recycle bin' } else { Write-Output 'not found' }"
  ```

### 后台进程拉起（web 进程等）——cmd start 弹窗陷阱与正确姿势（2026-08-05 实测）

- **`start "title" cmd /c "node ..."` 会弹可见 cmd 窗口**（用户质问"为什么又跳出了 cmd.exe"）——cmd 的 `start` 默认开新窗口，node 跑在那个可见窗口里
- 正确姿势 = PowerShell 隐藏启动（从 agent terminal 实测存活，进程持续监听直到主动杀）：

  ```
  powershell -Command "Start-Process -FilePath 'node' -ArgumentList 'dist/dev.mjs','web' -WorkingDirectory 'D:\kexvim-dev' -WindowStyle Hidden -RedirectStandardOutput 'D:\kexvim-dev\data\web.log' -RedirectStandardError 'D:\kexvim-dev\data\web-err.log'"
  ```

- ⚠️ **job object 结论修正**：cmd `start` 与 PowerShell `Start-Process` 从 agent terminal 拉起的后台进程**实测存活**（2026-08-05 两次：PID 8328、16456 均持续监听 8787）——"job object 三连实锤"仅限 **node 脚本内 spawn detached** 场景，不是"agent terminal 拉不起任何后台进程"的普适结论；**web 进程重启 agent 可直接做**，不用推给用户
- **cmd 单行命令别用 `goto`**：交互式 cmd 里 `& goto :done` 跳到标签会**跳过后续命令**（2026-08-05：taskkill 后 goto 把 timeout + powershell 启动全跳过，8787 没起来；for 循环还会重复执行）——组合命令用 `&&`/`&` 串联，执行完 `netstat -ano | findstr ":8787" | findstr LISTEN` 验证端口，别假设链条全跑了

## 审批门（ApprovalGate）工作方式（taskkill /F 等危险命令）

terminal 工具对危险命令（taskkill /F、递归删除、force kill 等）有审批门，弹 `approval_required` 才执行：

- **审批按规范化命令文本精确匹配**——用户「批准」只对该命令文本生效；命令文本任何变化（PID 变了、措辞改了）→ 旧批准失效，必须重新审批
- **批准绑定「当前已显示的审批提示」**：系统弹 `approval_required` 后用户回复「批准」才记录；**在消息正文里提前请求批准不可靠**（2026-08-10 实锤：用户批准了我消息里贴的完整命令文本，随后执行——无论短命令版还是与消息完全一致的完整命令版——都再次弹审批；预批准从未匹配任何已显示提示）
- **正确姿势**：①直接执行命令，不必提前请求；②收到 `approval_required` → 把提示里的命令原样展示给用户 → 请用户**看到这条提示后**回复「批准」；③批准后重试**与提示完全相同的命令文本**（任何编辑都使批准失效）
- **用户回复别的字不算批准**（「重启」「继续」等不算，按「批准」字面匹配）；用户先问范围（如「只需要重启web吗」）时，先答清改动范围再请批准
- **禁止变通绕门**：反复改命令措辞或换等价命令绕过审批 = 违规；审批未过就重新展示提示再请批准

## 历史弯路（勿重走）

- 外部常驻 watcher（data/scripts/kexvim-watcher.mjs 轮询内部文件）→ 被用户否决
  （一次性才对）——主进程内建的轮询机制也已删（2026-08-06），一律直接跑命令
- `--restart` 一次性入口（src/daemon/RestartOnce.ts）→ 已删除回收站（"我估计已经有了"——
  命令形态本就有：`kexvim restart`）
- in-tree detached 脚本自重启（_restart_dev.mjs 等）→ 三连实锤失败（job object，见上）
- schtasks 拒绝访问 + `Register-ScheduledTask` 假成功（返回空对象、查不到）——
  任务计划程序路线本机走不通
- WMI `wmic process call create` 逃逸 → 仅 agent terminal 工具链场景需要；用户终端 +
  主进程 spawner 场景已移除（依赖外物，违反用户哲学）
- 旧规则"agent 不要自己重启、交给用户手动"→ 曾作废（2026-08-03 内部文件轮询机制），
  **2026-08-11 移除 taskkill /T 后 agent 已可自跑 restart**（见诊断清单 7，实测成功），但
  回合必断 + 当回合任务丢失 → daemon 重启仍首选用户终端；内部轮询机制 2026-08-06 已删，
  **别再发明文件/端口/通道**（写了无效）

## 相关技能

- `kexvim-development` — kexvim 开发总纲（仓库/构建/路径约定/用户偏好）
- `kexvim-restart` — 重启运维与连接验证（安装版视角）
