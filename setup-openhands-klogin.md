# OpenHands on klogin 部署教程

> 全程不需要克隆任何代码，只需要 klogin 账号和 Docker。

> **注意**：本文档在各分支共享。具体端口、容器名、ingress 名等值因分支而异，
> 统一以占位符标注（如 `{APP_PORT}`），实际值见对应分支的 setup 脚本。
>
> | 分支 | 脚本 | `{APP_PORT}` | `{CONTAINER}` | `{AGENT_PREFIX}` | `{INGRESS_NAME}` |
> |------|------|-------------|---------------|-----------------|-----------------|
> | klogin-deploy | `setup-openhands-klogin.sh` | 3000 | openhands-app | oh-agent-server | openhands |
> | bridge-mode | `setup-openhands-klogin-bridge.sh` | 3002 | openhands-app-bridge | oh-bridge | openhands-bridge |
> | tab-display | `setup-openhands-klogin-tab.sh` | 3003 | openhands-app-tab | oh-tab | openhands-tab |

## 一键部署

```bash
bash setup-openhands-klogin-{variant}.sh
```

脚本会自动完成所有步骤：启动 OpenHands、打全部补丁、建立 SSH 隧道、验证连通性。

---

## 架构概述

```
浏览器 → klogin ingress (剥离 WS Upgrade) → openhands-app (Python, port {APP_PORT})
                                                  ├── /api/*                  → V0/V1 API
                                                  ├── /agent-server-proxy/*   → 反向代理到 agent-server
                                                  ├── /api/proxy/*            → SSE/WS 事件路由
                                                  └── /api/sandbox-port/{port}/* → VSCode/App tab 反代
                                                          ↓
                                              agent-server (Go binary, port 8000)
                                                  ├── port 8001: VSCode 编辑器
                                                  ├── port 8011: App Worker 1
                                                  └── port 8012: App Worker 2
                                                          ↓
                                              sandbox 容器 (tmux session)
                                                          ↓
                                    /workspace/project/{conv_id}/  ← 每会话隔离
```

## 补丁清单

脚本自动应用以下补丁（全部在容器 writable layer，`docker restart` 保留，`docker rm -f` 后需重跑脚本）：

> **Patch sentinel 最佳实践**：每个 patch 的"already applied"检查必须用该 patch 注入的**唯一 sentinel 字符串**，而不是可能在文件别处出现的通用字符串。False-positive 会导致 patch 静默跳过但实际未生效（例：`patch_bridge_fixes.py` Fix 3 原来用 `'host.docker.internal' in src` 会命中第 1515 行无关代码，需改为注入的注释行作 sentinel）。

| 文件 | 修改目标 | 功能 |
|------|----------|------|
| `patch_sandbox_infra.py` | `docker_sandbox_service.py` | per-session sandbox 隔离（每会话独立 oh-tab-* 容器）；bridge 模式网络修复（extra_hosts、webhook port、MCP URL）；exposed_urls 重写（VSCODE/WORKER → `/api/sandbox-port/{port}`） |
| `patch_agent_comms.py` | `app.py` + `middleware.py` | `/api/proxy/events/{id}` SSE 路由 + session key 注入（修复 agent-server 403）；rate limiter 修复（SSE 排除限流）；容器 bridge IP 路由（port<20000 → 内部 IP，port≥20000 → 127.0.0.1） |
| `patch_workspace.py` | `live_status_app_conversation_service.py` | per-conversation workspace 子目录隔离（`/workspace/project/{id}/`）；git init 在 workspace root |
| `patch_frontend_js.py` | JS assets + `index.html` + `middleware.py` | cache-control no-cache；socket.io polling；v1-svc 路由；FakeWS 全局拦截；cache busting（z-suffix rename）；browser store expose |
| `patch_code_app_tabs.py` | `app.py` | `/api/sandbox-port/{port}/*` HTTP/WS 反代（VSCode/App tab）；App tab 自动端口扫描（scan HTML、探针、目录列表拒绝）；scan WebSocket 代理（subprotocol 转发）；VSCode tab URL 修复 |
| `agent_server_proxy.py` | `app.py`（模块） | agent-server 反向代理：per-conv URL 查 SQLite；per-session key 注入；TTL cache（60s container，1h key/url） |
| `patch_fakews.py` | 宿主机 JS（单独运行） | FakeWS polyfill（绕过 klogin WebSocket 限制，将 WS 降级为 socket.io polling） |

### 补丁8 详细说明：Per-Conversation 工作目录隔离

**问题**：sandbox 复用（补丁1）后所有 V1 会话共用 `/workspace/project/`，新会话能看到旧会话文件。

**方案**：在 `_start_app_conversation()` 中，为每个会话创建 `/workspace/project/{task.id.hex}/` 子目录并 git init。后续 `remote_workspace` 和 `start_conversation_request` 均使用此子目录。

**效果**：软隔离——每个会话默认在自己目录工作，技术上仍可 `cd ..` 看到其他会话（同一 Linux 用户）。

### 补丁9+10 详细说明：Code/App tab 访问（sandbox port proxy）

**问题**：OpenHands 侧边栏的 Code tab（VSCode 编辑器）和 App tab（应用预览）通过 `exposed_urls` 中的 `http://127.0.0.1:{port}` URL 打开 iframe。klogin 用户的浏览器无法直接访问远程机器的 127.0.0.1，导致这些 tab 显示空白或报错。

**方案**：
- **补丁9**：在 `app.py` 注入 `/api/sandbox-port/{port}/{path:path}` 路由，作为 HTTP/WebSocket 反向代理。浏览器请求经 klogin → openhands-app（`{APP_PORT}` 端口）→ 转发到容器内 `http://127.0.0.1:{port}`。
- **补丁10**：在 `_container_to_sandbox_info()` 中，返回 `SandboxInfo` 前将 VSCODE/WORKER 的 `exposed_urls` 从 `http://127.0.0.1:{port}` 改写为 `/api/sandbox-port/{port}`。AGENT_SERVER URL 保持绝对路径不变（`_container_to_checked_sandbox_info()` health check 需要）。

**验证**：
```bash
# sandbox port proxy 是否存在（需要 sandbox 在运行中）
curl -s http://localhost:{TUNNEL_PORT}/api/sandbox-port/8001/?tkn=<session_api_key>&folder=/workspace/project
# → 应返回 200 OK + VSCode HTML

# exposed_urls 是否正确重写
curl -s "http://localhost:{TUNNEL_PORT}/api/v1/sandboxes?id=<sandbox_id>" | python3 -m json.tool
# VSCODE.url 应为 /api/sandbox-port/8001/...（不是 http://127.0.0.1:8001）
# AGENT_SERVER.url 应为 http://127.0.0.1:8000（保持绝对路径）
```

---

## 前置条件

本地 Mac 安装 klogin 客户端：
```bash
brew install klogin
```

## 手动步骤说明

### 1. 登录 klogin

```bash
klogin instances list
```

首次运行会弹出 AppleConnect 登录。确认你有一个 **RUNNING** 状态的实例。

### 2. 安装 Docker（首次使用时）

```bash
klogin instances apps sub <instance-id> -a docker
```

安装完成后重新 SSH 进入实例生效。

### 3. 配置 host.docker.internal

SSH 进入实例：
```bash
ssh <instance-id>
```

```bash
# 必须用 hostname -I，不要用 ifconfig.me（klogin 走代理会返回错误 IP）
EXTERNAL_IP=$(hostname -I | awk '{print $1}')
sudo sed -i '/host.docker.internal/d' /etc/hosts
echo "$EXTERNAL_IP host.docker.internal" | sudo tee -a /etc/hosts
```

### 4. 启动 OpenHands

> 不要设置 `OH_SECRET_KEY`，否则 agent-server 认证会 401。

具体命令见对应分支 setup 脚本。关键参数：

```bash
sudo docker ps -a --filter name={AGENT_PREFIX} -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f {CONTAINER} 2>/dev/null || true

sudo docker run -d --pull=always \
  --name {CONTAINER} \
  --network host \
  ...
  -e OH_WEB_URL='http://127.0.0.1:{APP_PORT}' \
  ...
```

### 5. 配置 LLM

编辑 `~/.openhands/settings.json`（klogin 实例上）：
```json
{
  "llm_model": "openai/gemini-3-pro-preview",
  "llm_api_key": "dummy-key",
  "llm_base_url": "http://127.0.0.1:8881/llm/gemini-3-pro-preview/v1"
}
```

> model proxy (dify-model-proxy) 需以 `--network host` 部署在 klogin 本地 8881 端口。

---

## 访问方式

### 域名（推荐，同事直接用）

首次使用需在**本地**创建 ingress（只需运行一次）：

```bash
# 1. 设置静态 IP（ingress 要求）
klogin instances update <instance-id> --static-ip

# 2. 在 klogin 实例上开放防火墙端口
ssh <instance-id> "sudo ufw allow {APP_PORT}"

# 3. 在本地创建 ingress，禁用 klogin OAuth 层（OpenHands 自带鉴权）
klogin ingresses create {INGRESS_NAME} --instance <instance-id> --port {APP_PORT} --access-control=false
```

> `--access-control=false`：跳过 klogin 的 AppleConnect OAuth 代理，由 OpenHands 自己负责认证。避免双重 auth 干扰（klogin OAuth 会拦截 cookie/header，导致 OpenHands 登录异常）。

创建后域名固定为：

```
https://{INGRESS_NAME}.svc.<instance-id>.klogin-user.mlplatform.apple.com
```

需要 AppleConnect 认证，浏览器会自动弹出。

### Agent 启动的 App（Streamlit / Gradio / Flask 等）

**App tab 自动扫描**（补丁 12a–13）：打开侧边栏 App tab 时，代理会自动扫描常用端口（3000、5000、7860、8000、8080、8501–8504 等），找到 AI 启动的 app 后自动跳转。支持：
- Streamlit（WebSocket subprotocol `streamlit` 自动转发）
- Flask、Gradio 等 HTTP/WS app
- 有 session/redirect 的 stateful app（Cookie 转发、Location 重写）

> **App 进程生命周期**：容器 `docker restart` 保留文件，但用户启动的 app 进程不会自动恢复，需在对话中让 AI 重新运行，或手动 `docker exec -d ... python3 app.py`。

**分享给同事（可选，使用 klogin ingress 直连）**：

```bash
# 开放防火墙端口池
ssh <instance-id> "sudo ufw allow 8500:8509/tcp"

# 批量创建 ingress（本地运行）
for port in $(seq 8500 8509); do
  klogin ingresses create app${port} \
    --instance <instance-id> --port ${port} --access-control=false -I
done
```

访问格式：`https://app8501.svc.<instance-id>.klogin-user.mlplatform.apple.com`

> **注意**：UFW 必须提前开放对应端口，否则 klogin health probe 失败，ingress 返回 503。

### SSH 本地隧道

```bash
ssh -f -N -L {TUNNEL_PORT}:127.0.0.1:{APP_PORT} <instance-id>
# 然后访问 http://localhost:{TUNNEL_PORT}
```

---

## 常见问题

### 会话显示 Disconnected

未打前端补丁，或容器 `docker rm -f` 重建后补丁丢失。重新运行 setup 脚本即可。

### 401 Unauthorized

```bash
# 清理旧 agent-server 容器
sudo docker ps -a --filter name={AGENT_PREFIX} -q | xargs -r sudo docker rm -f
sudo docker rm -f {CONTAINER}
# 重新运行 setup 脚本（不加 OH_SECRET_KEY）
```

### V1 会话消息无响应

HTTP POST 到 agent-server 不唤醒 Python agent asyncio 队列。补丁2/6/7 通过 WebSocket 转发解决此问题。如果仍有问题，检查 agent-server 是否在运行：
```bash
sudo docker ps --filter name={AGENT_PREFIX}
```

### 查看日志

```bash
sudo docker logs {CONTAINER} --tail 50
# agent-server 日志
AGENT=$(sudo docker ps --filter name={AGENT_PREFIX} -q | head -1)
sudo docker logs $AGENT --tail 50
```

### 验证 per-conversation 目录隔离

```bash
AGENT=$(sudo docker ps --filter name={AGENT_PREFIX} -q | head -1)
sudo docker exec $AGENT ls /workspace/project/
# 应看到多个 UUID 子目录，每个对应一个会话
```

### App tab 显示 500 Internal Server Error

访问 App tab 时出现 `NameError: name '_PORT_SCAN_HTML' is not defined`。

**原因**：容器 `docker restart` 后 `_PORT_SCAN_HTML` Python 全局变量丢失（patch 12a 注入的常量依赖 app.py 的 writable layer，重启时 Python 进程重载了旧 bytecode 或 patch 未正确持久化）。

**修复**：重新运行 setup 脚本（`bash setup-openhands-klogin-tab.sh`），或单独上传并执行 `patches/patch_code_app_tabs.py`。

### MCP 工具不可用（bridge mode 会话）

Agent 无法调用 MCP 工具，日志显示连接到 `http://127.0.0.1:3003/mcp/mcp` 失败。

**原因**：会话的 `meta.json`（`/workspace/conversations/{conv_id}/meta.json`，存储在 oh-tab-* 容器内）保存了旧的 mcp_url（`127.0.0.1`），即使 patch 1.5 已修复 `live_status_app_conversation_service.py`，已有会话的 meta.json 也不会自动更新。

**修复**：
1. **新建会话**（推荐）：新会话会使用修复后的 `host.docker.internal:...` URL，立即生效。
2. **手动修改 meta.json**（仅限测试）：`docker exec oh-tab-* cat /workspace/conversations/{id}/meta.json` 找到 `mcp_url` 字段，改为 `host.docker.internal`，然后 `docker restart oh-tab-*`。注意：容器重启后 agent-server 可能会回写 meta.json。
