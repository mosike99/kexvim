# Kexvim — 部署在你设备上的多专业 AI 助手

Kexvim 是一个运行在你本地设备上的 AI Agent 框架：既能像智能助手一样聊天问答，也能自动完成代码、文件、终端、搜索、定时任务等复杂工作。基于 Node.js/TypeScript 构建，单进程多线程架构，开箱即用。

## 特性

- **多平台接入**：QQ 机器人、Web UI 聊天面板、终端交互，一处运行多端可用
- **多模型支持**：DeepSeek 等主流 LLM（OpenAI 兼容协议），流式对话 + 工具调用 + 视觉分析
- **工具系统**：30+ 内置工具——文件读写、精准编辑、终端命令、网页搜索/抓取、代码执行、图像生成、图片分析等
- **技能系统**：200+ 可插拔技能（渐进披露、按需检索加载），覆盖开发、运维、文档、研究等领域
- **长期记忆**：事实记忆 + 用户画像持久化，跨会话记得你
- **会话管理**：SQLite 持久化，历史会话随时切换/恢复
- **定时任务**：内置 cron 调度（shell 命令 / agent 自动执行两种模式）
- **守护进程**：开机自启、崩溃自愈、`kexvim restart` 一键重启（主进程 + Web 一并重启）
- **跨平台**：Windows / Linux / macOS

## 环境要求

- Node.js **22+**（使用内置 `node:sqlite`，无需安装数据库）
- Windows / Linux / macOS

## 一键安装

### Windows

下载 [kexvim.bat](https://gitee.com/moscowzk/kexvim/raw/main/kexvim.bat?download=1)，双击运行。

首次运行自动：下载核心文件 → 安装依赖 → 引导配置 API Key。

### Linux / macOS

```bash
curl -fsSL https://gitee.com/moscowzk/kexvim/raw/main/kexvim.sh -o kexvim.sh && chmod +x kexvim.sh
./kexvim.sh
```

安装完成后，终端输入 `kexvim` 即可使用。

## 快速上手

1. **初始化**：`kexvim init` —— 配置 API Key（DeepSeek 等）
2. **启动**：`kexvim restart` —— 拉起主程序（daemon）与 Web UI
3. **聊天**：浏览器打开 `http://localhost:8788`，或通过已配置的 QQ 机器人直接对话

## 命令行

| 命令 | 说明 |
|------|------|
| `kexvim init` | 首次安装初始化（API Key + 配置 + PATH） |
| `kexvim restart` | 重启主程序（daemon + web 一并重启） |
| `kexvim stop` | 停止主程序（daemon + web） |
| `kexvim status` | 查看运行状态 / 自启配置 / 重启循环防护 |
| `kexvim sessions` | 列出所有历史会话 |
| `kexvim session <前8位ID>` | 切换/恢复历史会话 |
| `kexvim install` / `uninstall` | 安装 / 移除开机自启 |
| `kexvim clear-loop` | 解除重启循环防护 |
| `kexvim help` | 查看帮助 |

## 配置

配置位于安装目录 `data/` 下：

- **`data/.env`** — 敏感信息：`DEEPSEEK_API_KEY=sk-xxx`
- **`data/config.yaml`** — LLM provider、Agent 行为、会话重置策略、平台适配器（QQ）等

常用环境变量（均可覆盖默认值）：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `KEXVIM_PROVIDER` | `deepseek` | 默认 LLM provider |
| `KEXVIM_MODEL` | `deepseek-v4-flash` | 默认模型 |
| `KEXVIM_WEB_PORT` | `8788` | Web UI 端口 |

## 架构

- **单进程多线程**：Worker Threads 并行处理，零 IPC 开销
- **事件驱动**：AgentRuntime 主循环 + 工具执行 + 消息推送解耦
- **适配器模式**：平台适配层（QQ / Web / 终端）与 LLM Provider 抽象，扩展只需新增适配器
- **技能/记忆**：技能库渐进披露，记忆分层持久化

## 开源协议

[MIT](LICENSE)
