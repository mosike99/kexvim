---
name: kexvim-architecture
description: Kexvim 单进程多线程架构 — Worker Threads 模式，零 IPC，平级线程
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, architecture, worker-threads, single-process]
    related_skills: [kexvim-development, kexvim-session]
---

# Kexvim Architecture

## 核心原则

- **单文件**: 所有代码编译到 `kexvim.js`，一个文件部署
- **多线程平级**: Worker Threads，无主次之分，无 IPC
- **零通信**: 线程之间不交换消息，各自独立运行
- **窗口关闭保底**: SIGTERM → `spawn detached --daemon` → 原进程退出

## 线程角色

| 线程 | 职责 | 状态 |
|------|------|------|
| `watchdog` | 检测 `.stop_watchdog`(3s 轮询) + SIGTERM daemonize | ✅ 已实现 |
| `agent` | 配置加载 → LLM → MCP → Gateway(QQ Bot + TUI) + GuardianAgent | ✅ 已实现 |
| `guardian` | 独立 Worker，已初始化 config/LLM/GuardianAgent，等待 platform 接入 | 🔧 框架就绪 |
| `console`（主线程） | spawn Workers，转发 stdout/stderr，优雅关闭 | ✅ 已实现 |

## 启动流程

```
node kexvim.js
  ├── 主线程: spawn 4 Workers，转发 stdout/stderr，监听 SIGTERM
  │   ├── Worker「watchdog」
  │   ├── Worker「agent」
  │   ├── Worker「guardian」
  │   └── Worker「console」
  └── return（主线程保持控制台存活）
```

**daemon 模式**: `node kexvim.js --daemon`
- 主线程 spawn Workers 后 `w.unref()` 直接退出
- Workers 在后台隐藏运行，无控制台

## 关键代码位置

- 入口分发: `Main.ts` → `static async main()` → `isMainThread` 判断
- watchdog worker: `role === "watchdog"` 分支
- agent worker: `role === "agent"` → fall through 到现有 main() 逻辑
- guardian worker: `role === "guardian"` → 占位 `await new Promise(() => {})`
- Daemonize: `spawn(process.execPath, [process.argv[1], "--daemon"], { detached: true, windowsHide: true }).unref()`

## 停止看门狗

```bash
touch <项目根>/.stop_watchdog
```

## 构建

```bash
npm run build  # esbuild → kexvim.js (单文件, ~304KB)
```

## 入口脚本

| 脚本 | 作用 |
|------|------|
| `kexvim.bat` | Windows 双击入口，自动装 Node.js 便携版 + 下载 kexvim.js → `node watchdog.js` |
| `kexvim.sh` | Linux/macOS 入口 → `node watchdog.js` |
| `watchdog.js` | 旧版独立看门狗进程（已弃用，保留文件） |
