# System Prompt Alignment Lessons — 2026-07-28

## 诚实规则必须放在 `DEFAULT_AGENT_IDENTITY`

用户要求"system prompt 和 Hermes 对齐"时，诚实规则必须写死在 `DEFAULT_AGENT_IDENTITY`（`PromptBuilder.ts:32`）。

**AGENTS.md 不够。** AGENTS.md 只作为 project context 注入，优先级低于 identity。

### 对齐层级（从高到低）

| 层级 | 文件 | 出现频率 | 优先级 |
|------|------|---------|--------|
| 系统 prompt 身份 | `PromptBuilder.ts:32` | 每次 LLM 调用 | 最高 |
| Guidance 节 | `PromptDefaults.*_GUIDANCE` | 条件注入 | 中 |
| 项目上下文 | `AGENTS.md` | 可选注入 | 低 |

### 对齐检查流程

1. 先从 `DEFAULT_AGENT_IDENTITY` 开始（身份 + 诚实规则）
2. 再对所有 `PromptDefaults.*_GUIDANCE` 逐项核对
3. 最后才是 `AGENTS.md`

## search_files 是 regex（ripgrep）

`search_files` 底层是 `rg`（ripgrep），默认 regex 模式。搜特殊字符不转义会零结果，但 LLM 不知道这是 regex 问题，会误判为"不存在"。

根因：
- `main()` → rg 把 `()` 当空捕获组
- `import("...")` → rg 把 `("...")` 当捕获组

交叉验证方法：
1. 用 `grep -F`（纯文本模式）
2. 直接 `read_file` 目标文件
3. 检查文件大小：>`wc -l` > 300 行时零结果尤其可疑

## 公开仓不发 skills

`skills/` 目录没有包含在发布版 `kexvim.js` 中。安装脚本只创建 `data/.env` 和 `data/config.yaml`，不下载技能。
