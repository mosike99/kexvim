---
name: kexvim-skill-authoring
description: "Author kexvim SKILL.md: frontmatter, validation."
version: 1.0.0
author: Hermes Agent (adapted to kexvim)
license: MIT
platforms: [linux, macos, windows]
metadata:
  kexvim:
    tags: [skills, authoring, kexvim, conventions, skill-md]
    related_skills: [plan, requesting-code-review]
---

# Authoring kexvim Skills

## Overview

SKILL.md 文件可以存在于两个位置：

1. **用户级（可写）：** `<project_root>/data/skills/<name>/SKILL.md` — 个人技能，`skill_manage(action='create')` 写入此目录（分类可选：`data/skills/<category>/<name>/SKILL.md`）。
2. **共享级（公共技能，随包分发）：** `<project_root>/skills/<category>/<name>/SKILL.md` — 随 kexvim 分发的公共技能（公开仓 `skills/` 目录）。用 `write_file` + `git add` 提交。`skill_manage(action='create')` 不写入此树。

## When to Use

- 用户要求新增一个技能（"存个技能"、"这个流程存下来"）
- 提交一个可复用的工作流，应随 kexvim 分发
- 编辑 `<project_root>/skills/` 下的公共技能（小改动用 `patch`，重写用 `write_file`；`skill_manage(action='patch')` 也可用于公共技能，但 `create` 不行）

## Required Frontmatter

来源：`src/tool/SkillManageTool.ts::_validateFrontmatter`。硬性要求：

- 以 `---` 开头（文件第一字节，无前导空行）
- 以 `\n---\n` 闭合 frontmatter
- 可解析为 YAML mapping（kexvim 用简单 key-value 正则解析，不依赖 YAML 库）
- `name` 字段必须存在
- `description` 字段必须存在，**≤ 60 字符**（`MAX_DESCRIPTION_LENGTH = 60`，比 Hermes 的 1024 严格得多！）
- frontmatter 之后必须有非空正文

标准形状：

```yaml
---
name: my-skill-name               # 小写+连字符，≤64 字符（MAX_NAME_LENGTH）
description: Use when <trigger>. <one-line behavior>.   # ≤60 字符！
version: 1.0.0
author: kexvim
license: MIT
metadata:
  kexvim:
    tags: [short, descriptive, tags]
    related_skills: [other-skill]
---
```

`version` / `author` / `license` / `metadata` 非强制，但所有现有技能都有。

## Size Limits

- Description: **≤ 60 chars（强制）** — 移植 Hermes 技能时必查，超长会创建失败
- Full SKILL.md: ≤ 100,000 chars（`MAX_CONTENT_CHARS`）
- 目标 8-15k chars；超过 20k 拆到 `references/*.md` 并引用

## Writing Quality Principles

技能存在的意义是让 agent 的行为更可预测。可预测 ≠ 每次输出一样，而是 agent 可靠地遵循同一套有用纪律。

1. **为流程可预测性优化。** 问：加载这个技能后什么行为会变？某行不能改变行为就删掉。
2. **选择合适的上下文加载量。** description 每个回合都进上下文，保持聚焦触发类和独特行为，细节放正文或 references。
3. **信息分层。** 常用步骤放 SKILL.md，分支/大块参考放 `references/`、`templates/`、`scripts/`，需要时才指向。
4. **步骤以完成标准结尾。** 每步说明 agent 如何知道做完了。
5. **规则就近放置。** 定义、坑、示例、验证放在一起。
6. **用强引导词。** 用模型已知的紧凑概念（"tight loop"、"root cause"）代替冗长解释。
7. **去重和无操作内容。** 每句自问：这句话 vs 默认行为，改变行为吗？不改变就删。
8. **警惕过早完成。** 如果 agent 容易跳过某步，先强化该步的完成标准。

常见质量失败：
- **过早完成** — 工作没真正做完就继续
- **重复** — 同一条规则多处出现且漂移
- **沉积** — 过时行残留，因为加比删安全
- **臃肿** — 太多常驻内容；分支内容应放引用
- **无操作散文** — 不加技能也会遵守的泛泛建议

## Peer-Matched Structure

```
# <Title>

## Overview
一两段：是什么、为什么。

## When to Use
- 触发条件列表
- "Don't use for:" 反触发

## <技能特有的主题章节>
- 快速参考表
- 精确命令的代码块
- kexvim 特有配方

## Common Pitfalls
编号列表：错误与修复。

## Verification Checklist
- [ ] 操作后验证清单
```

## Directory Placement

```
skills/<category>/<skill-name>/SKILL.md
```

kexvim 公共技能现有分类（`ls skills/` 确认）：`devops`、`mcp`、`software-development`、`research`、`media`、`creative`、`productivity`。

选最接近的现有分类，不要随意新建顶层分类。

## Workflow

1. **看同类技能：**
   ```bash
   ls skills/<category>/
   ```
   读 2-3 个同类 SKILL.md 对齐风格。
2. **查校验约束**：`src/tool/SkillManageTool.ts` 的 `_validateFrontmatter`。
3. **起草**：`write_file` 到 `skills/<category>/<name>/SKILL.md`。
4. **本地验证：**
   ```python
   import re, pathlib
   content = pathlib.Path("skills/<category>/<name>/SKILL.md").read_text()
   assert content.startswith("---")
   m = re.search(r'\n---\s*\n', content[3:])
   fm = content[3:m.start()+3]
   name = re.search(r'^name:\s*(.+)$', fm, re.M)
   desc = re.search(r'^description:\s*(.+)$', fm, re.M)
   assert name and desc
   assert len(desc.group(1).strip()) <= 60   # kexvim 硬限制！
   assert len(content) <= 100_000
   print("frontmatter OK")
   ```
5. **Git add + commit**（公共技能）。
6. **注意：** 当前 session 的技能加载器有缓存——`skill_view` / `skills_list` 看不到新技能，直到新 session。这是预期行为，不是 bug。

## Cross-Referencing Other Skills

`metadata.kexvim.related_skills` 加载时合并两个树（`skills/` 共享 + `data/skills/` 用户）。引用只在共享树里存在的技能，否则其他克隆者解析不了。

## Editing Existing Skills

- **小修（typo、加坑、收紧触发）：** `skill_manage(action='patch', name=..., old_string=..., new_string=...)` 对公共技能也有效。
- **重写：** `write_file` 整个 SKILL.md。`skill_manage(action='edit')` 也行但要提供完整新内容。
- **加辅助文件：** `write_file` 到 `skills/<category>/<name>/references/<file>.md`、`templates/<file>`、`scripts/<file>`。
- **必提交** — 公共技能是源码不是运行时状态。

## Common Pitfalls

1. **用 `skill_manage(action='create')` 建公共技能。** 它写入 `data/skills/`（用户级），不是共享树。共享树用 `write_file`。
2. **`---` 前有前导空白。** 校验查 `content.startsWith("---")`，任何前导空行/BOM 都失败。
3. **description 超过 60 字符。** kexvim 的硬限制（Hermes 是 1024）。移植 Hermes 技能时**必查**——这是最常见的失败原因。
4. **忘了 author/license/metadata 块。** 非强制但所有同类都有。
5. **写了个重复的技能。** 创建前 `ls skills/<category>/` 看 2-3 个同类，优先扩展现有技能。
6. **期望当前 session 看到新技能。** 不会。技能加载器在 session 启动时初始化，新 session 或直接 `skill_view` 精确路径验证。
7. **让技能积累沉积。** 技能应越改越短或越尖锐。加规则时删掉它取代的旧措辞。
8. **写无操作散文。** "小心"、"全面"、"用最佳实践"很少改变模型行为。换成可检查的完成标准。
9. **链接不存在的技能。** `related_skills: [some-user-local-skill]` 你自己能用，其他克隆者用不了。只链共享树内的。

## Verification Checklist

- [ ] 文件在 `skills/<category>/<name>/SKILL.md`（不是 `data/skills/`）
- [ ] frontmatter 从字节 0 开始 `---`，以 `\n---\n` 闭合
- [ ] `name`、`description` 存在，且 **description ≤ 60 字符**
- [ ] 名称 ≤ 64 字符，小写+连字符
- [ ] 总文件 ≤ 100,000 字符（目标 8-15k）
- [ ] 结构：`# Title` → `## Overview` → `## When to Use` → 正文 → `## Common Pitfalls` → `## Verification Checklist`
- [ ] 每步有可检查的完成标准
- [ ] 大块/分支参考放在链接文件里渐进披露
- [ ] 无操作散文和重复规则已删
- [ ] `related_skills` 引用可解析（共享树内）
- [ ] `git add skills/<category>/<name>/ && git commit` 已执行
