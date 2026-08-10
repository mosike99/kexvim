---
name: kexvim-release
description: Kexvim Gitee release 流程 — tag + gitee-release-cli 发版
version: 1.0.0
author: agent
license: MIT
metadata:
  kexvim:
    tags: [kexvim, release, gitee, tag, versioning]
    related_skills: [kexvim-development, kexvim-deployment]
---

# Kexvim Release Process

## 前置条件

- Tag 已打并推送（`git tag vX.Y.Z && git push origin vX.Y.Z`）
- `gitee-release-cli` 已安装（`npm install gitee-release-cli`）

## Token

**Token 会被日重置清掉 config，但实际存在 NAS 上**

路径：`/mnt/nas/agent安装/mosike99.git-token.txt`

文件第 5 行格式：
```
gitee  zk/zk-agent  <token>
```

拿到后存到 gitee-release-cli config：
```bash
cd /tmp && npm install gitee-release-cli --no-save
./node_modules/.bin/gitee-release-config accessToken <token>
```

本地 config 文件（会保留，不会随重置丢失）：
`~/.config/gitee-release-cli-nodejs/config.json`

## 发 Release

### 步骤

```bash
# 1. 先编译
cd <项目根> && npm run build

# 2. 同步到公开仓
cp kexvim.js /tmp/sage-public/kexvim.js
cd /tmp/sage-public
git add kexvim.js
git commit -m "feat: ..."
git push origin main

# 3. 打 tag（两个仓都要）
cd <项目根> && git tag vX.Y.Z && git push origin vX.Y.Z
cd /tmp/sage-public && git tag vX.Y.Z && git push origin vX.Y.Z

# 4. 发 release
npx gitee-release-cli create --upload
```

## 发布说明

保持简洁，列出核心架构变化即可：

```
v1.0.0 — 单进程多线程架构：watchdog + agent + guardian Worker，Pi 风格 TUI + 树导航 + 增量压实，Gateway 可选并行
```

## 同步 checklist

发布版 `kexvim.js` + `kexvim.sh` + `kexvim.bat` + `skills/` 同步到公开仓后，入口脚本首次安装会自动下载 `skills/`（git clone --depth 1）。如需更新 skills，直接在私仓改好，发布时 `cp -r <项目根>/skills /tmp/sage-public/skills`。

## 已知问题

- **Token 被日重置清掉** — `gitee-release-cli` config 文件存在磁盘不会丢，但新会话的 agent 可能不知道 config 在哪。NAS 路径 `/mnt/nas/agent安装/mosike99.git-token.txt` 是后备。
- **"access token does not exist"** — config 被清，去 NAS 取 token 重新设置
- **多仓同步** — 公开仓和私仓都要打 tag
- **"target_commitish is missing"** — 加 `"target_commitish": "main"`
- **"登录失效" (40001)** — token 无效，从 NAS 重新获取

## References

- `references/agent-debugging-lessons.md` — Agent 工具使用教训（search_files 大文件不完整、交叉验证方法）
