---
name: kexvim-data-directory-rule
description: "Kexvim data 路径定位规则：findProjectRoot 回溯 package.json"
version: 1.1.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, data-dir, findProjectRoot, path-rule, project-root, deployment, cross-platform]
    related_skills: [kexvim-development, kexvim-session, kexvim-skill-authoring]
---

# Kexvim Data 目录部署规则

kexvim 的数据路径定位**铁律**：从运行路径（cwd，含其本身）逐级向上回溯，
取第一个 `package.json` 所在目录为**项目根**，数据目录 = `<project_root>/data`。
禁止使用 release 路径（`<项目根>/data`）或任何硬编码 data 路径。

**跨平台**：规则与平台无关（Windows / Linux / macOS 一致），实现必须用
`node:path` 的 `path.join`/`path.resolve`（自动处理 `\` 与 `/` 分隔符），
禁止手写分隔符或硬编码具体路径。

## 核心规则（2026-08 定案，无例外）

> **data 路径 = 从 cwd 向上回溯第一个 package.json 所在目录 + `/data`**

- 适用于 dev 版（`D:\kexvim-dev` → `D:\kexvim-dev\data`）与 release 版
  （Linux/macOS 安装目录 → `<安装目录>/data`，Windows 同理），三平台同一套规则
- 找不到 package.json 时：`SessionSearchTool` 退回 `cwd/data`；Config 层退回
  `<项目根>/data`（非项目环境，仅兜底）
- 开发排查时**绝不**去 `<项目根>` 找数据——那里没有，也不该有

## 代码落点（改路径相关代码前先看这里）

| 位置 | 职责 |
|------|------|
| `src/Config.ts:238 findProjectRoot(cwd?)` | 核心实现：`while` 向上找 package.json，到文件系统根返回 null（`path.dirname` 跨平台） |
| `src/Config.ts:269 userDataDir` | 默认 = `findProjectRoot() → <root>/data`；可被 `KEXVIM_USER_DATA_DIR` 覆盖 |
| `src/Config.ts:284 findPath()` | 配置路径：`KEXVIM_CONFIG` 环境变量 > `<root>/data/config.yaml` |
| `src/tool/SessionSearchTool.ts:18 resolveDataDir()` | session_search 用同一规则，找不到退回 `cwd/data` |
| `src/GatewayLauncher.ts:94 resolveLastUserPath()` | `.last_user` 文件 = `<root>/data/.last_user` |
| `src/Bootstrap.ts:176-181` | `skillsDir` = `<data>/skills`；`sharedSkillsDir` = `<root>/skills` |

## 技能双目录结构（同一条规则派生）

| 目录 | 定位 | 可写性 | 用途 |
|------|------|--------|------|
| `skills/`（项目根） | `findProjectRoot() + /skills` | 只读（写 = write_file + git add） | 公共技能，随 kexvim 分发 |
| `data/skills/`（项目根 data 下） | `userDataDir + /skills` | 可写（skill_manage create 写入） | 用户/自动保存技能，gitignore |

其他数据文件（按同一规则）：`data/kexvim.db`（会话库）、`data/config.yaml`（配置）、
`data/.env`（密钥）、`data/memories/`（记忆）、`data/cron-jobs.json`（定时任务）、`data/.last_user`（最近用户）。

## 排查清单：路径报错时

1. 确认项目根：`ls package.json` / `dir package.json`（找离 cwd 最近的 package.json 所在目录）
2. 确认 data 目录存在：`ls <root>/data/`（会话库 `kexvim.db`、`config.yaml` 应在此）
3. 若报 `<项目根>/data` 找不到 → 那是 release 路径残留 bug，查 `findProjectRoot` 调用链，
   不要手动去创建 `<项目根>/data`
4. 环境变量可覆盖默认值：`KEXVIM_USER_DATA_DIR`、`KEXVIM_SKILLS_DIR`、`KEXVIM_CONFIG`
   （仅调试用，生产别依赖）

## Common Pitfalls

1. **硬编码 release 路径**：`<项目根>/data` 曾硬编码在 SessionSearchTool（2026-07-31 实测 bug），
   新写工具一律用 `KexvimConfigLoader.findProjectRoot()`
2. **手写路径分隔符**：`root + "/data"` 在 Windows 可用但 Linux 下字符串拼接出问题的是反方向——
   用 `path.join(root, "data")`，三平台自动正确。Windows 别写 `\` 字面量，Linux/macOS 别写 `/` 前缀拼接
3. **从文件路径反推根目录**：AutoValidate 的 `AutoValidator.findProjectRoot(filePath)` 是
   从被检查文件向上找 package.json（变体，语义相同），不是从 cwd
4. **cwd 决定根**：`findProjectRoot()` 依赖进程 cwd——daemon 模式、cron 触发、systemd service、
   launchctl、Windows 服务、IDE 调试启动时 cwd 不同，根也不同。要稳定就显式传 cwd 或先 `process.chdir()`
5. **别在技能正文写死 data 路径**：公共技能（skills/）里写 `<项目根>/data` 是历史遗留
   （native-mcp/gif-search/kexvim-skill-authoring 都中招过），一律写"项目根/data"语义

## Verification Checklist

- [ ] 新工具定位数据用 `KexvimConfigLoader.findProjectRoot()` + `path.join`，无硬编码路径、无手写分隔符
- [ ] dev 版数据在 `<dev_root>/data`，不是 `<项目根>/data`
- [ ] 公共技能正文不出现 `<项目根>/data`（保留"历史记录"除外）
- [ ] 环境变量覆盖只在调试场景使用
- [ ] 新增路径逻辑在 Windows 与 Linux/macOS 下用 `path.join` 验证过
