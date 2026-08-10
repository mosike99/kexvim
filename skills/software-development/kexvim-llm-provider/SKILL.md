---
name: kexvim-llm-provider
description: "kexvim LLM provider 层：注册表、适配器、无 key 测试"
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, llm, provider, adapter, registry, no-key-test]
    related_skills: [kexvim-system-prompt, kexvim-session-runtime]
---

# kexvim LLM Provider 层

kexvim 的 LLM provider 注册在 `packages/llm/src/ProviderRegistry.ts`（类 ProviderRegistry）。所有 provider 默认走 OpenAI 兼容协议（`OpenAIChatAdapter`），Anthropic 协议走 `AnthropicAdapter`。

## 架构

- `ProviderEntry` = `{ adapter, baseUrl, envKey?, envKeyAlt?, vendorOnly?, options? }`
- 内置表在 `registerBuiltins()`；用户自定义 provider 通过 `registry.register()` 覆盖（优先级更高）
- `resolve(provider, model?)` 优先级：**用户注册 > `custom:` 前缀 > 内置表**
- `vendorOnly: true`（如 ollama）要求 resolve 时必须显式传 model 名

### API key 解析优先级（`resolveApiKey`）

1. `registry.setApiKey()` 显式设置
2. `entry.envKey` 环境变量
3. `entry.envKeyAlt` 备选环境变量
4. 自动推导 `<PROVIDER>_API_KEY`（大写、`-`→`_`）
5. 兜底 `OPENAI_API_KEY`（仅 OpenAI 兼容协议）

## Hermes 对照移植（加新 provider 的标准流程）

Hermes 的 provider profile 在 `~/.hermes/hermes-agent/venv/lib/python3.12/site-packages/plugins/model-providers/<name>/__init__.py`，结构是 `ProviderProfile(name=, aliases=, env_vars=, base_url=)`：

```bash
grep -E "name=|base_url=|env_vars=" <name>/__init__.py
```

对照表（2026-08-01 已移植，kexvim 29 个内置）：

| kexvim key | baseUrl | envKey / envKeyAlt |
|---|---|---|
| deepseek | api.deepseek.com | DEEPSEEK_API_KEY |
| openai | api.openai.com/v1 | OPENAI_API_KEY |
| anthropic | api.anthropic.com | ANTHROPIC_API_KEY / ANTHROPIC_TOKEN |
| openrouter | openrouter.ai/api/v1 | OPENROUTER_API_KEY |
| xai | api.x.ai/v1 | XAI_API_KEY |
| groq | api.groq.com/openai/v1 | GROQ_API_KEY |
| together | api.together.xyz/v1 | TOGETHER_API_KEY |
| mistral | api.mistral.ai/v1 | MISTRAL_API_KEY |
| nvidia | integrate.api.nvidia.com/v1 | NVIDIA_API_KEY |
| fireworks | api.fireworks.ai/inference/v1 | FIREWORKS_API_KEY |
| huggingface | api-inference.huggingface.co/v1 | HF_TOKEN |
| cerebras | api.cerebras.ai/v1 | CEREBRAS_API_KEY |
| ollama (vendorOnly) | localhost:11434/v1 | — |
| alibaba | dashscope-intl.aliyuncs.com/compatible-mode/v1 | DASHSCOPE_API_KEY |
| qwen | dashscope.aliyuncs.com/compatible-mode/v1 | DASHSCOPE_API_KEY |
| gemini | generativelanguage.googleapis.com/v1beta/openai | GOOGLE_API_KEY / GEMINI_API_KEY |
| minimax | api.minimax.io/v1 | MINIMAX_API_KEY |
| minimax-cn | api.minimaxi.com/v1 | MINIMAX_CN_API_KEY |
| stepfun | api.stepfun.ai/v1 | STEPFUN_API_KEY |
| deepinfra | api.deepinfra.com/v1/openai | DEEPINFRA_API_KEY |
| novita | api.novita.ai/openai/v1 | NOVITA_API_KEY |
| upstage | api.upstage.ai/v1 | UPSTAGE_API_KEY |
| nous | inference-api.nousresearch.com/v1 | NOUS_API_KEY |
| kimi | api.moonshot.cn/v1 | KIMI_API_KEY / MOONSHOT_API_KEY |
| zai | api.z.ai/api/paas/v4 | GLM_API_KEY / ZAI_API_KEY |
| bigmodel | open.bigmodel.cn/api/paas/v4 | GLM_API_KEY / BIGMODEL_API_KEY |
| xiaomi | api.xiaomimimo.com/v1 | XIAOMI_API_KEY |
| arcee | api.arcee.ai/api/v1 | ARCEEAI_API_KEY |
| gmi | api.gmi-serving.com/v1 | GMI_API_KEY |

移植要点：
- **大多数 provider 是 OpenAI 兼容**（chat/completions 端点），直接 `adapter: OpenAIChatAdapter` 即可，无需新 adapter 类
- 某些 provider（如 minimax）Hermes 用 Anthropic 端点，但 kexvim 用其 OpenAI 兼容端点（api.minimax.io/v1）统一走 OpenAIChatAdapter
- gemini 用 Google 官方 OpenAI 兼容端点 `/v1beta/openai`（免额外 SDK）
- env key 用 Hermes 的 `env_vars` 第一个值；别名/国内版拆成两个 key（minimax/minimax-cn、zai/bigmodel）

## 配置用法

```yaml
llm:
  default_provider: kimi
  default_model: kimi-k2
  providers:
    kimi:
      adapter: openai          # 缺省即可，内置表自动匹配
      api_key: '${KIMI_API_KEY}'
```

换 provider 只需改 `default_provider` + 设对应环境变量，无需动代码。

**全量参考配置（2026-08-01 已补全）**：`data-example/config.yaml` 含全部 29 个
provider（国内/国际/本地分组 + 推荐默认模型）+ fallback 回退链示例 + 8 个平台
适配器参考段；`data-example/.env` 含全部 provider 的 API key 环境变量占位（XXX）。
新环境照抄填 key 即可。

**参考配置验证**：解析 `data-example/config.yaml` 用 `js-yaml`（kexvim 依赖它，
不是 `yaml` 包）→ 断言 config 里每个 provider key 都在 `registry.list()` 中 →
断言平台 adapter 数与 `ADAPTER_FACTORIES` 一致（防拼写错误漂移）。

## 测试（无 key 全量验证）

写 `tmp/smoke-providers.ts`，esbuild 打包运行（见 kexvim-platform-adapter 的 smoke 模式）：

- **数量与清单**：`registry.list()` 长度 + 每个期望 key 存在
- **大小写不敏感**：`registry.has("DeepSeek") && registry.has("GEMINI")`
- **无 key resolve 抛错**：每个新增 provider `resolve(p, "test-model")` 必须 throw（验证 envKey 映射生效）
- **setApiKey 后 resolve 成功** + 断言 adapter 的 **config 字段**（`adapter.config.baseUrl / .model / .apiKey`，不在顶层！）
- **env 别名读取**：先 `delete process.env.X`，再设 alt env，resolve 后断言 `config.apiKey`；注意：**显式 setApiKey 优先级高于 env**，测 env 别名要用未 setApiKey 的 provider
- **vendorOnly**：ollama resolve 显式传 model 名

## DeepSeek V4-Flash 正式版核查（2026-08-02）

官方 7/31 发布 V4-Flash 正式版后核查结论：**kexvim 无需任何改动**（模型名/端点/参数全对）。核查方法（可复用于任何"官方发布新版本，我要改吗"的场景）：

1. **官方模型列表实测**：`GET https://api.deepseek.com/models`（`Authorization: Bearer <key>`）→ 返回 `deepseek-v4-flash` + `deepseek-v4-pro`。config.yaml 里的 `deepseek-v4-flash` 正是官方正式版 ID。
2. **推理模型确认**：`POST /chat/completions`（max_tokens=500，问"1+1=?"）→ 响应含 `reasoning_content`、`usage.completion_tokens_details.reasoning_tokens=33/35` → **V4-Flash 仍是推理模型，max_tokens 包含 reasoning token**（16384 预算的修复依然必要，见 kexvim-session-runtime）。
3. **参数名兼容**：`max_tokens` 和 `max_completion_tokens` 都接受（两个都返回 200）——OpenAIChatAdapter 用 `max_tokens` 无问题。
4. **Hermes 对照**：`model_normalize.py` 确认 `deepseek-v4-pro`/`deepseek-v4-flash` 是 first-class V 系列 ID，与 kexvim 一致。

**API key 不进命令行**：查官方 API 用临时 node 脚本读 `data/.env`（`node -e` 里 fs.readFileSync），不要 `grep .env` 把 key 塞进 shell 命令（会被安全层拦截）。

## 语音工具（STT，2026-08）

`src/tool/SpeechToTextTool.ts`（`speech_to_text`）— 语音转文字，复用 provider key/端点：

- provider 自动检测优先级：**local faster-whisper（免费无 key）→ groq → openai → deepinfra**
- API 路径统一走 OpenAI 兼容 `POST {base}/audio/transcriptions`，curl `-F file=@path -F model=...` 上传
  （与 TTS 的 execSync 模式一致）
- 文件校验：不存在 / 空文件 / >25MB 明确报错
- provider 显式覆盖 `setProvider()` + `setApiBase(provider, url)`（测试注入 mock）
- 注册：AgentRuntime 里 `skipTools` 可关（对齐 TextToSpeechTool）

**STT 测试陷阱（execSync 阻塞事件循环）**：被测工具用 `execSync` 调 curl 时，同进程的
HTTP mock server 无法响应 —— execSync 同步阻塞主线程事件循环，mock 的 `req.on('end')`
永不执行，curl 挂起至超时（exit 124 卡死）。mock 必须 `spawn` 独立子进程，等它就绪信号
（如 stdout 打 `MOCK_UP`）再调被测代码；mock 切模式（ok→error）也 kill 旧进程 + 重新 spawn。
curl 无法被拦截，测试只能靠 `setApiBase` 指向本地 mock 端口。

## 验证命令

```bash
cd /home/ubuntu/<项目根>
npx tsc --noEmit
npm run build:dev
```

## 参考

- 代码：`packages/llm/src/ProviderRegistry.ts`、`OpenAIChatAdapter.ts`、`AnthropicAdapter.ts`
- Hermes 对照：`~/.hermes/hermes-agent/venv/lib/python3.12/site-packages/plugins/model-providers/`（34 个 profile，kexvim 已移植 29 个；未移植：copilot/copilot-acp/bedrock/vertex/azure-foundry/gemini 原生端点等 SDK 型）
- 本次移植 16 个新 provider 的提交即按上述流程完成（2026-08-01）
