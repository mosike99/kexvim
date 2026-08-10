# 多线程优化记录（2026-07-28，kex 实现）

## 改动汇总

| 文件 | 改动 | 目的 |
|------|------|------|
| `Main.ts` | `import { Worker } from "worker_threads"` 改为 `await import("node:worker_threads")` 动态导入 | 避免顶层 `require` 报错 |
| `Watchdog.ts` | 数组 `WorkerInfo[]` → `Map<role, WorkerInfo>` | 按 role 索引，重启时不依赖数组下标，避免索引漂移 |
| `AgentRuntime.ts` | 新增 `_chatQueue` Promise chain | Gateway 模式下并发消息不破坏 mutable state（如 `_iters_since_skill`、`_last_tool_call`） |
| `ToolExecutor.ts` | 新增 `maxConcurrent = 5`，分批 `Promise.all` | 防止并行工具调用数量失控 |
| `StoreWorker.ts` | shutdown 前 `setImmediate` + `appendMessage` 加 `.catch(() => {})` | 确保 WAL flush 完成 + 防 unhandled rejection |

## AgentRuntime `_chatQueue` 模式

```typescript
private _chatQueue: Promise<void> = Promise.resolve();

async chat(request, ops): Promise<ChatResult> {
  const run = () => this.runChatInternal(request, ops);
  const prev = this._chatQueue;
  this._chatQueue = prev.then(run, run); // 第二个 run 作为 rejection handler
  return this._chatQueue;
}
```

要点：
- `prev.then(run, run)` — 即使前一个 chat 失败（rejection），后一个也要正常执行（用 run 替代 catch）
- 保证 `_chat_queue` 同一时间只有一个请求在修改 agent state
- 对使用者透明——`chat()` 返回的 Promise 解析到当前调用的结果

## Watchdog Map 模式

```typescript
private workers: Map<string, WorkerInfo> = new Map();

private createWorker(role: string): WorkerInfo {
  const worker = new Worker(entryPoint, { workerData: { role } });
  const info = { worker, role };
  this.workers.set(role, info);
  return info;
}

private restartWorker(role: string): void {
  this.workers.get(role)?.worker.terminate();
  this.workers.delete(role);
  this.createWorker(role);
}
```

优势：重启不需要知道数组下标，按 role 直接定位。

## DeepSeek 工具流优化提示

`ToolExecutor.ts` 的 `maxConcurrent = 5` 与 DeepSeek 模型配合良好——DeepSeek 经常在一次响应中发出大量并行工具调用（6-12 个），分批执行避免后端超时或限流。
