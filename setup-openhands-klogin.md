# OpenHands on klogin 部署教程

> 全程不需要克隆任何代码，只需要 klogin 账号和 Docker。

## 一键部署

```bash
bash setup-openhands-klogin.sh
```

脚本会自动完成所有步骤：启动 OpenHands、打全部补丁、建立 SSH 隧道、验证连通性。

---

## 架构概述

```
浏览器 → klogin ingress (剥离 WS Upgrade) → openhands-app (Python, port 3000)
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

| # | 补丁 | 修改文件 | 解决问题 |
|---|------|----------|----------|
| 1 | sandbox 复用 | `docker_sandbox_service.py` | host network 下多 sandbox 争端口 8000 → 401 |
| 2 | agent-server 反向代理 | `agent_server_proxy.py` + `app.py` | 浏览器无法直接访问 127.0.0.1:8000 |
| 3 | socket.io polling | `markdown-renderer-*.js`, `parse-pr-url-*.js` | V0 会话 Disconnected |
| 4 | v1-svc.js 路由重写 | `v1-conversation-service.api-*.js` | V1 API 调用走反向代理 |
| 5 | should-render-event SSE | `should-render-event-*.js` | V1 WebSocket→EventSource |
| 6 | /api/proxy/events 路由 | `app.py` | klogin 只转发 /api/*，SSE 事件流走此路径 |
| 7 | index.html FakeWS | `index.html` | 全局 WS 拦截→SSE，绕过 klogin 缓存 |
| 8 | per-conversation workspace | `live_status_app_conversation_service.py` | 每会话独立工作目录 |
| 2b | rate limiter 修复 | `middleware.py` | klogin 共享 IP + SSE 重连风暴导致全局 429；SSE 排除限流 + X-Forwarded-For |
| 9 | sandbox port proxy | `app.py` | 注入 `/api/sandbox-port/{port}/*` 反代，让浏览器访问 VSCode/App tab |
| 10 | exposed_urls 重写 | `docker_sandbox_service.py` | VSCODE/WORKER URL 改为 `/api/sandbox-port/{port}`；AGENT_SERVER 保持绝对 URL |

### 补丁8 详细说明：Per-Conversation 工作目录隔离

**问题**：sandbox 复用（补丁1）后所有 V1 会话共用 `/workspace/project/`，新会话能看到旧会话文件。

**方案**：在 `_start_app_conversation()` 中，为每个会话创建 `/workspace/project/{task.id.hex}/` 子目录并 git init。后续 `remote_workspace` 和 `start_conversation_request` 均使用此子目录。

**效果**：软隔离——每个会话默认在自己目录工作，技术上仍可 `cd ..` 看到其他会话（同一 Linux 用户）。

### 补丁9+10 详细说明：Code/App tab 访问（sandbox port proxy）

**问题**：OpenHands 侧边栏的 Code tab（VSCode 编辑器）和 App tab（应用预览）通过 `exposed_urls` 中的 `http://127.0.0.1:{port}` URL 打开 iframe。klogin 用户的浏览器无法直接访问远程机器的 127.0.0.1，导致这些 tab 显示空白或报错。

**方案**：
- **补丁9**：在 `app.py` 注入 `/api/sandbox-port/{port}/{path:path}` 路由，作为 HTTP/WebSocket 反向代理。浏览器请求经 klogin → openhands-app（3000端口）→ 转发到容器内 `http://127.0.0.1:{port}`。
- **补丁10**：在 `_container_to_sandbox_info()` 中，返回 `SandboxInfo` 前将 VSCODE/WORKER 的 `exposed_urls` 从 `http://127.0.0.1:{port}` 改写为 `/api/sandbox-port/{port}`。AGENT_SERVER URL 保持绝对路径不变（`_container_to_checked_sandbox_info()` health check 需要）。

**验证**：
```bash
# sandbox port proxy 是否存在（需要 sandbox 在运行中）
curl -s http://localhost:3001/api/sandbox-port/8001/?tkn=<session_api_key>&folder=/workspace/project
# → 应返回 200 OK + VSCode HTML

# exposed_urls 是否正确重写
curl -s "http://localhost:3001/api/v1/sandboxes?id=<sandbox_id>" | python3 -m json.tool
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

```bash
sudo docker ps -a --filter name=oh-agent-server -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f openhands-app 2>/dev/null || true

sudo docker run -d --pull=always \
  --name openhands-app \
  --network host \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e AGENT_SERVER_IMAGE_TAG=1.10.0-python \
  -e LOG_ALL_EVENTS=true \
  -e SANDBOX_STARTUP_GRACE_SECONDS=120 \
  -e SANDBOX_USE_HOST_NETWORK=true \
  -e AGENT_SERVER_PORT_RANGE_START=12000 \
  -e AGENT_SERVER_PORT_RANGE_END=13000 \
  -e 'SANDBOX_CONTAINER_URL_PATTERN=http://127.0.0.1:{port}' \
  -e OH_WEB_URL='http://127.0.0.1:3000' \
  -e ENABLE_MCP=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands:/.openhands \
  docker.openhands.dev/openhands/openhands:1.3
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

```
https://openhands.svc.<instance-id>.klogin-user.mlplatform.apple.com
```

需要 AppleConnect 认证，浏览器会自动弹出。

### SSH 本地隧道

```bash
ssh -f -N -L 3001:127.0.0.1:3000 <instance-id>
# 然后访问 http://localhost:3001
```

---

## 常见问题

### 会话显示 Disconnected

未打前端补丁，或容器 `docker rm -f` 重建后补丁丢失。重新运行 `setup-openhands-klogin.sh` 即可。

### 401 Unauthorized

```bash
# 清理旧 agent-server 容器
sudo docker ps -a --filter name=oh-agent-server -q | xargs -r sudo docker rm -f
sudo docker rm -f openhands-app
# 用上面正确命令重新启动（不加 OH_SECRET_KEY）
```

### V1 会话消息无响应

HTTP POST 到 agent-server 不唤醒 Python agent asyncio 队列。补丁2/6/7 通过 WebSocket 转发解决此问题。如果仍有问题，检查 agent-server 是否在运行：
```bash
sudo docker ps --filter name=oh-agent-server
```

### 查看日志

```bash
sudo docker logs openhands-app --tail 50
# agent-server 日志
AGENT=$(sudo docker ps --filter name=oh-agent-server -q | head -1)
sudo docker logs $AGENT --tail 50
```

### 验证 per-conversation 目录隔离

```bash
AGENT=$(sudo docker ps --filter name=oh-agent-server -q | head -1)
sudo docker exec $AGENT ls /workspace/project/
# 应看到多个 UUID 子目录，每个对应一个会话
```
