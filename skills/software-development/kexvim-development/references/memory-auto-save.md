# Memory Auto-Save (不要等用户提示)

## 问题

用户说"MEMORY.md不是自动存的吗？还要我提示？" — 用户期望 agent 自动保存信息。

## 根因

1. MEMORY_GUIDANCE 太被动（"Save durable facts using the memory tool" 而非 "USE IT IMMEDIATELY"）
2. MemoryTool schema 缺 `target` 参数，LLM 不知道能写 user profile
3. `type` 参数无默认值，LLM 少传时走 error 分支中断任务

## 解决方案

三管齐下：

### 1. MEMORY_GUIDANCE 强化

见 `PromptBuilder.ts` 第 176-191 行。改为命令式：

```
When you learn something about the user — their name, preferences, habits,
environment details, project conventions — USE THE MEMORY TOOL IMMEDIATELY
to save it. Do NOT wait to be asked.
```

添加中文引导和具体示例。

### 2. MemoryTool schema 补全

`MemoryTool.ts` `parameters.properties` 增加：

```typescript
target: {
  type: "string",
  enum: ["memory", "user"],
  description: "Write target: 'memory' for notes about environment/projects, 'user' for user profile/preferences (default: memory, only for write)",
},
```

### 3. type 默认值

```typescript
const action = String(args.type || "read");
```

## 验证

```bash
cat <项目根>/data/memories/USER.md     # 应有用户偏好
cat <项目根>/data/memories/MEMORY.md   # 应有项目/环境信息
```
