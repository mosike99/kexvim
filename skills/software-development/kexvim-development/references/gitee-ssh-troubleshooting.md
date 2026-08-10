# Gitee SSH 故障排查

当 Sage 的 git 操作（push/pull/fetch）失败时，按此流程排查。

## 快速诊断脚本

```bash
# 1. 确认 remote 是 SSH 地址
cd D:\kexvim-dev && git remote -v
# 期望: git@gitee.com:moscowzk/kexvim-dev.git

# 2. 测试 SSH 连通性
ssh -T git@gitee.com
# 成功: "Hi zk(@moscowzk)! You've successfully authenticated..."
# 失败: "Permission denied (publickey)."

# 3. 检查 SSH agent 加载了哪些 key
ssh-add -l
# "The agent has no identities" = 没有 key 加载

# 4. 检查 deploy key 是否存在
ls -la /tmp/sage_deploy_key

# 5. 比对关键指纹
ssh-keygen -lf /tmp/sage_deploy_key
# 看标题和指纹是否匹配 Gitee 上显示的公钥

# 6. 检查 SSH config 是否有 gitee.com 的配置
cat ~/.ssh/config
```

## 典型故障场景

### 场景一：SSH deny 但 deploy key 存在

**症状**: `ssh -T git@gitee.com` → `Permission denied (publickey)`

**常见原因**:
- deploy key (`/tmp/sage_deploy_key`) 没被 SSH 自动加载
- `~/.ssh/config` 不存在或没有 gitee.com 条目
- 默认 `~/.ssh/id_ed25519` 的公钥没加到 Gitee 上

**修复**: 创建 `~/.ssh/config`:

```
Host gitee.com
  IdentityFile /tmp/sage_deploy_key
  IdentitiesOnly yes
```

验证（无需 ssh-add）:

```bash
ssh-add -D 2>/dev/null       # 清空 agent，确认走 config
ssh -T git@gitee.com         # 应该输出 Hi zk(@moscowzk)!
```

### 场景二：指纹对不上

**症状**: Gitee 上显示的公钥指纹和本地私钥的指纹不同。

**解读**: 这是正常的——Gitee 上那把公钥对应的私钥在其他机器上（如 NAS zkme）。本机用的是 deploy key。检查 `/tmp/sage_deploy_key` 是否匹配 Gitee 上的指纹。

### 场景三：git push 提示 Permission denied

**修复**:

```bash
# 临时用 deploy key 推送
export GIT_SSH_COMMAND="ssh -i /tmp/sage_deploy_key -o StrictHostKeyChecking=no"
git push origin master

# 永久修复：加上面的 SSH config
```

## 关键文件

| 文件 | 用途 |
|------|------|
| `/tmp/sage_deploy_key` | Gitee deploy key 私钥（标题 "zk-agent"，指纹 `SHA256:fgUEZjQf92...`） |
| `~/.ssh/config` | SSH 配置，指定 gitee.com 用 deploy key |
| `~/.ssh/id_ed25519` | 本机默认 SSH key（公钥一般没加到 Gitee） |

## 验证

```bash
cd D:\kexvim-dev && echo "test" > /tmp/test_push && git add /tmp/test_push && git commit -m "test ssh" && git push origin main && git reset --soft HEAD~1 && git push origin main -f
```
