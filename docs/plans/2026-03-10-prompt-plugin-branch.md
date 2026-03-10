# prompt-plugin Branch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 从 `multiuser` 切出 `prompt-plugin` 分支，创建完全独立的 klogin 部署脚本，与 cda-demo（multiuser）零冲突。

**Architecture:** 代码层面完全复制 multiuser，仅 setup 脚本中所有资源标识符替换为 pp 命名空间。两实例可同时在同一 klogin 机器运行互不干扰。

**Tech Stack:** bash, Docker, klogin CLI, git

---

## 隔离资源对照

| 配置项 | multiuser（cda-demo） | prompt-plugin |
|--------|----------------------|---------------|
| App 端口 | 3005 | 3007 |
| 容器名 | `openhands-app-multi` | `openhands-app-pp` |
| Agent 前缀 | `oh-multi-` | `oh-pp-` |
| Persistence | `~/.openhands-multi` | `~/.openhands-pp` |
| 镜像名 | `openhands-multi:latest` | `openhands-pp:latest` |
| 源码目录 | `/tmp/openhands-multiuser` | `/tmp/openhands-pp` |
| Ingress | `openhands-multi` | `openhands-pp` |
| 本地隧道 | 3006 → 3005 | 3008 → 3007 |
| REPO_BRANCH | `multiuser` | `prompt-plugin` |

---

### Task 1: 创建 prompt-plugin 分支

**Files:** 无（纯 git 操作）

**Step 1: 确认当前在 multiuser 分支**

```bash
cd /Users/gloryc/projs/OpenHands
git branch --show-current
```
Expected: `multiuser`

**Step 2: 创建 prompt-plugin 分支**

```bash
git checkout -b prompt-plugin
```
Expected: `Switched to a new branch 'prompt-plugin'`

---

### Task 2: 创建 setup-openhands-klogin-pp.sh

**Files:**
- Create: `setup-openhands-klogin-pp.sh`

**Step 1: 从 multi 脚本复制并替换所有标识符**

文件内容（完整替换规则）：

| 替换前 | 替换后 |
|--------|--------|
| `[multiuser]` | `[prompt-plugin]` |
| `OH_MULTI_REPO_URL` | `OH_PP_REPO_URL` |
| `OH_MULTI_REPO_BRANCH` | `OH_PP_REPO_BRANCH` |
| `OH_MULTI_JWT_SECRET` | `OH_PP_JWT_SECRET` |
| `REPO_BRANCH:-multiuser` | `REPO_BRANCH:-prompt-plugin` |
| `sudo ufw allow 3005` | `sudo ufw allow 3007` |
| `~/.openhands-multi` | `~/.openhands-pp` |
| `oh-multi-` (docker filter & 代码) | `oh-pp-` |
| `openhands-app-multi` | `openhands-app-pp` |
| `/tmp/openhands-multiuser` | `/tmp/openhands-pp` |
| `origin/multiuser` (git reset) | `origin/prompt-plugin` |（仅限 REMOTE here-doc 内的引用）
| `openhands-multi:latest` | `openhands-pp:latest` |
| `Dockerfile.multiuser` | `Dockerfile.multiuser`（不变，共用同一 Dockerfile）|
| `multiuser-\$(git rev-parse` | `pp-\$(git rev-parse` |
| `SANDBOX_CONTAINER_PREFIX=oh-multi-` | `SANDBOX_CONTAINER_PREFIX=oh-pp-` |
| `OH_WEB_URL=http://127.0.0.1:3005` | `OH_WEB_URL=http://127.0.0.1:3007` |
| `--pid=host` | 保留不变 |
| `BASE = 'http://127.0.0.1:3005'` | `BASE = 'http://127.0.0.1:3007'` |
| `name = f'oh-multi-{cid_nodash}'` | `name = f'oh-pp-{cid_nodash}'` |
| `openhands-app-multi` (logs wait) | `openhands-app-pp` |
| `openhands-multi` (ingress name) | `openhands-pp` |
| `--port 3005` (ingress) | `--port 3007` |
| `-L 3006.*$INSTANCE_ID` (pkill) | `-L 3008.*$INSTANCE_ID` |
| `-L 3006:127.0.0.1:3005` (tunnel) | `-L 3008:127.0.0.1:3007` |
| `localhost:3006` (所有验证) | `localhost:3008` |
| `openhands-multi.svc.` (输出 URL) | `openhands-pp.svc.` |
| `OH_MULTI_JWT_SECRET` (末尾输出) | `OH_PP_JWT_SECRET` |

**Step 2: 赋执行权限**

```bash
chmod +x setup-openhands-klogin-pp.sh
```

**Step 3: 快速验证关键标识符无遗漏**

```bash
grep -n "openhands-multi\|oh-multi-\|3005\|3006\|openhands-multiuser\|REPO_BRANCH:-multiuser\|OH_MULTI_" setup-openhands-klogin-pp.sh
```
Expected: **无输出**（所有 multi 标识符均已替换）

---

### Task 3: 提交并推送

**Step 1: 提交**

```bash
git add setup-openhands-klogin-pp.sh docs/plans/
git commit -m "feat(prompt-plugin): add isolated klogin deploy script (port 3007, container openhands-app-pp)"
```

**Step 2: 推送到 origin**

```bash
git push -u origin prompt-plugin
```

---

## 部署验证（在 klogin 机器上）

脚本创建完成后，在本地运行：

```bash
bash setup-openhands-klogin-pp.sh
```

验证两实例同时运行互不干扰：
```bash
# cda-demo 还在运行
curl -s http://localhost:3006/api/options/models | python3 -m json.tool | head -5

# prompt-plugin 独立运行
curl -s http://localhost:3008/api/options/models | python3 -m json.tool | head -5
```

访问地址：
```
https://openhands-pp.svc.<instance-id>.klogin-user.mlplatform.apple.com
```
