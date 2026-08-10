# Prompt Alignment Findings (2026-07-27)

## Root Cause of Sage Hallucinations — CORRECTED FINAL VERSION

Sage (DeepSeek V4 Flash) was hallucinating because **EXECUTION_DISCIPLINE_GUIDANCE**
was never injected for DeepSeek. However, after injecting it, DeepSeek **stopped
outputting text** (stalled after the first character). This matches Hermes'
deliberate choice: Hermes' `system_prompt.py` line 291 only applies
`OPENAI_MODEL_EXECUTION_GUIDANCE` to GPT/Codex/Grok, NOT DeepSeek.

### Final Resolution

Three-iteration fix:
1. **`2fb3902`**: Added DeepSeek to EXECUTION_DISCIPLINE_GUIDANCE model list
   → Result: DeepSeek stalls at first word
2. **`155d735`**: Reverted back to Hermes' original list (GPT/Codex/Grok only)
   → Result: back to original behavior
3. **`f86097e`**: Created `DEEPSEEK_VERIFICATION_GUIDANCE` - lightweight version
   with ONLY the anti-hallucination parts:
   - `do NOT guess or hallucinate`
   - `label assumptions explicitly`
   - `verify with tools before finalizing`
   → Result: DeepSeek keeps speaking AND stops fabricating

### Why EXECUTION_DISCIPLINE broke DeepSeek

The `<mandatory_tool_use>` section says "NEVER answer these from memory —
ALWAYS use a tool" including "Git history → use terminal". DeepSeek took this
as an absolute: when asked about git changes, it started writing a response,
then realized "I'm answering from memory about git, which is forbidden" →
aborted the response mid-word to call tools instead. GPT/Grok interpret the
same text as "use tools when in doubt, not every sentence."

### What was missing before

Before any fix, DeepSeek was getting TOOL_USE_ENFORCEMENT_GUIDANCE (through
`_shouldInjectEnforcement` which includes 'deepseek' at line 688) but NOT
the `<missing_context>` / `<verification>` sections from EXECUTION_DISCIPLINE.
Those sections contain the actual anti-hallucination rules. The final fix
extracts JUST those rules into a separate lightweight constant.

## Hierarchy of Alignment Impact

| Layer | Impact | Effort |
|-------|--------|--------|
| System prompt composition | High (prevents hallucinations) | Low (one-line model list change) |
| Tool schema precision | High (prevents malformed calls) | Medium |
| Message history hygiene | Medium (prevents confusion) | Low |
| Tool error feedback | Medium (prevents silent failure) | Low |
| Background review | Low (post-turn, non-blocking) | Medium |

## Prompt Alignment Checklist for Sage

When checking if Sage is aligned with Hermes, verify:

1. **Guidance constants** — Does Sage have the same MEMORY_GUIDANCE / SKILLS_GUIDANCE / SESSION_SEARCH_GUIDANCE / TASK_COMPLETION_GUIDANCE / TOOL_USE_ENFORCEMENT_GUIDANCE / EXECUTION_DISCIPLINE_GUIDANCE?
2. **Model gating** — Are the model match lists identical between `_shouldInjectEnforcement()` and `build()`?
3. **Tool gating** — Is each guidance injected only when the relevant tool exists in `valid_tool_names`?
4. **Build options** — Are all relevant flags passed from AgentRuntime to PromptBuilder.build()?
5. **No fake tool messages** — Hermes never injects synthetic `role: "tool"` messages mid-loop.
6. **Config over runtime detection** — Use boolean config flags (like `markdownSupport`), not regex guessing.
7. **i18n parameter names** — Template placeholder names must match code's params object keys exactly.
