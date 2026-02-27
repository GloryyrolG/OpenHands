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
| 11 | vscode-tab URL parse fix + cache bust | `vscode-tab-*.js`（z-suffix 新文件） | `new URL(relativeUrl)` 抛 TypeError → 改为 `new URL(url, window.location.origin)`；z-suffix 绕过 30d immutable 缓存 |

### 补丁8 详细说明：Per-Conversation 工作目录隔离

**问题**：sandbox 复用（补丁1）后所有 V1 会话共用 `/workspace/project/`，新会话能看到旧会话文件。

**方案**：在 `_start_app_conversation()` 中，为每个会话创建 `/workspace/project/{task.id.hex}/` 子目录并 git init。后续 `remote_workspace` 和 `start_conversation_request` 均使用此子目录。

**效果**：软隔离——每个会话默认在自己目录工作，技术上仍可 `cd ..` 看到其他会话（同一 Linux 用户）。

### 补丁9+10+11 详细说明：Code/App tab 访问（sandbox port proxy）

**问题根因**：VSCode/App 服务跑在服务器上，地址是 `http://127.0.0.1:{port}`（HTTP）。浏览器页面是 HTTPS，安全规定不允许 HTTPS 页面加载 HTTP 内容（mixed content），直接嵌 iframe 会被拒绝。

**核心思路**：在服务器上加一个路由作为中转——浏览器只跟同一个 HTTPS 域名说话，服务器在内部把请求转给真实端口。本质上是「用路径区分端口」而不是「用不同子域名区分端口」：

```
路径方案（我们用的）： https://openhands.svc.xxx.../api/sandbox-port/8001/
子域名方案（未采用）： https://app8001.svc.xxx.../
```

路径方案的好处：一个 klogin ingress 搞定所有端口，不需要为每个端口单独创建 ingress。

**方案**：
- **补丁9**：在 `app.py` 注入 `/api/sandbox-port/{port}/{path:path}` 路由（OpenHands 原生不支持，我们自己加的），作为 HTTP/WebSocket 反向代理。URL 里的端口号直接读出来转发，不查表。
  - **klogin-deploy**（host network）：所有端口在宿主机上直接可达，`127.0.0.1:{port}` 即可。VSCode 永远在 8001，所有会话共用同一个地址（只有 `tkn` 不同）。
  - **bridge-mode**：固定端口（VSCode 8001/App 8011/8012）由 Docker 发布到宿主机随机端口（如 47131），P10 改写后转发随机端口；用户自启 app（如 8506）仅在容器内，`_find_bridge_target()` 扫描容器 IP 转发。
- **补丁10**：把 `exposed_urls` 里的 `http://127.0.0.1:{port}` 改写为 `/api/sandbox-port/{port}`（相对路径），让前端拿到可用的 URL。改为相对路径还消除了协议不匹配（`http:` vs `https:`）导致的跨域 Cookie 警告。
- **补丁11**：前端 JS 解析相对路径时崩溃（`new URL('/api/...')` 无 base 会报错），改为 `new URL(url, window.location.origin)` 修复；z-suffix 重命名绕过浏览器 30d immutable 缓存。

**直接访问 VSCode**（不通过 OpenHands UI）：
```bash
# 查询某个会话的 VSCode 完整 URL
curl -s "http://localhost:{APP_PORT}/api/v1/sandboxes?id=<sandbox_id>" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for eu in d[0].get('exposed_urls') or []:
    if eu['name'] == 'VSCODE':
        print('https://{INGRESS_NAME}.svc.<instance-id>.klogin-user.mlplatform.apple.com' + eu['url'])
"
```

**验证**：
```bash
# exposed_urls 是否正确重写
curl -s "http://localhost:{APP_PORT}/api/v1/sandboxes?id=<sandbox_id>" | python3 -m json.tool
# VSCODE.url 应为 /api/sandbox-port/{port}/...（相对路径）
# AGENT_SERVER.url 应为 http://127.0.0.1:{port}（保持绝对路径，health check 需要）
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

### Agent 启动的 App 分享给同事（Streamlit / Gradio 等）

分享方案因分支（网络模式）而异：

#### klogin-deploy（host network）

sandbox 端口直接暴露在宿主机，可用 klogin ingress 直连。`/api/sandbox-port/` 对 WebSocket 密集型 app 不可靠（klogin 剥离 WS Upgrade 头），推荐 ingress 方案。

**一次性准备**（预留端口池 8500–8509）：

```bash
# 开放防火墙
ssh <instance-id> "sudo ufw allow 8500:8509/tcp"

# 批量创建 ingress（本地运行）
for port in $(seq 8500 8509); do
  klogin ingresses create app${port} \
    --instance <instance-id> \
    --port ${port} \
    --access-control=false \
    -I
done
```

访问地址格式：`https://app8501.svc.<instance-id>.klogin-user.mlplatform.apple.com`

**使用方式**：让 agent 把 app 启动在 8500–8509 中任意一个端口，把对应 URL 发给同事即可。
需要换 app 时，停掉旧进程，在同一端口启新 app，URL 不变。

> **注意**：UFW 必须提前开放对应端口，否则 klogin health probe 探活失败，ingress 显示 `READY=false`，访问返回 503。

#### bridge-mode（bridge network）

sandbox 容器运行在 Docker bridge 网络，用户 app 端口**不发布到宿主机**，klogin ingress 直连不可用。
**正确方案**：通过 `/api/sandbox-port/{port}/` 路由访问，bridge-P9 的 `_find_bridge_target()` 会自动扫描容器 IP 转发。

```
浏览器 → openhands-bridge ingress → /api/sandbox-port/{port}/ → 容器 IP:{port}
```

访问地址格式：
```
https://{INGRESS_NAME}.svc.<instance-id>.klogin-user.mlplatform.apple.com/api/sandbox-port/{port}/
```

**使用方式**：让 agent 把 app 启动在任意端口（如 8506），分享上述 URL 即可。无需预留端口池或创建额外 ingress。

> **注意**：klogin 剥离 WS Upgrade 头，WebSocket 密集型 app（如原生 Streamlit）可能功能受限。Gradio / HTTP-only app 可正常使用。

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

### Code tab 显示「跨域 Cookie 错误」

> "The code editor cannot be embedded due to browser security restrictions. Cross-origin cookies are being blocked."

**根因**：`exposed_urls` 中 VSCODE 的 URL 仍为 `http://127.0.0.1:{port}`（HTTP 协议）。vscode-tab 组件检测到 URL 协议（`http:`）与页面协议（`https:`）不匹配，触发跨域警告。

**修复**：确保补丁9、10、11 均已应用。

```bash
# 检查 exposed_urls 是否已重写（URL 应为相对路径，不含 http://）
curl -s "http://localhost:{TUNNEL_PORT}/api/v1/sandboxes?id=<sandbox_id>" | python3 -c "
import sys, json
sandboxes = json.load(sys.stdin)
for eu in (sandboxes[0].get('exposed_urls') or []):
    print(eu['name'], eu['url'][:60])
"
# VSCODE 应显示 /api/sandbox-port/...（相对路径）

# 若补丁未应用，重新运行 setup 脚本后 docker restart {CONTAINER}
```

还需强制刷新浏览器（Cmd+Shift+R）清除旧缓存的 JS 文件。

### 验证 per-conversation 目录隔离

```bash
AGENT=$(sudo docker ps --filter name={AGENT_PREFIX} -q | head -1)
sudo docker exec $AGENT ls /workspace/project/
# 应看到多个 UUID 子目录，每个对应一个会话
```
