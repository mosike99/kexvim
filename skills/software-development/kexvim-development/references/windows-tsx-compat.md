# Windows Node 22 TypeScript 兼容性

## 原始问题

`npx tsx src/Main.ts` 在 Windows 上反复报错，经历了三个阶段：

### 阶段 1: ERR_MODULE_NOT_FOUND（无扩展名）

```
Cannot find module 'D:\kexvim-dev\packages\llm\src\ProviderRegistry'
```

**根因**: `tsx` 在 Windows 上的 ESM loader 钩子有时不触发，不自动添加 `.ts` 扩展名。Linux/macOS 正常。

**修复**: 全仓库所有相对 import 加 `.ts` 后缀。不仅跨 package，同目录的也要。

### 阶段 1.5: 遗漏的单引号 import

首次替换只处理了 `from "..."`，漏掉了 `from '...'`（如 `src/memory/MemoryManager.ts` 的 `from './MemoryProvider'`）和 `.js` 后缀的本地 import（`src/agents/*.ts` 和 `src/mcp/*.ts` 用的是 `from './Foo.js'`）。

**修复**: 扫两轮——第一轮双引号，第二轮单引号 + `.js` 后缀。然后统一全仓为单引号。

建议直接 `grep -rn "from '"` 和 `grep -rn 'from "'` 双面验证。

### 阶段 2: ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX（enum）

```
TypeScript enum is not supported in strip-only mode
```

**根因**: Node 22.22+ 内置了实验性 strip-only TypeScript 支持，但它只做类型擦除，不处理 `enum` 这类真正的 TS 语法。Node 内置处理器抢在 `tsx` 之前拦截了 `.ts` 文件。

**尝试过的解法**:
- `--no-experimental-strip-types` — `npx` 在 Windows 上不传递 flag
- `node --import tsx --no-experimental-strip-types` — 但 `tsx` 需安装到本地 `node_modules`

**最终修复**: 把所有 `enum` 替换成 const 对象：
```typescript
// 改前
export enum Status { Active = 'active', Inactive = 'inactive' }
// 改后
export const Status = { Active: 'active', Inactive: 'inactive' } as const;
export type Status = (typeof Status)[keyof typeof Status];
```

Codebase 中 3 处 enum 受影响：
- `src/agents/Types.ts` — `SubAgentStatus`
- `src/inference/ErrorClassifier.ts` — `FailoverReason`（20 个成员，含详细 JSDoc）
- `src/mcp/Types.ts` — `MCPServerState`

### 阶段 3: 不再需要 tsx

enum 全部改为 const 对象 + import 全加 `.ts` 后缀后，**直接 `node src/Main.ts` 即可运行**。Node 22+ 的 strip-only 模式能正确处理所有语法。

**最终 `package.json` 的 start 脚本：**
```json
"start": "node src/Main.ts"
```

## 最终结论

| 组件 | 状态 |
|------|------|
| `tsx` | 不再需要 |
| `enum` | 禁止使用，改 const 对象 |
| import 扩展名 | 必须 `.ts`，全仓库统一 |
| import 引号风格 | 单引号 `from '...'`（用户偏好） |
| 编译产物 `.js`/`.d.ts` | 删除，`noEmit: true` |
| `allowImportingTsExtensions` | 需要启用 |
| 启动方式 | `node src/Main.ts`（Windows） / `npx tsx src/Main.ts`（Linux） |

### 阶段 4: ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX（构造器参数属性）

```
SyntaxError: TypeScript parameter property is not supported in strip-only mode
```

**根因**: Node 22 strip-only 不支持 `public readonly x: T` 写在构造器参数里。

**修复**: 所有构造器参数属性改为显式类属性 + `this.x = x`：

```typescript
// 改前
constructor(public readonly reason: FailoverReason, public readonly statusCode?: number) {}

// 改后
public readonly reason: FailoverReason;
public readonly statusCode?: number;
constructor(reason: FailoverReason, statusCode?: number) {
  this.reason = reason;
  this.statusCode = statusCode;
}
```

Codebase 中 3 处受影响：
- `src/inference/ErrorClassifier.ts` — `ClassifiedError`（10 个参数属性）
- `src/memory/Types.ts` — `MemoryError`（1 个参数属性）
- `src/inference/BackgroundReviewer.ts` — `BackgroundReviewer`（1 个 `private signal` 参数属性）
