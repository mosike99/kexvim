# Release Workflow

## 双仓库架构

| 仓库 | 地址 | 用途 |
|------|------|------|
| 私仓 | `git@gitee.com:moscowzk/kexvim-dev.git` | 日常开发，有 .ts 源码 |
| 公开仓 | `https://gitee.com/moscowzk/kexvim.git` | Release 发布，无 .ts 源码 |

## 构建

```bash
npm run build     # esbuild 直接打包 → kexvim.js (280KB, minified, 单文件)
```

esbuild 参数（直接在 package.json scripts 中调用 esbuild，不用 tsup）:
- 入口: `src/Main.ts`
- 输出: `kexvim.js`（根目录，单文件，没有 dist/ 目录）
- 压缩: `--minify`
- Shebang: `--banner:js='#!/usr/bin/env node'`（全局安装后 `kexvim` 命令可直接运行）
- Format: ESM (`--format=esm`)
- Platform: Node.js (`--platform=node`)
- External: cron, ws, js-yaml, @modelcontextprotocol/*
- `node:` 前缀: 直接用 esbuild（不用 tsup）保留 `node:sqlite` 前缀
- **不产生 chunk 文件** — 单文件输出

## 发布到公开仓

```bash
# 1. 构建
npm run build

# 2. 准备发布目录
rm -rf /tmp/sage-public && mkdir /tmp/sage-public
cd /tmp/sage-public && git init -b main
cp <项目根>/kexvim.js .
cp <项目根>/package.json <项目根>/LICENSE .
cp <项目根>/install.bat <项目根>/install.sh <项目根>/install-macos.command <项目根>/install.ps1 .

# 3. 修复 package.json（只保留 start + bin，清理 workspace/devDeps）
node -e "
const fs=require('fs');
const p=JSON.parse(fs.readFileSync('package.json','utf-8'));
p.name = '@moscowzk/kexvim';
p.bin = { kexvim: 'kexvim.js' };
p.scripts = { start: 'node kexvim.js' };
p.version = '0.1.0';
delete p.private;
delete p.workspaces;
delete p.devDependencies;
delete p.dependencies.tsx;
fs.writeFileSync('package.json', JSON.stringify(p, null, 2));
"

# 4. .gitignore
echo -e 'node_modules/\npackage-lock.json' > .gitignore

# 5. 推送到公开仓
git add -A && git commit -m "kexvim v$(date +%Y.%m.%d)"
git remote add origin git@gitee.com:moscowzk/kexvim.git
git push -u origin main --force

# 6. 版本分支（可选）
git checkout -b v0.1.0 && git push origin v0.1.0
```

## Release 准则

- **没有 zip 文件** — 版本用 git 分支区分
- **没有 node_modules** — 用户 `npm install --omit=dev`
- **没有 package-lock.json** — .gitignore 屏蔽
- **没有 dist/ 目录** — `kexvim.js` 在根目录
- **没有 chunk 文件** — esbuild 打出单文件
- **没有 sqlite shim** — esbuild 保留 `node:sqlite` 前缀，Node.js 22 原生支持
- **没有 .ts 源码**
- **installer 脚本**从公开仓克隆: `git clone --depth 1 https://gitee.com/moscowzk/kexvim.git`
- **运行**: `node kexvim.js`（不需要 tsx）
- **全局安装**: `npm install -g git@gitee.com:moscowzk/kexvim.git` → 命令 `kexvim`
- **许可证**: MIT (`LICENSE`)

## 跨平台 Installer

| 平台 | 文件名 | 方式 |
|------|--------|------|
| Windows | `install.bat` | 双击运行, clone + npm install + 配 API Key + 桌面快捷方式 |
| macOS | `install-macos.command` | 双击运行, clone + npm install + 配 API Key + launchd 服务 |
| Linux | `install.sh` | `bash install.sh`, clone + npm install + 配 API Key + systemd 服务 |

所有 installer 流程：
1. 检查 Node.js (>=18)
2. 检查 Git
3. `git clone --depth 1` 公开仓
4. `npm install --omit=dev`
5. 配置 API Key (`<项目根>/data/.env`)
6. 可选设置系统服务 (systemd/launchd)
7. 可选立即启动

## 热修复

```bash
cd <项目根>
# 改代码 → 重新构建
npm run build
# 更新公开仓
cp kexvim.js /tmp/sage-public/
cd /tmp/sage-public && git add -A && git commit -m "fix: xxx" && git push
```
