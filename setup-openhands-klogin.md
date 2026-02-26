# OpenHands on klogin 部署教程

> 全程不需要克隆任何代码，只需要 klogin 账号和 Docker。

## 前置条件

本地 Mac 安装 klogin 客户端：
```bash
brew install klogin
```

## 一键部署

```bash
bash setup-openhands-klogin.sh
```

脚本会自动完成下面所有步骤，包括打补丁让域名访问正常工作。

---

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

> ⚠️ 不要设置 `OH_SECRET_KEY`，否则 agent-server 认证会 401。

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

### 5. 打前端补丁（域名访问必须）

klogin ingress 会剥离 WebSocket 升级头，不打补丁则域名访问时会话显示 Disconnected。

```bash
JS_FILE=/tmp/oh-md-patch.js
sudo docker cp openhands-app:/app/frontend/build/assets/markdown-renderer-Ci-ahARR.js $JS_FILE
sudo chmod 644 $JS_FILE
sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_FILE
sudo docker cp $JS_FILE openhands-app:/app/frontend/build/assets/markdown-renderer-Ci-ahARR.js
```

> 此补丁在容器内，`docker restart` 不影响，`docker rm -f` 重建后需重打（脚本已自动处理）。

### 6. 配置 LLM

编辑 `~/.openhands/settings.json`（klogin 实例上）：
```json
{
  "llm_model": "openai/gemini-3-pro-preview",
  "llm_api_key": "dummy-key",
  "llm_base_url": "http://127.0.0.1:8881/llm/gemini-3-pro-preview/v1"
}
```

> model proxy (dify-model-proxy) 已部署在 klogin 本地 8881 端口，无需任何隧道转发。

---

## 访问方式

### 域名（推荐，同事直接用）

```
https://openhands.svc.<instance-id>.klogin-user.mlplatform.apple.com
```

需要 AppleConnect 认证，浏览器会自动弹出。

### SSH 本地隧道

```bash
# 只需端口转发，不需要 -R 反向隧道
ssh -f -N -L 3001:127.0.0.1:3000 <instance-id>
# 然后访问 http://localhost:3001
```

---

## 常见问题

### 会话显示 Disconnected

未打前端补丁，或容器重建后补丁丢失。执行步骤 5 重新打补丁即可。

### 401 Unauthorized

重启时未清理旧 agent-server：
```bash
sudo docker ps -a --filter name=oh-agent-server -q | xargs -r sudo docker rm -f
sudo docker restart openhands-app
# 重启后重新执行步骤 5 打补丁
```

确认启动命令**没有** `OH_SECRET_KEY`。

### 查看日志

```bash
sudo docker logs openhands-app --tail 50
```
