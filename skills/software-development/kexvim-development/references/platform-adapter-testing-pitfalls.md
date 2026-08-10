# 平台适配器测试陷阱（实测踩过，2026-08）

给 kexvim 新增平台适配器（Telegram/Discord/HTTP）时，无真实凭证的全量验证方法见
`kexvim-platform-adapter` 技能。以下是实测踩过的三个陷阱：

## 1. WS 类 adapter 测试勿 await start()

`start()` 内部是 `while(running) { connectAndListen() }`，`connectAndListen` 直到 WS
**断开**才 resolve（QQ/Discord 同构）。测试里 `await adapter.start()` 会永久挂起（timeout 60s 才暴露）。

正确写法：
```ts
adapter.start().catch(e => console.error("[test] start error:", e)); // 不 await
await new Promise(r => setTimeout(r, 500)); // 等连接建立
```

## 2. mock 需可覆盖 apiBase

Discord adapter 测试时，构造函数必须有 `apiBase?: string` 选项（对齐 QQBotAPIAdapter
的设计），才能指向本地 mock server。没有它就只能打真实 API。

```ts
// adapter 构造：this.apiBase = config.apiBase ?? API_BASE;
// 请求时：new URL(`${this.apiBase}${path}`)，按协议选 https/http 模块
```

## 3. 端到端测试的 worker 架构陷阱

kexvim 主线程 fork watchdog/agent/guardian 三个 worker，**gateway 跑在 agent worker 里**；
主线程同时进 REPL。后台跑 `node dist/dev.mjs` 时 stdin 是 EOF → REPL 立即退出 → 连带杀掉
workers（日志表现为 `[agent] exited (0)`，gateway 根本没起来）。

保持 stdin 存活：`tail -f /dev/null | node dist/dev.mjs`

**环境变量管道陷阱**：`VAR=x cmd1 | cmd2` 中 VAR **只作用于 cmd1**（tail），不传给 cmd2
（node）。必须：
```bash
export KEXVIM_CONFIG=/path/to/config
tail -f /dev/null | node dist/dev.mjs
```
踩过：没 export 时它加载了真实 data/config.yaml，**连上了真实 QQ Bot**（日志出现
`适配器 qq 已注册` + `BotAPI WebSocket 已连接` 即中招）。

验证成功的日志信号：
```
[gateway] 适配器 {name} 已注册
[http-adapter] listening on http://127.0.0.1:8642   (HTTP)
```

## 4. mock 长轮询必须加延迟

`getUpdates` 类轮询的 mock 若立即返回，`pollLoop` 会疯狂空转刷内存 → Node heap 1.8GB
OOM（FATAL ERROR: Ineffective mark-compacts）。mock 里加 50ms 延迟模拟长轮询：
```ts
await new Promise(r => setTimeout(r, 50));
```
