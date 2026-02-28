#!/bin/bash
set -e

echo "=== OpenHands on klogin 一键部署 [tab-display] ==="
echo ""

# 1. 获取实例列表
echo ">>> 获取 klogin 实例列表..."
klogin instances list

echo ""
read -p "请输入你的 instance-id（如 your-name-test1）: " INSTANCE_ID

# 2. 检查实例状态
STATUS=$(klogin instances list -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
    if item['metadata']['name'] == '$INSTANCE_ID':
        print(item.get('status', {}).get('status', 'UNKNOWN'))
        break
" 2>/dev/null || echo "UNKNOWN")

echo "实例状态: $STATUS"

if [ "$STATUS" = "TERMINATED" ]; then
    echo ">>> 启动实例..."
    klogin instances start "$INSTANCE_ID"
    echo "等待实例就绪（约60秒）..."
    sleep 60
fi

# 3. 配置服务器
echo ""
echo ">>> 配置服务器环境..."
# Upload patch files to klogin instance before entering remote block
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo ">>> Uploading patches to $INSTANCE_ID:/tmp/ ..."
scp -o StrictHostKeyChecking=no "$SCRIPT_DIR"/patches/*.py "$INSTANCE_ID":/tmp/
echo "Patches uploaded ✓"

ssh -o StrictHostKeyChecking=no "$INSTANCE_ID" bash << 'REMOTE'
set -e

# 检查 Docker
if ! sudo docker info &>/dev/null 2>&1; then
    echo "错误: Docker 未安装，请先在本地运行："
    echo "  klogin instances apps sub <instance-id> -a docker"
    exit 1
fi
echo "Docker 已安装 ✓"

# 开放防火墙端口（ingress 直连模式需要）
sudo ufw allow 3003
echo "ufw allow 3003 ✓"

# 配置 host.docker.internal（必须用 hostname -I，不能用 ifconfig.me）
EXTERNAL_IP=$(hostname -I | awk '{print $1}')
echo "实例 IP: $EXTERNAL_IP"
sudo sed -i '/host.docker.internal/d' /etc/hosts
echo "$EXTERNAL_IP host.docker.internal" | sudo tee -a /etc/hosts
echo "hosts 配置完成 ✓"

# 创建独立 settings 目录（与 klogin-deploy 完全隔离）
mkdir -p ~/.openhands-tab

# 从主实例 settings 复制 LLM 配置（只改 base_url 用 host.docker.internal）
CURRENT_MODEL=$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.openhands/settings.json')) as f:
        d = json.load(f)
    print(d.get('llm_model', 'openai/gemini-3-pro-preview'))
except: print('openai/gemini-3-pro-preview')
" 2>/dev/null)
CURRENT_APIKEY=$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.openhands/settings.json')) as f:
        d = json.load(f)
    print(d.get('llm_api_key', 'dummy-key'))
except: print('dummy-key')
" 2>/dev/null)
MODEL_SLUG=$(echo "$CURRENT_MODEL" | sed 's|.*/||')

cat > ~/.openhands-tab/settings.json << EOF
{
  "llm_model": "$CURRENT_MODEL",
  "llm_api_key": "$CURRENT_APIKEY",
  "llm_base_url": "http://host.docker.internal:8881/llm/$MODEL_SLUG/v1",
  "agent": "CodeActAgent",
  "language": "en",
  "enable_default_condenser": true
}
EOF
echo "settings.json 已创建（LLM: $CURRENT_MODEL via host.docker.internal）✓"

# 清理旧 agent-server 和主容器（防止 401 认证冲突）
sudo docker ps -a --filter name=oh-tab- -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f openhands-app-tab 2>/dev/null || true

# 启动 OpenHands（不要加 OH_SECRET_KEY，否则 agent-server 认证会 401）
echo ">>> 启动 OpenHands..."
sudo docker run -d --pull=always \
  --name openhands-app-tab \
  --network host \
  -e SANDBOX_USER_ID=0 \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e AGENT_SERVER_IMAGE_TAG=1.10.0-python \
  -e LOG_ALL_EVENTS=true \
  -e SANDBOX_STARTUP_GRACE_SECONDS=120 \
  -e SANDBOX_USE_HOST_NETWORK=true \
  -e AGENT_SERVER_PORT_RANGE_START=14000 \
  -e AGENT_SERVER_PORT_RANGE_END=15000 \
  -e 'SANDBOX_CONTAINER_URL_PATTERN=http://127.0.0.1:{port}' \
  -e OH_WEB_URL='http://127.0.0.1:3003' \
  -e ENABLE_MCP=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands-tab:/.openhands \
  docker.openhands.dev/openhands/openhands:1.3 \
  uvicorn openhands.server.listen:app --host 0.0.0.0 --port 3003

# 等待启动
echo "等待 OpenHands 启动..."
for i in $(seq 1 30); do
    if sudo docker logs openhands-app-tab 2>&1 | grep -q "Uvicorn running"; then
        echo "OpenHands 启动成功 ✓"
        break
    fi
    [ "$i" -eq 30 ] && echo "警告: 等待超时，请手动确认: sudo docker logs openhands-app-tab"
    sleep 2
done

# ─── 补丁1：sandbox 复用（修复 V1 新建会话 401）───
# 根因：host network 下每次新建会话都调用 start_sandbox()，创建新 agent-server 容器，
# 端口 8000 冲突导致 session key 不匹配 → 401。修复：复用已运行的 sandbox。
# [extracted to patches/patch_sandbox.py]
sudo docker cp /tmp/patch_sandbox.py openhands-app-tab:/tmp/patch_sandbox.py
SANDBOX_RESULT=$(sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox.py 2>&1)
echo "$SANDBOX_RESULT"

# ─── 补丁1.5：bridge mode 网络修复 ───
# 修复三个 bridge 容器网络问题：
# (1) extra_hosts 仅在 network_mode != 'host' 时应用（不管 SANDBOX_USE_HOST_NETWORK 值）
#     → oh-tab- 容器能解析 host.docker.internal → 172.17.0.1
# (2) webhook URL 端口从 OH_WEB_URL 读取（避免默认 3000 与 tab-display 端口 3003 不符）
# (3) MCP URL 替换 127.0.0.1 → host.docker.internal（bridge 容器内 127.0.0.1 是自身）
# [extracted to patches/patch_bridge_fixes.py]
sudo docker cp /tmp/patch_bridge_fixes.py openhands-app-tab:/tmp/patch_bridge_fixes.py
sudo docker exec openhands-app-tab python3 /tmp/patch_bridge_fixes.py

# ─── 补丁2：agent-server 反向代理路由（修复 V1 Disconnected + 消息无响应）───
# 问题1：V1 会话的 agent-server URL 是 http://127.0.0.1:8000，浏览器无法直接访问。
# 问题2：klogin ingress 剥离 WebSocket Upgrade 头，原生 WS 连接失败。
# 问题3（核心）：POST /api/conversations/{id}/events 只存 DB，不唤醒 Python agent asyncio
#               队列。必须通过 WebSocket 发送才能触发 agent 处理消息！
# 修复：
#   - 反向代理路由（HTTP/SSE/WS）让浏览器通过 klogin 访问 agent-server
#   - SSE 端点替代 WebSocket（klogin 不拦截普通 HTTP）
#   - POST /api/conversations/{id}/events 专用路由：收到 HTTP POST 后内部开 WS 转发

# [extracted to patches/agent_server_proxy.py]

# [extracted to patches/patch_app.py]

sudo docker cp /tmp/agent_server_proxy.py openhands-app-tab:/app/openhands/server/routes/agent_server_proxy.py
sudo docker cp /tmp/patch_app.py openhands-app-tab:/tmp/patch_app.py
sudo docker exec openhands-app-tab python3 /tmp/patch_app.py

# ─── 补丁2b：rate limiter 修复（klogin 共享 IP + SSE 重连风暴）───
# 根因1：klogin 所有请求共用同一代理 IP，per-IP 10req/s 限流会误杀正常请求。
# 根因2：老 browser tab 的 SSE 失败后不断重连，把限流配额耗尽。
# 修复：SSE 端点排除限流 + 用 X-Forwarded-For 获取真实客户端 IP。
# [extracted to patches/patch_rate_limiter.py]
sudo docker cp /tmp/patch_rate_limiter.py openhands-app-tab:/tmp/patch_rate_limiter.py
sudo docker exec openhands-app-tab python3 /tmp/patch_rate_limiter.py

# ─── 补丁2c：CacheControlMiddleware 改为 no-cache（防止浏览器将 JS 资产缓存为 immutable）───
# 根因：middleware.py 的 CacheControlMiddleware 对所有 /assets/*.js 设置 immutable(max-age=30d)，
# 导致补丁修改的 JS 文件无法被浏览器重新获取，必须使用全新文件名才能绕过缓存。
# 修复：改为 no-cache, must-revalidate，让浏览器每次都向服务器确认文件是否更新。
# [extracted to patches/patch_cache_control.py]
sudo docker cp /tmp/patch_cache_control.py openhands-app-tab:/tmp/patch_cache_control.py
sudo docker exec openhands-app-tab python3 /tmp/patch_cache_control.py

# ─── 补丁3：socket.io polling（修复 V0 会话 Disconnected）───
# klogin 会剥离 WebSocket Upgrade 头，改为 polling+websocket 顺序，先用 polling
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_FILE=/tmp/oh-patch-${JS_ASSET}
    sudo docker cp openhands-app-tab:/app/frontend/build/assets/${JS_ASSET} $JS_FILE 2>/dev/null || continue
    sudo chmod 666 $JS_FILE
    if ! grep -q 'polling.*websocket' $JS_FILE 2>/dev/null; then
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_FILE
        sudo docker cp $JS_FILE openhands-app-tab:/app/frontend/build/assets/${JS_ASSET}
        echo "socket.io polling 补丁已应用: ${JS_ASSET} ✓"
    else
        echo "socket.io polling 补丁已存在: ${JS_ASSET} ✓"
    fi
done

# ─── 补丁4：v1-conversation-service.js 路由改为走反向代理 ───
# C() 和 $() 函数改为使用 window.location.host/agent-server-proxy，
# 这样浏览器的所有 agent-server 调用都走 openhands-app-tab（port 3003），可通过 klogin
# [extracted to patches/patch_v1svc.py]
sudo docker cp /tmp/patch_v1svc.py openhands-app-tab:/tmp/patch_v1svc.py
sudo docker exec openhands-app-tab python3 /tmp/patch_v1svc.py

# ─── 补丁5：should-render-event.js（已废弃，由 index.html FakeWS 全局 override window.WebSocket）───
# index.html 的 patch 7 已全局覆盖 window.WebSocket，should-render-event.js 内的 new WebSocket(L)
# 会自动被 FakeWS 拦截，无需再修改 BMHP.js 文件。
# 原来此处注入 EventSource 代码会产生有效或无效正则，对浏览器 immutable cache 造成污染，已移除。
# 保留原版 BMHP.js（有效 JS）以避免 "Invalid regular expression flags" SyntaxError。
# [extracted to patches/patch_sre.py]
sudo docker cp /tmp/patch_sre.py openhands-app-tab:/tmp/patch_sre.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sre.py

# ─── 补丁5b：cache busting — 重命名已修改的 JS 文件（bust proxy/browser immutable cache）───
# should-render-event → BMHPx, conversation-fHdubO7R → Rx, manifest → x, 更新 index.html
# [extracted to patches/patch_cache_bust.py]
sudo docker cp /tmp/patch_cache_bust.py openhands-app-tab:/tmp/patch_cache_bust.py
sudo docker exec openhands-app-tab python3 /tmp/patch_cache_bust.py

# ─── 补丁12：browser store 全局暴露（修复 Browser tab 截图不更新）───
# 根因：V1 browse observation 事件 (BrowserObservation/browse) 经 FakeWS 传递给前端，
#       但 useBrowserStore (Zustand) 不在 window 作用域，FakeWS 无法直接调用 setScreenshotSrc。
# 修复：在包含 screenshotSrc 初始状态的 JS bundle 末尾注入
#       window.__oh_browser_store = <store_var>，使 FakeWS 可访问 Zustand store。
# [extracted to patches/patch_browser_store_expose.py]
sudo docker cp /tmp/patch_browser_store_expose.py openhands-app-tab:/tmp/patch_browser_store_expose.py
sudo docker exec openhands-app-tab python3 /tmp/patch_browser_store_expose.py

# ─── 补丁6：app.py 注入 /api/proxy/events 路由（klogin 转发 /api/*）───
# klogin 只转发 /api/* 和 /socket.io/*。
# GET  /api/proxy/events/{id}/stream     — SSE 事件流（FakeWS EventSource 用）
# POST /api/proxy/conversations/{id}/events — 收 HTTP POST 后内部走 WebSocket 发给 agent
#   ↑ 关键！HTTP POST 直接发给 agent-server 不会唤醒 Python agent asyncio 队列，
#     必须通过 WebSocket 发送才能触发 LLM 调用。
# [extracted to patches/patch_api_proxy_events.py]
sudo docker cp /tmp/patch_api_proxy_events.py openhands-app-tab:/tmp/patch_api_proxy_events.py
sudo docker exec openhands-app-tab python3 /tmp/patch_api_proxy_events.py

# ─── 补丁3.5：SSE/POST proxy 注入 session_api_key ───
# GET /api/conversations/{id} 对 V1 会话返回 session_api_key: null
# → BMHP.js 的 s=null → WS URL 无 key → FakeWS SSE URL 无 key → agent-server 403
# 修复：在 SSE proxy 注入 _gask()（从 oh-tab- 容器 env 读取全局 key）
# [extracted to patches/fix_session_key.py]
sudo docker cp /tmp/fix_session_key.py openhands-app-tab:/tmp/fix_session_key.py
sudo docker exec openhands-app-tab python3 /tmp/fix_session_key.py

# ─── 补丁7：index.html 注入全局 WebSocket/fetch 拦截器 ───
# klogin 代理层会缓存 /assets/*.js，补丁可能对浏览器不生效。
# index.html 设置了 no-store，每次都新鲜，是最可靠的注入点。
# FakeWS: 拦截 /sockets/events/ WebSocket → EventSource → /api/proxy/events/{id}/stream
# send(): 用 /api/proxy/conversations/{id}/events（klogin 可转发）
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html
sudo chmod 666 /tmp/oh-index.html
python3 /tmp/patch_fakews.py
sudo docker cp /tmp/oh-index.html openhands-app-tab:/app/frontend/build/index.html

# ─── 补丁8：per-conversation 工作目录隔离 ───
# 根因：host network sandbox 复用导致所有 V1 会话共用 /workspace/project/，互相可见文件。
# 修复：在 _start_app_conversation() 中，为每个会话创建独立子目录
#       /workspace/project/{task.id.hex}/ 并 git init，后续代码使用此目录。
# [extracted to patches/patch_per_conv_workspace.py]
sudo docker cp /tmp/patch_per_conv_workspace.py openhands-app-tab:/tmp/patch_per_conv_workspace.py
sudo docker exec openhands-app-tab python3 /tmp/patch_per_conv_workspace.py

# ─── 补丁8b：迁移 git init 到 workspace root（Changes tab 修复）───
# 根因：git init 在 per-conv 子目录，但 Changes tab 始终查询 /workspace。
# 修复：git init 在 workspace root（/workspace），用 .git/info/exclude 排除系统目录。
# [extracted to patches/patch_git_workspace_root.py]
sudo docker cp /tmp/patch_git_workspace_root.py openhands-app-tab:/tmp/patch_git_workspace_root.py
sudo docker exec openhands-app-tab python3 /tmp/patch_git_workspace_root.py

# ─── 补丁9b：sandbox-port proxy 使用容器 bridge IP（App tab 访问任意容器内端口）───
# 根因：proxy 用 http://127.0.0.1:{port}，容器内部端口（如 streamlit 8502）未映射到宿主机，
#       无法通过宿主机 127.0.0.1 访问。
# 修复：添加 _get_oh_tab_ip()，port < 20000 用容器 bridge IP（内部端口），
#       port >= 20000 用 127.0.0.1（Docker NAT 映射端口，如 VSCode 39377→8001）。
# [extracted to patches/patch_sandbox_proxy_container_ip.py]
sudo docker cp /tmp/patch_sandbox_proxy_container_ip.py openhands-app-tab:/tmp/patch_sandbox_proxy_container_ip.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_proxy_container_ip.py

# ─── 补丁9：sandbox port proxy（Code/App tab 浏览器访问）───
# VSCode (8001), App 预览 (8011/8012) 的 URL 是 http://127.0.0.1:{port}，
# 浏览器无法通过 klogin 访问。在 openhands-app-tab 注入 /api/sandbox-port/{port}/* 代理路由。
# [extracted to patches/patch_sandbox_port_proxy.py]
sudo docker cp /tmp/patch_sandbox_port_proxy.py openhands-app-tab:/tmp/patch_sandbox_port_proxy.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_port_proxy.py

# ─── 补丁10：exposed_urls 代理路径重写（VSCODE/WORKER → /api/sandbox-port/{host_port}/）───
# Per-session 模式：每个容器都有唯一的宿主机映射端口（host port），
# 改写为 /api/sandbox-port/{host_port}（从 URL 中提取）。
# AGENT_SERVER 保持绝对 URL（health check 需要）。
# [extracted to patches/patch_sandbox_exposed_urls.py]
sudo docker cp /tmp/patch_sandbox_exposed_urls.py openhands-app-tab:/tmp/patch_sandbox_exposed_urls.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_exposed_urls.py

# ─── 补丁11：vscode-tab JS 修复 + z-suffix cache busting ───
# 根因：new URL(r.url) 当 r.url 是相对路径时抛 TypeError → "Error parsing URL"
# 修复：new URL(r.url, window.location.origin)
# 由于 assets 被标记 immutable，需要创建新文件名（z 后缀）打破缓存链
# [extracted to patches/patch_vscode_tab.py]
sudo docker cp /tmp/patch_vscode_tab.py openhands-app-tab:/tmp/patch_vscode_tab.py
sudo docker exec openhands-app-tab python3 /tmp/patch_vscode_tab.py

# ─── 补丁12a：sandbox-port proxy 连接失败时返回端口自动扫描页（App tab 自动跳到运行中的 app）───
# 根因：WORKER 端口（8011/8012）通常没有监听；真实 app（如 streamlit）在内部端口（8502）。
# 修复：proxy 收到 ConnectError 且路径为根路径时，返回一段 HTML，
#       自动扫描常用端口（3000,5000,7860,8080,8501,8502,...），找到后跳转。
# [extracted to patches/patch_port_scan_html.py]
sudo docker cp /tmp/patch_port_scan_html.py openhands-app-tab:/tmp/patch_port_scan_html.py
sudo docker exec openhands-app-tab python3 /tmp/patch_port_scan_html.py

# ─── 补丁12b：Tab 三项修复（VSCode 403→tkn / no-slash redirect / per-session scan）───
# [extracted to patches/patch_tabs_fixes.py]
sudo docker cp /tmp/patch_tabs_fixes.py openhands-app-tab:/tmp/patch_tabs_fixes.py
sudo docker exec openhands-app-tab python3 /tmp/patch_tabs_fixes.py

# --- Fix 12c: sandbox-port proxy -- show scan HTML for directory listings ---
# Root cause: Python's http.server returns valid HTML ("Directory listing for /"),
# so the existing agent-server JSON check does not trigger scan HTML.
# Fix: detect directory listing response at root GET and show scan page instead.
# [extracted to patches/patch_dir_listing_scan.py]
sudo docker cp /tmp/patch_dir_listing_scan.py openhands-app-tab:/tmp/patch_dir_listing_scan.py
sudo docker exec openhands-app-tab python3 /tmp/patch_dir_listing_scan.py

# --- Fix 12d: scan probe rejects directory listings (return 502 to skip port) ---
# Scan probe (X-OH-Tab-Scan:1) was accepting directory listing as valid app HTML.
# Fix: detect "Directory listing for" in scan probe response -> return 502,
# so tryPort() returns false and scan continues to find the real app port.
# Applies to both httpx bridge-IP path and docker-exec fallback path.
# [extracted to patches/patch_dir_listing_probe.py]
sudo docker cp /tmp/patch_dir_listing_probe.py openhands-app-tab:/tmp/patch_dir_listing_probe.py
sudo docker exec openhands-app-tab python3 /tmp/patch_dir_listing_probe.py

# ─── 重启 openhands-app-tab 使所有 Python 补丁生效 ───
echo ""
echo ">>> 重启 openhands-app-tab 使补丁生效..."
sudo docker restart openhands-app-tab
for i in $(seq 1 30); do
    sudo docker logs openhands-app-tab 2>&1 | grep -q "Uvicorn running" && echo "重启完成 ✓" && break
    sleep 2
done

# 重启后重新注入 JS 补丁（docker restart 保留 writable layer，但做一次确认）
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_TMP=/tmp/oh-patch-${JS_ASSET}
    sudo docker cp openhands-app-tab:/app/frontend/build/assets/${JS_ASSET} $JS_TMP 2>/dev/null || continue
    sudo chmod 666 $JS_TMP
    grep -q 'polling.*websocket' $JS_TMP 2>/dev/null || {
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_TMP
        sudo docker cp $JS_TMP openhands-app-tab:/app/frontend/build/assets/${JS_ASSET}
        echo "重启后重新注入 polling 补丁: ${JS_ASSET}"
    }
done
# 重新注入 index.html FakeWS（/api/proxy/events 路径，klogin 可转发，含 browser tab fix）
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html 2>/dev/null
sudo chmod 666 /tmp/oh-index.html 2>/dev/null
python3 /tmp/patch_fakews.py
sudo docker cp /tmp/oh-index.html openhands-app-tab:/app/frontend/build/index.html 2>/dev/null || true
REMOTE

# 4. 配置 klogin ingress（域名访问，只需运行一次）
echo ""
echo ">>> 配置 klogin ingress..."
# 确保实例有静态 IP（ingress 必需）
klogin instances update "$INSTANCE_ID" --static-ip 2>/dev/null && echo "静态 IP 已设置 ✓" || echo "静态 IP 已存在或设置失败（可忽略）"
# 创建 ingress（已存在则跳过）
klogin ingresses create openhands-tab --instance "$INSTANCE_ID" --port 3003 --access-control=false 2>/dev/null \
  && echo "ingress 创建成功 ✓" \
  || echo "ingress 已存在或创建失败（可忽略，域名: https://openhands-tab.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com）"

# 5. 建立本地 SSH 隧道并验证
echo ""
echo ">>> 建立本地隧道并验证..."
pkill -f "ssh.*-L 3001.*$INSTANCE_ID" 2>/dev/null || true
sleep 1
ssh -f -N -L 3004:127.0.0.1:3003 "$INSTANCE_ID"
sleep 2

echo "测试 API 连通性..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3004/api/options/models)
if [ "$HTTP_CODE" != "200" ]; then
    echo "警告: API 返回 $HTTP_CODE，请检查 OpenHands 是否启动"
else
    echo "API 连通 ✓"
fi

echo "测试代理路由..."
PROXY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3004/agent-server-proxy/health)
[ "$PROXY_CODE" = "200" ] && echo "agent-server 代理路由 ✓" || echo "警告: 代理路由返回 $PROXY_CODE"

echo "测试 sandbox port proxy（Code/App tab）..."
SPORT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:3004/api/sandbox-port/8001/")
[ "$SPORT_CODE" = "200" ] || [ "$SPORT_CODE" = "302" ] || [ "$SPORT_CODE" = "403" ] && \
  echo "sandbox port proxy 路由 ✓（HTTP $SPORT_CODE）" || \
  echo "警告: sandbox port proxy 返回 $SPORT_CODE（正常情况需等 sandbox 启动后才能访问）"

echo "测试新建 V1 会话（浏览器路径）..."
CONV_V1_RESP=$(curl -s -X POST http://localhost:3004/api/v1/app-conversations \
  -H 'Content-Type: application/json' \
  -d '{"initial_user_msg": "hello"}')
CONV_V1_ID=$(echo "$CONV_V1_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
CONV_V1_STATUS=$(echo "$CONV_V1_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)
if [ -z "$CONV_V1_ID" ] || echo "$CONV_V1_RESP" | grep -q '"401"\|Unauthorized'; then
    echo "警告: V1 API 无法创建会话，响应: $CONV_V1_RESP"
    echo "  → 检查是否已应用 sandbox 复用补丁"
else
    echo "V1 会话创建成功 (ID: ${CONV_V1_ID:0:8}... status:$CONV_V1_STATUS) ✓"
fi

echo "等待 V1 会话就绪..."
if [ -n "$CONV_V1_ID" ]; then
    for i in $(seq 1 40); do
        STATUS_INFO=$(curl -s "http://localhost:3004/api/conversations/$CONV_V1_ID" | \
          python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''), d.get('runtime_status',''))" 2>/dev/null || true)
        if echo "$STATUS_INFO" | grep -q "RUNNING.*READY"; then
            echo "会话就绪 ✓"
            break
        fi
        [ "$i" -eq 40 ] && echo "警告: 会话 120s 内未就绪，当前状态: $STATUS_INFO"
        sleep 3
    done
fi

echo "测试 /api/proxy/events SSE 事件流（V1 Connected 依赖，klogin 转发路径）..."
CONV_ID="$CONV_V1_ID"
API_KEY=$(curl -s "http://localhost:3004/api/conversations/$CONV_ID" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('session_api_key',''))" 2>/dev/null || true)
if [ -n "$CONV_ID" ] && [ -n "$API_KEY" ]; then
    SSE_FIRST=$(curl -s -N --max-time 5 \
      -H 'Accept: text/event-stream' \
      "http://localhost:3004/api/proxy/events/$CONV_ID/stream?resend_all=true&session_api_key=$API_KEY" \
      2>/dev/null | head -2)
    if echo "$SSE_FIRST" | grep -q '__connected__\|full_state'; then
        echo "SSE 事件流正常 ✓（浏览器 V1 会话将显示 Connected）"
    else
        echo "警告: /api/proxy/events SSE 未返回事件: $SSE_FIRST"
    fi
else
    echo "警告: 无法获取 session_api_key（CONV_ID=$CONV_ID）"
fi

# 5. 输出结果
echo ""
echo "========================================"
echo "✓ 部署完成！所有补丁已应用："
echo "  - sandbox 复用（防 401）"
echo "  - agent-server 反向代理（HTTP + SSE）"
echo "  - CacheControlMiddleware: no-cache 替代 immutable（防浏览器永久缓存 JS 补丁）"
echo "  - socket.io polling 回退（V0 会话）"
echo "  - /api/proxy/events SSE 路由（klogin 可转发，修复 V1 Disconnected）"
echo "  - index.html FakeWS（WebSocket→EventSource→/api/proxy/events）"
echo "  - per-conversation 工作目录隔离（每个会话独立子目录）"
echo "  - rate limiter 修复（SSE 排除 + X-Forwarded-For，防 klogin 共享 IP 429）"
echo "  - sandbox port proxy（Code/App tab 通过 /api/sandbox-port/ 访问，CSP stripped, remoteAuthority cleared）"
echo "  - App tab 自动扫描端口（proxy 失败时返回 scan 页，自动跳到运行中的 app）"
echo "  - Enter 键修复（served-tab URL bar，触发 blur 导航）"
echo "  - exposed_urls 代理路径重写（VSCODE/WORKER URL → /api/sandbox-port/）"
echo "  - vscode-tab URL parse fix（new URL relative path fix + z-suffix cache busting）"
echo "  - git-service.js poll 修复（V1 新建会话直接返回真实 conversation_id）"
echo "  - task-nav-fix（index.html 兜底脚本，确保浏览器缓存情况下也能跳转会话）"
echo "  - cache busting z-suffix（manifest/conversation JS 全新 URL，清除旧 immutable 缓存）"
echo ""
echo "访问方式："
echo "  域名（推荐）: https://openhands-tab.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com"
echo "  本地隧道:     http://localhost:3004  (隧道已在后台运行)"
echo ""
echo "同事访问域名无需任何隧道，AppleConnect 认证即可。"
echo "下一步: 打开上方任意地址 → Settings → 配置 LLM"
echo "========================================"
