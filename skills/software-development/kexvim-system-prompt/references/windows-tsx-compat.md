# Windows tsx 兼容性修复记录

## 问题

`npx tsx src/Main.ts` 在 Windows 上报错：
```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module '.../packages/llm/src/ProviderRegistry'
```

根因：Node.js ESM resolver 在 Windows 上不自动尝试 `.ts` 扩展名，又因为 `tsc` 产物（.js/.d.ts）与 `.ts` 并存，RSE 加载了不匹配的 `.js` 文件。

## 修复步骤

### 1. 删除 tsc 编译产物（2026-07-28）

删除 `src/` 和 `packages/*/src/` 下全部 `.js`/`.d.ts` 文件（约 155 个文件）。

```bash
find src packages -type f \( -name "*.js" -o -name "*.d.ts" \) ! -path "*/node_modules/*" -delete
rm -f packages/*/tsconfig.tsbuildinfo
```

### 2. 设置 noEmit

根 `tsconfig.json`：

```diff
- "declaration": true,
+ "noEmit": true,
```

各 `packages/*/tsconfig.json`：

```diff
- "declaration": true,
- "declarationMap": true,
- "sourceMap": true,
- "composite": true,
+ "noEmit": true,
+ "declaration": false,
+ "declarationMap": false,
+ "sourceMap": false,
```

### 3. 全部 import 加 .ts 后缀

68 个文件，约 255 处 import 需要加 `.ts`：

```diff
- import { ProviderRegistry } from "../packages/llm/src/ProviderRegistry";
+ import { ProviderRegistry } from "../packages/llm/src/ProviderRegistry.ts";
```

### 4. 允许 .ts import 扩展名

所有 tsconfig.json 加：

```json
"allowImportingTsExtensions": true,
```

### 5. Node 22 strip-only 模式冲突

```
SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript enum is not supported in strip-only mode
```

Node 22 内置的 strip-only TS 支持会拦截 `.ts` 文件，但它不支持 `enum`。

修复：`package.json` scripts 中加 `--no-experimental-strip-types`：

```json
"start": "npx --no-experimental-strip-types tsx src/Main.ts"
```
