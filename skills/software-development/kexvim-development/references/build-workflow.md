# Build Workflow 说明（2026-07）

## 架构

```
源文件 (.ts, 无后缀 import)
    │
    ├── tsc --noEmit → 类型检查（零输出）
    │
    └── esbuild --bundle --platform=node --format=esm
              │
       dist/dev.mjs（开发）
       或 kexvim.js（发布，--minify）
              │
              └── node dist/dev.mjs
```

## 为什么不用 tsc 编译

tsc 输出 ESM import 路径与源码一致。如果源码用 extensionless import，输出的 `.js` 也是 extensionless，Node.js ESM 解析失败（报 ERR_MODULE_NOT_FOUND）。之前用过 `.js` 后缀方案（tsc 在编译时把 `.js` 解析为 `.ts`），但要改 256 处 import，维护成本高。

esbuild 自动处理扩展名解析，source code 可以保持 extensionless。

## npm 包 import 的特殊处理

npm 子路径 import（如 `@modelcontextprotocol/sdk/client/stdio`）必须保留 `.js` 后缀，因为：

1. 该包的 `package.json` 没有 `exports` 字段
2. esbuild 对 bare specifier 的子路径解析不会自动尝试添加扩展名
3. 去掉 `.js` 会报 `Could not resolve`

本地 import（如 `./Foo`、`../packages/llm/src/ProviderRegistry`）无后缀，esbuild 自动尝试 `.ts`→`.tsx`→`.js`→`.jsx`。

## 性能

| 操作 | 耗时 |
|------|------|
| tsc --noEmit（完整项目） | ~3s |
| esbuild 开发编译 | ~141ms |
| 合计 npm start | ~3.1s |

## 相关文件

- `AGENTS.md` — import 约定
- `package.json` — scripts 定义
- `tsconfig.json` — `noEmit: true`
