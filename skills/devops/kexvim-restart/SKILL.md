---
name: kexvim-restart
description: "重启 kexvim（安全停旧启新、验证就绪）与连接验证"
license: MIT
version: 4.0.0
author: agent
platforms: [linux, win32, darwin]
metadata:
  kexvim:
    tags: [kexvim, restart, daemon, stop-start, verification]
    related_skills: [kexvim-build-restart, kexvim-development, kexvim-deployment]
---

# kexvim 重启

通过 `kexvim restart`（内部实现 `src/commands/RestartKexvim.ts`）安全重启：**先清理旧进程、再启动新实例、确认就绪**（2026-08-08 用户改序——QQ 网关同一 bot 只允许一个活跃连接，旧"先起后杀"下新 daemon 的 Identify 被旧连接挤掉）。构建/产物/自重启细节见 `kexvim-build-restart`。

## 触发条件

用户说"重启kexvim"、"重启 kexvim"、"restart kexvim"、"重启sage"（旧称）时使用。

## 标准操作

```bash
kexvim restart          # 唯一对外命令（接口铁律：外部命令永远只有 kexvim XXX）
```

（`npm run restart` 已删除，2026-08-04。）

底层流程（`src/commands/RestartKexvim.ts`）：

1. `findRunningKexvim()` 枚举运行中的 node 进程，CommandLine 匹配
   `dev.mjs|kexvim.js|Main.ts` 提取**实际在跑的入口**（版本无关，谁在跑用谁）；
   无运行实例兜底 `resolveDaemonEntry`（dist/dev.mjs → kexvim.js → src/Main.ts）
2. 杀旧：`taskkill /PID <pid> /F`（**无 /T**——2026-08-11 去掉，见步骤 5）杀启动前记录的 PID（杀完才启，新 PID 尚未生成，原"跳过新 PID"逻辑已删）
3. spawn detached 新 daemon（`node <入口> --daemon`），从 `data/.env` 补缺失 env
4. 轮询 `data/kexvim.log` 就绪标记（"Guardian agent 已就绪"/"kexvim 已就绪"，30s 超时**仅告警不杀进程**）
5. **agent 会话内跑 restart**（2026-08-11 实锤+修复）：restart 命令进程是 daemon 直接子进程，
   旧 `taskkill /T` 树杀连执行者自己一起杀 → 旧死新不启；**修复 = 杀 daemon 去 /T**
   （`taskkill /PID <pid> /F`，daemon 树内 worker 全是 worker_threads 线程，无独立进程可清）
   → agent 实测成功，但 **agent 跑时回合必断**（agent 线程随 daemon 死），新 daemon 起来后
   等新消息；daemon 重启首选**用户终端**跑 `kexvim restart`，agent 只验证结果
   （详见 `kexvim-build-restart` 诊断清单 7/8）

## Daemon 模式（后台常驻）

```bash
node kexvim.js --daemon
# 或开发版：node dist/dev.mjs --daemon
```

- `--daemon` 是**长驻进程**：主线程 spawn watchdog/agent/guardian 三 worker 后保持存活。
  ⚠️ **`daemon`（无 `--`）不是子命令**：`node dist/dev.mjs daemon` 不存在该子命令 → 会落进
  **终端交互 REPL**，stdin EOF 即 `exited (1)`（2026-08-11 实锤：误以为拉起第二个 daemon，
  实为交互残留秒退，日志显示 exited(1)）。**真 daemon 判定 = CommandLine 含 `--daemon`**——
  wmic 枚举时区分 `--daemon`（真常驻）vs 无 `--`（交互残留/将退出），别把残留当 daemon。
  前台 `timeout` 命令会超时被杀——这是预期行为，不是挂起。用后台任务或 nohup 方式运行。
- daemon 模式 stdio ignore，主进程 console 不可见；worker 输出落盘 `data/kexvim.log`
  （2026-08-03 起）。要观测实时日志可前台跑 `node dist/dev.mjs`。

## Windows 进程枚举陷阱（2026-08-11 实锤，RestartKexvim.ts 已修复）

- **wmic 表格输出是 UTF-16LE**（BOM `fffe`），CommandRunner 按 utf-8 解码 → 每行穿插 `\u0000`
  → 正则行尾锚定（`\s*$`）永远匹配失败 → `findRunningKexvim()` 返回空 → restart 只杀 pid 文件
  里的进程 → 老 daemon 永远不被杀。**修复：`wmic ... /format:list`**（键值对字段）+ 去 `\x00`
  + 按 `CommandLine=` / `ProcessId=` 字段解析。wmic 表格列还会错位（命令行换行串行到下一行、
  字段对不上），表格模式不可靠
- **Session 0 进程 CommandLine 读不到**（Services 会话，权限隔离）：wmic `/format:list` 和
  PowerShell JSON 都返回空（`CommandLine=` 无值 / null），ExecutablePath 也读不到——任何按命令行
  匹配的枚举都漏掉它。**修复：空命令行兜底**——非空命令行正常匹配；空/缺失命令行的 node.exe 视为
  可疑 daemon 候选（entry 空 → 调用方 resolveEntry 兜底）。实测 8296 即此：老 daemon 被顶掉后
  挂死不退出（QQ 单连接抢占），表现为 Session 0 + 命令行空 + 零网络连接，杀掉安全（非服务托管，
  不会自动拉起）
- **进程身份指纹（netstat -ano | findstr PID）**：活跃 daemon = 多条 ESTABLISHED 443 出站
  （QQ 网关 + DeepSeek API）；web = LISTENING 8787 + 本机连接；僵尸 = 零网络连接。判断"某 PID
  是不是 kexvim"先看连接，别只看创建时间/命令行

## 铁律：说重启必须立刻执行（2026-08-11 用户四次纠正）

- 一旦说"现在执行重启"，restart 命令必须是**同一回合的下一个工具调用**——只发文本"现在重启"
  不调用 = 用户可见的撒谎（用户连纠正四次："重启了吗""你说重启但没有重启""你又没重启"
  "几乎每次说重启都不动作"）
- 为什么容易只说不做：`node dist/dev.mjs restart` 会 taskkill 当前 daemon（agent 所在进程）→
  回合断、回复发不出 → 用户看到最后一句是承诺。属预期，正确姿势 = 先把构建/提交/推送全部做完，
  再把 restart 作为**当回合最后一个工具调用**执行
- 对进程状态的断言先验证再出口：曾断言"8296 从 8/3 一直跑从未重启"，被用户推翻（"我都手动重启
  过好多次了"）——事实是 8296 是无连接的挂死僵尸，活跃 daemon 是 14:45 启动的 25572
  （netstat 有 QQ/LLM 连接）。断言"某进程从 X 时间起没变"前必须核对 CreationDate + 连接指纹

## 验证（关键）

进程存在 ≠ 连接成功。按序检查：

```bash
# 进程存活
wmic process where "name='node.exe'" get ProcessId,CommandLine | findstr /i "dev.mjs kexvim.js"   # Windows
pgrep -f "kexvim.js|dev.mjs"                                                                       # Linux
```

```bash
# 连接真实建立（QQ 网关，Linux）
ss -tnp | grep <pid>        # 期望 ESTAB 到 api.sgroup.qq.com:443
getent hosts api.sgroup.qq.com   # 确认 IP（43.137.144.87 等）

# worker 线程数（主 + 3 worker = 13）
grep Threads /proc/<pid>/status
```

```bash
# 日志 mtime 是否新鲜（别读旧日志）
stat -c "%y" <项目根>/data/kexvim.log   # Linux；Windows 用 dir <项目根>\data\kexvim.log
```

**Stale log 陷阱**：`data/kexvim.log` / `data/kexvim.pid` 可能是**数小时前**旧进程写的。
看到日志里 `正在重连 (尝试 N)` 刷屏先查 mtime，别当成当前进程的故障。

## 凭证验证（QQ 11244 token 错误）

日志报 `GET /gateway: 500 {"message":"token not exist or expire","code":11244}` 时，
先直接实测凭证，别改代码：

```bash
# 1) 换 token
curl -s -X POST https://bots.qq.com/app/getAppAccessToken \
  -H "Content-Type: application/json" \
  -d '{"appId":"<APP_ID>","clientSecret":"<SECRET>"}'
# 返回 access_token + expires_in = 凭证有效

# 2) 用 token 请求 gateway
curl -s https://api.sgroup.qq.com/gateway -H "Authorization: QQBot <token>"
# 返回 {"url":"wss://..."} = 网关正常
```

两步都 200 → 凭证和网关都没问题，故障在别处（旧进程占日志、旧 bundle、或日志本身是历史）。

## 注意

- **EPIPE 递归刷屏**（2026-08-11 实锤）：restart 残留进程 stderr 断（用户跑完即关终端）→
  console 输出抛异步 EPIPE → uncaughtException handler 里 console.error 又 EPIPE → 无限递归
  → kexvim.log GB 级 + CPU 100%。诊断 = `Get-Process -Id <pid> | Select CPU`（CPU 秒≈墙钟 =
  递归者）；止血 = 杀该进程 + 删日志；修复 = handler 去 console.error、就绪检测只读文件尾部
  、restart 末尾显式 `process.exit(0)`（残留句柄挂住 → 进程永不退出 → 用户关终端断管道 =
  EPIPE 递归入口；2026-08-11 实测 36032 残留 121MB 实锤）
  （详见 `kexvim-build-restart` 诊断清单 8）
- **绝不用 `npm start` 前台方式重启**（REPL 遇 stdin EOF 立即退出并连坐杀 workers）
- 生产环境用 `kexvim restart` 或 `node kexvim.js --daemon`
- 推送/SSH 用 HTTPS + token（`~/.config/gitee-release-cli-nodejs/config.json`），
  不用 SSH deploy key（`/tmp/sage_deploy_key` 重启即失，勿依赖）
