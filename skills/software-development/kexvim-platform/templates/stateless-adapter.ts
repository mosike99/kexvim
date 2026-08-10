// ===================================================================
// HTTPAdapter 精简骨架 — 无状态（请求/响应）平台的参考实现
// 复制修改即可得到新的 request/response 式 adapter（HTTP/WS/Webhook）。
// 完整版见 packages/platform/src/HTTPAdapter.ts（含 CORS、鉴权、body 限制）。
// ===================================================================

import * as http from 'node:http';
import type { PlatformAdapter, PlatformMessage, MessageHandler } from './PlatformAdapter';

export interface HTTPAdapterConfig {
  port?: number;    // 默认 8642（对齐 Hermes api_server）
  host?: string;    // 默认 127.0.0.1
  apiKey?: string;  // 可选：X-API-Key / Authorization: Bearer
  settleMs?: number;    // 回复静默去抖窗口，默认 800
  timeoutMs?: number;   // 请求超时，默认 120000
}

interface PendingRequest {
  chunks: string[];
  settleTimer: ReturnType<typeof setTimeout>;
  timeoutTimer: ReturnType<typeof setTimeout>;
  resolve: (t: string) => void;
  reject: (e: Error) => void;
  settled: boolean;
}

export class HTTPAdapter implements PlatformAdapter {
  readonly name = "api_server";   // 注意：notify 循环按此名跳过无外呼平台
  private handler: MessageHandler | null = null;
  private server: http.Server | null = null;
  private running = false;
  private pending = new Map<string, PendingRequest>();
  constructor(private cfg: HTTPAdapterConfig = {}) {}

  setMessageHandler(h: MessageHandler): void { this.handler = h; }
  isConnected(): boolean { return this.running; }
  async sendText(userId: string, text: string): Promise<void> {
    // 无外呼通道：仅记录日志（接口兼容）
    console.error(`[${this.name}] sendText ignored (request/response only): ${text.slice(0, 100)}`);
  }

  async start(): Promise<void> {
    if (this.running) return;
    this.running = true;
    this.server = http.createServer((req, res) => {
      this.handle(req, res).catch(e => this.writeJson(res, 500, { ok: false, error: String(e?.message ?? e) }));
    });
    await new Promise<void>((resolve, reject) => {
      const onErr = (e: Error) => reject(e);
      this.server!.once("error", onErr);
      this.server!.listen(this.cfg.port ?? 8642, this.cfg.host ?? "127.0.0.1", () => {
        this.server!.removeListener("error", onErr);
        console.error(`[${this.name}] listening on http://${this.cfg.host ?? "127.0.0.1"}:${this.cfg.port ?? 8642}`);
        resolve();
      });
    });
  }

  async stop(): Promise<void> {
    if (!this.running) return;
    this.running = false;
    for (const p of this.pending.values()) {
      clearTimeout(p.settleTimer); clearTimeout(p.timeoutTimer);
      if (!p.settled) { p.settled = true; p.reject(new Error("server shutting down")); }
    }
    this.pending.clear();
    const s = this.server; this.server = null;
    if (s) await new Promise<void>(r => { s.close(() => r()); s.closeAllConnections?.(); });
  }

  private async handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const url = (req.url || "").split("?")[0];
    if (req.method === "GET" && url === "/health") { this.writeJson(res, 200, { ok: true, platform: this.name }); return; }
    if (req.method !== "POST" || url !== "/chat") { this.writeJson(res, 404, { ok: false, error: "use POST /chat or GET /health" }); return; }

    // 鉴权（可选）...
    // 读 body → JSON.parse → { user_id?, text }（text 缺失 → 400）

    const userId = (parsed.user_id ?? "anonymous").toString().trim() || "anonymous";
    const messageId = `http-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

    // ── 核心模式：sendReply 静默去抖合并（busy ack + 最终回复 → 单个响应）──
    const reply = await new Promise<string>((resolve, reject) => {
      const pending: PendingRequest = {
        chunks: [], settleTimer: null as any, timeoutTimer: null as any, resolve, reject, settled: false,
      };
      pending.timeoutTimer = setTimeout(() => {
        if (pending.settled) return;
        pending.settled = true; this.pending.delete(messageId);
        if (pending.chunks.length > 0) resolve(pending.chunks.join("\n"));   // 超时兜底：有内容返回内容
        else reject(new Error("request timed out"));
      }, this.cfg.timeoutMs ?? 120_000);
      this.pending.set(messageId, pending);

      const pm: PlatformMessage = {
        userId: `api_server:dm:${userId}`,
        text: parsed.text.toString().trim(),
        messageId,
        source: { platform: "api_server", chatId: userId, chatType: "dm", userId },
        sendReply: async (t: string) => {
          if (!pending.settled && t) {
            pending.chunks.push(t);
            clearTimeout(pending.settleTimer);
            pending.settleTimer = setTimeout(() => {
              if (pending.settled) return;
              pending.settled = true; this.pending.delete(messageId);
              resolve(pending.chunks.join("\n"));
            }, this.cfg.settleMs ?? 800);
          }
        },
      };
      this.handler?.(pm).catch(e => { if (!pending.settled) { pending.settled = true; this.pending.delete(messageId); reject(e); } });
    });

    this.writeJson(res, 200, { reply });
  }

  private writeJson(res: http.ServerResponse, status: number, data: unknown): void {
    if (res.headersSent) return;
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify(data));
  }
}
