# QQ 平台 interim 过程消息 — 正确行为与实现（2026-08-01 定稿，08-02 修订）

> 本文推翻 2026-07-29 的旧结论（"QQ 上 interim 必须禁用、bot 静默只发最终回复"）。
> 旧结论写进了 kexvim-hermes-alignment 的 §8 和映射表，属**已证伪内容**——以本文为准。
> **2026-08-02 修订**：去重实现从「final 前缀裁剪」（32405ee）改为 **Hermes 对齐的
> `_delivered_interim_texts` 集合查重**（e42316c）——§3 已重写，final 前缀裁剪已废弃。

## zk 在 QQ 上的真实行为（源码实测，用户确认）

| 事实 | zk 源码位置 | 含义 |
|---|---|---|
| LLM 调用恒为流式 | conversation_loop.py:1291 | 无 consumer 仍走流式 health check |
| `_fire_stream_delta` 只在**有 consumer** 时累积文本 | run_agent.py 附近 | QQ 无 stream consumer → 不累积 → `_current_streamed_assistant_text` 为空 |
| 工具边界 `_emit_interim_assistant_message` 检查"已流式" | run_agent.py:3949-3958 | 比较累积文本 → QQ 上不相等 → `already_streamed=False` |
| 网关 `_interim_assistant_cb` | gateway/run.py:17650 | `already_streamed=False` 且 `_status_adapter` 存在 → **真实 send 完整句子** |

**结论：zk 在 QQ 上 = 「工具边界发完整句子 interim + 最终回复」。interim 不是被抑制的。**

## kexvim 正确实现（commit 6a3096d + 32405ee + e42316c 定稿）

### 1. 句子切分 `_flushInterimSentences(statusCallback)`

- 中英文句末标点 `。！？!?` 直接切
- 英文 `.`：后随空格/换行/tab/闭合符（`)]}）】"'`）才切；前字符字母数字且后随字母数字 → 小数/缩写（`3.14`、`e.g.`、`v1.2`）**不切**
- flush 发"从 buffer 开头到**最后一个**完整标点"的整块（可能含多个句子，一条消息）
- **半截尾部保留**在 `_streamBuffer`（等待下一轮续接）
- 无完整句子 → 全部保留不发

### 2. 跨轮 buffer 清理（kex 初版 6a3096d 漏掉，32405ee 补）

`agentLoop` 的 `while (budget.consume())` **每轮开头** `this._streamBuffer = ""`。
否则上一轮 tool_use 残留的半截尾会与新一轮 LLM 输出拼接成垃圾（"旧半截尾+新句子"一起发出）。

### 3. interim 去重 — Hermes 对齐的集合查重（2026-08-02 定稿，e42316c）

**Hermes 源码定案**（run_agent.py:4904-5014、conversation_loop.py:675）：
- 去重靠 `_delivered_interim_texts` **集合**：发送前 `_interim_text_was_delivered()`（`replace(/\s+/g," ")` normalize 后**精确匹配** in set）、发送后 `_record_delivered_interim_text()`、每轮 turn 开头重置
- **绝不做 final 前缀裁剪**——Hermes 没有这个机制。final 的完整性由 `already_streamed`（流式是否已交付）决定，与 interim 无关
- Hermes 注释原话：*fails safe to a benign duplicate, never loses text* —— 宁可良性重复，绝不丢文本

**kexvim 对齐实现**：
- 字段 `_deliveredInterimTexts: Set<string>`（turn 开头重置 `new Set()`）
- `_flushInterimSentences` 发送前查重（normalize 后精确匹配）、发送后 `add()`
- final 发送**不裁剪**——`extractContent` 原样返回（extractContent 取最后一条 assistant 消息，工具轮 interim 与 final 天然不同消息）

**❌ 已废弃（不要实现）**：`_interimSentThisTurn` 字符串 + final 前缀裁剪（32405ee）——
自创 hack，Hermes 没有；裁剪有丢文本风险。2026-08-02 用户追问"对齐 hermes 了吗"后对照
源码推翻。

### 4. 发送链路

```
AgentRuntime.onStream(tool_use) → _flushInterimSentences(opts.statusCallback)
  → GatewayLauncher sendProgress (msg.sendReply) → QQ 消息
final: runtime.chat() 返回值 → Gateway → msg.sendReply
```

### 5. 流式截断恢复（finish_reason=length，e230bda + 3a43e87 + 028ad6b）

**先治本：推理模型 max_tokens 预算（028ad6b）**——kexvim 每轮硬编码 `maxOutputTokens=4096`，
推理模型（deepseek-v4-flash 等，`ErrorClassifier.isReasoningModel`）的 **max_tokens 包含
reasoning token**：长思考挤爆 content 预算 → 正文几 token 就触顶 → `finish_reason=length`
→ 随机轮次中断（"为什么中断两次"根因）。Hermes 对照：`run_agent.py` `max_tokens: int = None`
默认不传，API 用默认值 → 从不截断。kexvim 对齐：`_reasoningAwareMaxTokens` getter
（推理 16384 / 非推理 4096），三处统一（主 req、finalizer、压缩重试 req）。

截断重试（`finishReason === "length"` 分支，对齐 Hermes conversation_loop.py:2755-3076）：
- **纯文本截断**：截断片段累积进 `truncatedParts` → 追加 continuation prompt 重试 ≤4 次；
  **重试成功必须拼接** `truncatedParts.join("") + continuation`（对齐 Hermes L5483-5484
  `"".join(truncated_response_parts) + final_response`）——否则用户只收到后半段
- **tool_call 截断**：参数可能不完整 → 提升 max_tokens（×2^n 封顶 32768）重试，**不拼接**（参数重试是全新生成）
- **两条重试路径重试前都清 `_streamBuffer`**——防截断残尾拼入新输出
- **4 次仍截断**：回滚 continuation 消息 + 返回拼接的 partial；tool_call 4 次仍 length → `response.toolCalls = null` 拒绝执行不完整参数

## 测试要点

- 切分/跨轮/去重单测用**独立脚本复刻实现逻辑**（不需要 import AgentRuntime，避免启动依赖）
- 关键用例：中英混合完整句、小数不误切、`e.g.` 不误切、无完整句全保留、跨轮无污染、
  同一文本不重复发（集合查重）、不同文本都发、空白差异去重（normalize）、截断拼接、4 次全截断 partial、tool_call 不拼接

## 易错点

- `_streamBuffer` 同时被 `_applyActiveTurnRedirect` 使用（redirect 时作为"已流出可见文本"）——清空/截断逻辑要两者兼顾
- welcome 拼接（新用户首次会话）发生在最终内容提取**之后**，不受去重影响
- plannedContent 路径（planner 模式）不走流式，无 interim，无需去重
- 若 bot 出现"过程消息和最终回复内容重复"，检查集合查重是否被绕过（如走 plannedContent/welcome 路径），**而非回退到"禁用 interim"**
- **对齐 Hermes 必须逐行读源码**——kex 的实现"看起来对齐"不等于真对齐：interim 去重（集合 vs 裁剪）和截断恢复（拼接 vs 覆盖）两次都是对照源码才发现偏差
- **先 `git fetch` 再断言他人声称的提交/改动**——kex 的 commit 曾因未 fetch 被误判为幻觉；fetch 用 HTTPS+token（SSH deploy key 在 /tmp 已被重启清空）
