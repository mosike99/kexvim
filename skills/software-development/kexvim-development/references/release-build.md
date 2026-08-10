# Sage Release Build

## 构建命令

```bash
npm run build       # tsup 打包 → dist/Main.js（~600KB 单文件）
npm run release     # build + 打 zip → .release/sage-v{version}.zip（~11MB）
npm run start       # 开发模式：npx tsx src/Main.ts
npm run start:release  # 生产模式：node dist/Main.js
```

## Release 包结构

```
sage-v0.1.0.zip (11MB)
├── dist/Main.js              ← tsup 单文件 bundle
├── node_modules/              ← production 依赖（npm install --omit=dev）
├── install.bat                ← Windows 双击安装
├── install-macos.command      ← macOS 双击安装
├── install.sh / install.ps1   ← 命令行安装
└── package.json               ← start: "node dist/Main.js"
```

**不含** `.ts` 源码。

## tsup 配置 (`tsup.config.ts`)

```typescript
import { defineConfig } from "tsup";
export default defineConfig({
  entry: ["src/Main.ts"],
  format: "esm",
  platform: "node",
  noSplitting: true,
  clean: true,
  external: ["cron", "ws", "js-yaml", "@modelcontextprotocol/*"],
});
```

## sqlite 兼容性

Node.js 22 内置 `node:sqlite` 模块（`DatabaseSync`），但源码中 `import { DatabaseSync } from "node:sqlite"` 经 esbuild 编译后变成 `import { DatabaseSync } from "sqlite"`。

解决方案——`/tmp/sqlite-shim/` shim 包：

```json
// /tmp/sqlite-shim/package.json
{ "name": "sqlite", "main": "index.mjs", "exports": { ".": "./index.mjs" } }
```

```js
// /tmp/sqlite-shim/index.mjs
export * from "node:sqlite";
export { default } from "node:sqlite";
```

作为本地依赖安装：`npm install /tmp/sqlite-shim --save`。
Release 脚本中会复制真实文件（非 symlink）到 `node_modules/sqlite/`。

## 安装器脚本

| 文件 | 平台 | 说明 |
|------|------|------|
| `install.bat` | Windows | 双击运行，自包含（不下载外部脚本） |
| `install-macos.command` | macOS | 双击在终端打开，自包含 |
| `install.sh` | Linux/macOS | `bash <(curl -s ...)` |
| `install.ps1` | Windows | `irm ... \| iex` 一行命令 |

所有安装器为自包含脚本，不依赖 Gitee raw 下载（Gitee 防盗链 403）。

## TUI + QQ Bot 同进程

`Main.ts` 启动 Gateway 时同时注册 QQ Bot 适配器和 TUI 适配器（`TuiAdapter`）。
- 有 TTY 时：终端显示 `sage>` 提示符，可同时从 QQ 和终端输入
- 无 TTY 时（systemd 后台）：TUI 自动跳过
- `packages/tui/` 独立包，仅依赖 Node.js 内置 `readline`
