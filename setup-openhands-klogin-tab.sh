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
tar czf - -C "$SCRIPT_DIR" patches/ | ssh -o StrictHostKeyChecking=no "$INSTANCE_ID" "tar xzf - -C /tmp/ --strip-components=1"
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

# ─── 模块文件：agent_server_proxy.py (直接 cp 到 /app，不是 patch) ───
sudo docker cp /tmp/agent_server_proxy.py openhands-app-tab:/app/openhands/server/routes/agent_server_proxy.py
echo "agent_server_proxy.py 已上传 ✓"

# ─── 合并补丁（按功能域，顺序不可更改）───
for PATCH in patch_sandbox_infra patch_agent_comms patch_workspace patch_frontend_js patch_code_app_tabs; do
    echo ""
    echo ">>> 应用 ${PATCH}.py ..."
    sudo docker cp /tmp/${PATCH}.py openhands-app-tab:/tmp/
    RESULT=$(sudo docker exec openhands-app-tab python3 /tmp/${PATCH}.py 2>&1)
    echo "$RESULT"
    if echo "$RESULT" | grep -q "^Traceback\|RuntimeError\|ERROR:"; then
        echo "错误: ${PATCH}.py 执行失败，中止部署"
        exit 1
    fi
done
echo ""
echo "所有 Python 补丁已应用 ✓"

# ─── 补丁7：index.html 注入全局 WebSocket/fetch 拦截器 ───
# klogin 代理层会缓存 /assets/*.js，补丁可能对浏览器不生效。
# index.html 设置了 no-store，每次都新鲜，是最可靠的注入点。
# FakeWS: 拦截 /sockets/events/ WebSocket → EventSource → /api/proxy/events/{id}/stream
# send(): 用 /api/proxy/conversations/{id}/events（klogin 可转发）
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html
sudo chmod 666 /tmp/oh-index.html
python3 /tmp/patch_fakews.py
sudo docker cp /tmp/oh-index.html openhands-app-tab:/app/frontend/build/index.html

# ─── 重启 openhands-app-tab 使所有 Python 补丁生效 ───
echo ""
echo ">>> 重启 openhands-app-tab 使补丁生效..."
sudo docker restart openhands-app-tab
for i in $(seq 1 30); do
    sudo docker logs openhands-app-tab 2>&1 | grep -q "Uvicorn running" && echo "重启完成 ✓" && break
    sleep 2
done

# 重启后重新注入（所有 patch 幂等，直接重跑）
echo ">>> 重启后重新应用前端补丁..."
for PATCH in patch_frontend_js patch_code_app_tabs; do
    sudo docker exec openhands-app-tab python3 /tmp/${PATCH}.py 2>&1 | grep -v "✓" | grep "WARNING\|ERROR" || true
done
# FakeWS: 从容器取最新 index.html，注入后放回
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html 2>/dev/null
sudo chmod 666 /tmp/oh-index.html 2>/dev/null
python3 /tmp/patch_fakews.py
sudo docker cp /tmp/oh-index.html openhands-app-tab:/app/frontend/build/index.html 2>/dev/null || true

# ─── 恢复历史会话（重启后所有会话变 STOPPED，自动 stream-start 恢复）───
echo ""
echo ">>> 恢复历史会话..."
python3 << 'PYEOF'
import urllib.request, urllib.error, json, time, sys

BASE = 'http://127.0.0.1:3003'

def api(path, data=None):
    url = BASE + path
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body,
          headers={'Content-Type': 'application/json'} if body else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {'error': e.code, 'body': e.read().decode()[:200]}
    except Exception as e:
        return {'error': str(e)}

# 取所有会话，找 STOPPED 的
convs = api('/api/conversations?limit=100')
if not isinstance(convs, list):
    convs = convs.get('results', convs.get('conversations', []))

stopped = [c for c in convs
           if c.get('status') == 'STOPPED'
           and c.get('conversation_version') == 'V1']

print(f'共 {len(convs)} 个会话，{len(stopped)} 个 STOPPED 需恢复')

ok = fail = 0
for c in stopped:
    cid = c.get('conversation_id', c.get('id', ''))
    r = api('/api/v1/app-conversations/stream-start',
            {'conversation_id': cid})
    if isinstance(r, dict) and 'error' in r:
        print(f'  ✗ {cid[:16]}... 恢复失败: {r}')
        fail += 1
    else:
        first = r[0] if isinstance(r, list) and r else r
        print(f'  ✓ {cid[:16]}... 恢复中（{first.get("status","?") if isinstance(first,dict) else "?"}）')
        ok += 1
    time.sleep(0.5)   # 避免同时启动太多容器

print(f'恢复完成：{ok} 成功，{fail} 失败')
PYEOF
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
