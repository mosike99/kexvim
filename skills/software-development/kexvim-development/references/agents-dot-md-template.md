# AGENTS.md Template (Pi-derived Best Practices)

基于 Pi 项目（78.6k ⭐）162 行 AGENTS.md 提炼的通用模板。
适合放在项目根目录，指导 AI agent 的开发行为。

## 结构

```
## Conversational Style      ← 回答风格、语气
## Code Quality              ← 代码质量规则、禁止模式
## Commands                  ← 修改代码后必须执行的命令
## Dependency Security       ← npm 依赖管理规则
## Git                       ← 多 session 安全提交规则
## Changelog                 ← 更新日志规则
## Releasing                 ← 发版流程
## User Override             ← 用户指令覆盖规则（最后一条）
```

## 关键规则

### Conversational Style
- 回答简洁，先答问题再改代码
- 收到分析先说同意/不同意，再说改什么
- 不加废话和表情符号

### Code Quality
- 大范围修改前先完整读文件，不依赖搜片段
- 禁止动态 import（`await import()`、`import("pkg").Type`）
- 依赖过时导致的类型错误 → 升级 dep，不降级代码
- 删除有意为之的代码前先问用户

### Git (Multi-session Safety)
- 只 stage 本次改动的文件：`git add <path1> <path2>`
- 禁止 `git add -A` / `git add .` / `git stash` / `git reset --hard`
- Rebase 只解决自己改过的文件，冲突在未改文件则中止问用户
- 不 force push

### User Override
用户指令与 AGENTS.md 规则冲突时，**先问用户确认**再执行。

## 与 Sage AGENTS.md 的差异

Sage 的 AGENTS.md 额外包含：
- 跨平台规范（SystemAdapter、npm 脚本、cron npm 包）
- 自动验证（AutoValidate：write_file/patch 后 tsc 编译检查）
- 架构参考（目录结构、启动流程）
- 中英双语 JSDoc 注释规则
- 代码风格（4 空格、封装类、PascalCase 文件名）

这些是 Sage 项目特有的，Pi 模板不覆盖。
