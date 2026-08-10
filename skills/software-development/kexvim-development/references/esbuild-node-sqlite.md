# esbuild + `node:sqlite` 编译

## 问题

kexvim 使用 Node.js 22 内置的 `node:sqlite` 模块。esbuild 在 `--platform=node` 模式下会自动解析 Node.js 内置模块并**去掉 `node:` 前缀**，导致编译产物中出现：

```js
import { DatabaseSync } from "sqlite"  // 错误！运行时没有 "sqlite" 包
```

而正确输出应为：

```js
import { DatabaseSync } from "node:sqlite"  // 正确
```

## 尝试过的方案

| 方案 | 结果 | 原因 |
|------|------|------|
| `tsup` + `esbuildOptions.alias` | ❌ | tsup 的 alias 在 built-in 解析之后应用 |
| `tsup` + `esbuildPlugins` (onResolve `"sqlite"`) | ❌ | 同上，tsup 包装层不传递 plugin |
| `platform: "neutral"` + 手动 external Node.js built-ins | ❌ | `node:sqlite` 仍被 esbuild 重写为 `"sqlite"` |
| esbuild 直接调用（不用 tsup）+ external 列表 | ✅ | 单文件，`node:` 前缀保留 |
| 静态 shim (`packages/sqlite-shim/` 重导出) | ⚠️ 能用但臃肿 | 多一个包的维护成本 |

## 最终方案

直接使用 esbuild CLI，不用 tsup 包装：

```json
"build": "esbuild src/Main.ts --bundle --platform=node --format=esm --outfile=kexvim.js --banner:js='#!/usr/bin/env node' --external:cron --external:ws --external:js-yaml --external:@modelcontextprotocol/* --minify"
```

关键点：
- **`platform: "node"`** — 让 esbuild 自动处理所有 Node.js 内置模块的 external（fs、path、crypto 等）
- **不要用 tsup** — tsup 的 `noSplitting: true` 对动态 import 不生效，会产生 chunk 文件；且 tsup 会干扰 `node:` 前缀
- **保留 `node:sqlite` 在外部依赖中** — 不手动 external，esbuild 的 `platform: node` 自动处理

## 验证

编译后检查产物：

```bash
grep 'from"' dist/kexvim.js | grep sqlite
# 应输出: from"node:sqlite"  （NOT from"sqlite"）
```
