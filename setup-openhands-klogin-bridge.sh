#!/bin/bash
# ============================================================
# OpenHands on klogin — Bridge Mode (per-session sandbox isolation)
# Branch: bridge-mode
# 与 setup-openhands-klogin.sh 完全独立：
#   - 容器名: openhands-app-bridge
#   - 端口:   3002 (app) / 本地隧道 3002→3002
#   - sandbox 前缀: oh-bridge-
#   - settings 目录: ~/.openhands-bridge
#   - LLM URL: host.docker.internal（bridge 容器可达）
#   - sandbox: 每会话独立容器（bridge network + 随机端口）
#   - agent-server URL: 每会话动态查询（/api/conversations/{id}）
# ============================================================
set -e

echo "=== OpenHands Bridge Mode 部署 (独立实例，端口 3002) ==="
echo ""

# ─────────────────────────────────────────────────────────────
# 0. 获取 instance-id
# ─────────────────────────────────────────────────────────────
klogin instances list
echo ""
read -p "请输入 instance-id（如 rongyu-chen-test1）: " INSTANCE_ID

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

# ─────────────────────────────────────────────────────────────
# 1. 在 klogin 上配置环境
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 配置远程环境..."
ssh -o StrictHostKeyChecking=no "$INSTANCE_ID" bash << 'REMOTE'
set -e

# Docker 检查
if ! sudo docker info &>/dev/null; then
    echo "错误: Docker 未安装"
    exit 1
fi
echo "Docker OK ✓"

# 开放防火墙端口（ingress 直连模式需要）
sudo ufw allow 3002
echo "ufw allow 3002 ✓"

# host.docker.internal（必须用 hostname -I）
EXTERNAL_IP=$(hostname -I | awk '{print $1}')
sudo sed -i '/host.docker.internal/d' /etc/hosts
echo "$EXTERNAL_IP host.docker.internal" | sudo tee -a /etc/hosts
echo "hosts 配置 ✓ ($EXTERNAL_IP)"

# 清理旧的 bridge 实例（不碰 openhands-app）
sudo docker ps -a --filter name=oh-bridge- -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f openhands-app-bridge 2>/dev/null || true
echo "旧 bridge 实例已清理 ✓"

# ─── 创建独立 settings 目录 ───
mkdir -p ~/.openhands-bridge

# 读取当前 LLM model 名称（从主实例 settings 复制，只改 base_url）
CURRENT_MODEL=$(python3 -c "
import json, sys
try:
    with open(f'{__import__(\"os\").path.expanduser(\"~\")}/.openhands/settings.json') as f:
        d = json.load(f)
    print(d.get('llm_model', 'openai/gemini-2.5-pro'))
except:
    print('openai/gemini-2.5-pro')
")
CURRENT_APIKEY=$(python3 -c "
import json, sys
try:
    with open(f'{__import__(\"os\").path.expanduser(\"~\")}/.openhands/settings.json') as f:
        d = json.load(f)
    print(d.get('llm_api_key', 'dummy-key'))
except:
    print('dummy-key')
")
# 提取 model slug（去掉 openai/ 前缀）
MODEL_SLUG=$(echo "$CURRENT_MODEL" | sed 's|openai/||')

# 写 bridge settings — LLM base_url 改为 host.docker.internal（bridge 容器可达）
cat > ~/.openhands-bridge/settings.json << EOF
{
  "language": "en",
  "agent": "CodeActAgent",
  "max_iterations": null,
  "security_analyzer": "llm",
  "confirmation_mode": false,
  "llm_model": "$CURRENT_MODEL",
  "llm_api_key": "$CURRENT_APIKEY",
  "llm_base_url": "http://host.docker.internal:8881/llm/$MODEL_SLUG/v1",
  "user_version": null,
  "remote_runtime_resource_factor": 1,
  "secrets_store": {"provider_tokens": {}},
  "enable_default_condenser": true,
  "enable_sound_notifications": false,
  "enable_proactive_conversation_starters": false,
  "enable_solvability_analysis": false,
  "user_consents_to_analytics": false,
  "sandbox_base_container_image": null,
  "sandbox_runtime_container_image": null,
  "mcp_config": {"sse_servers": [], "stdio_servers": [], "shttp_servers": []},
  "search_api_key": null,
  "sandbox_api_key": null,
  "max_budget_per_task": null,
  "condenser_max_size": 240,
  "email": "",
  "email_verified": true,
  "git_user_name": "openhands",
  "git_user_email": "openhands@all-hands.dev",
  "v1_enabled": true
}
EOF
echo "settings.json 已创建（LLM: $CURRENT_MODEL via host.docker.internal）✓"

# ─────────────────────────────────────────────────────────────
# 2. 启动 openhands-app-bridge（端口 3002，不设 SANDBOX_USE_HOST_NETWORK）
# ─────────────────────────────────────────────────────────────
echo ">>> 启动 openhands-app-bridge (port 3002)..."
sudo docker run -d --pull=always \
  --name openhands-app-bridge \
  --network host \
  -e port=3002 \
  -e SANDBOX_HOST_PORT=3002 \
  -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
  -e AGENT_SERVER_IMAGE_TAG=1.10.0-python \
  -e LOG_ALL_EVENTS=true \
  -e SANDBOX_STARTUP_GRACE_SECONDS=120 \
  -e AGENT_SERVER_PORT_RANGE_START=13000 -e AGENT_SERVER_PORT_RANGE_END=14000 \
  -e 'SANDBOX_CONTAINER_URL_PATTERN=http://127.0.0.1:{port}' \
  -e OH_WEB_URL='http://127.0.0.1:3002' \
  -e ENABLE_MCP=false \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.openhands-bridge:/.openhands \
  docker.openhands.dev/openhands/openhands:1.3 \
  uvicorn openhands.server.listen:app --host 0.0.0.0 --port 3002

echo "等待启动..."
for i in $(seq 1 30); do
    sudo docker logs openhands-app-bridge 2>&1 | grep -q "Uvicorn running" && echo "启动成功 ✓" && break
    [ "$i" -eq 30 ] && echo "警告: 启动超时，继续（可能只是慢）"
    sleep 2
done

# ─────────────────────────────────────────────────────────────
# bridge-P1：修改 sandbox 容器名前缀（oh-bridge-，避免与主实例冲突）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch1_prefix.py << 'PYEOF'
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if "container_name_prefix: str = 'oh-bridge-'" in src:
    print('prefix 补丁已存在 ✓')
    exit(0)

old = "container_name_prefix: str = 'oh-agent-server-'"
new = "container_name_prefix: str = 'oh-bridge-'"
if old in src:
    src = src.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(src)
    print("sandbox 前缀已改为 'oh-bridge-' ✓")
else:
    print('警告: prefix pattern 未找到，跳过')
PYEOF
sudo docker cp /tmp/bridge_patch1_prefix.py openhands-app-bridge:/tmp/bridge_patch1_prefix.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch1_prefix.py

# ─────────────────────────────────────────────────────────────
# bridge-P2：动态 agent_server_proxy.py
#    根据 conversation_id 从 API 查 agent_server_url（每个 sandbox 不同端口）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_agent_server_proxy.py << 'PYEOF'
import asyncio
import re
import httpx
import websockets
from fastapi import APIRouter, Request, WebSocket, Response
from starlette.responses import StreamingResponse

# Bridge 模式：每个 conversation 有独立 agent-server（不同端口），动态路由
_BRIDGE_PORT = 3002  # openhands-app-bridge 本身的端口
_url_cache: dict[str, str] = {}  # conversation_id → agent_server base URL

agent_proxy_router = APIRouter(prefix='/agent-server-proxy')


async def _get_agent_server_url(conversation_id: str) -> str:
    """从本地 openhands API 查询对应 conversation 的 agent-server base URL，带内存缓存。"""
    if conversation_id in _url_cache:
        return _url_cache[conversation_id]
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(
                f'http://127.0.0.1:{_BRIDGE_PORT}/api/conversations/{conversation_id}'
            )
            data = resp.json()
            url = data.get('url', '')
            if url and '://' in url:
                # url = "http://127.0.0.1:PORT/api/conversations/..."
                base_url = url.split('/api/conversations/')[0]
                _url_cache[conversation_id] = base_url
                return base_url
    except Exception:
        pass
    return 'http://127.0.0.1:8000'  # fallback


def _to_ws(http_url: str) -> str:
    return http_url.replace('http://', 'ws://').replace('https://', 'wss://')


# ── SSE 端点：WS→SSE + 自动重连（agent-server 发完 backlog 后会关闭 WS）──
@agent_proxy_router.get('/sockets/events/{conversation_id}/sse')
async def proxy_sse(request: Request, conversation_id: str):
    base_url = await _get_agent_server_url(conversation_id)
    params = dict(request.query_params)
    qs = '&'.join(f'{k}={v}' for k, v in params.items())
    ws_url = f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
    if qs:
        ws_url += f'?{qs}'

    async def generate():
        import asyncio
        first = True
        _base_qs = qs.replace('resend_all=true&', '').replace('&resend_all=true', '').replace('resend_all=true', '')
        while True:
            try:
                _url = ws_url if first else f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
                if not first and _base_qs:
                    _url += f'?{_base_qs}'
                async with websockets.connect(_url) as ws:
                    if first:
                        yield 'data: __connected__\n\n'
                        first = False
                    async for msg in ws:
                        data = (msg if isinstance(msg, str) else msg.decode()).replace('\n', '\\n')
                        yield f'data: {data}\n\n'
            except Exception:
                if first:
                    yield 'data: __closed__\n\n'
                    return
            await asyncio.sleep(1)

    return StreamingResponse(
        generate(), media_type='text/event-stream',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'},
    )


# ── WebSocket 代理（备用）──
@agent_proxy_router.websocket('/sockets/events/{conversation_id}')
async def proxy_websocket(websocket: WebSocket, conversation_id: str):
    await websocket.accept()
    base_url = await _get_agent_server_url(conversation_id)
    params = dict(websocket.query_params)
    qs = '&'.join(f'{k}={v}' for k, v in params.items())
    ws_url = f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
    if qs:
        ws_url += f'?{qs}'
    try:
        async with websockets.connect(ws_url) as agent_ws:
            async def c2a():
                try:
                    while True:
                        await agent_ws.send(await websocket.receive_text())
                except Exception:
                    pass

            async def a2c():
                try:
                    async for msg in agent_ws:
                        if isinstance(msg, bytes):
                            await websocket.send_bytes(msg)
                        else:
                            await websocket.send_text(msg)
                except Exception:
                    pass

            done, pending = await asyncio.wait(
                [asyncio.create_task(c2a()), asyncio.create_task(a2c())],
                return_when=asyncio.FIRST_COMPLETED,
            )
            for t in pending:
                t.cancel()
    except Exception:
        pass
    finally:
        try:
            await websocket.close()
        except Exception:
            pass


# ── POST events：旧 action 格式转换为 agent-server v1.10.0-python SDK 格式后 HTTP POST ──
def _convert_action_to_sdk_message(body: bytes) -> bytes:
    """Convert old OpenHands action format to agent-server v1.10.0-python SendMessageRequest format."""
    import json as _json
    try:
        data = _json.loads(body)
        if data.get('action') == 'message' and 'args' in data:
            content_str = data['args'].get('content', '')
            image_urls = data['args'].get('image_urls') or []
            content_items: list = [{'type': 'text', 'text': content_str}]
            for url in image_urls:
                content_items.append({'type': 'image_url', 'image_url': {'url': url}})
            return _json.dumps({
                'role': 'user',
                'content': content_items,
                'run': True,
            }).encode()
    except Exception:
        pass
    return body


@agent_proxy_router.post('/api/conversations/{conversation_id}/events')
async def proxy_send_event_ws(conversation_id: str, request: Request):
    base_url = await _get_agent_server_url(conversation_id)
    params = dict(request.query_params)
    key = request.headers.get('X-Session-API-Key', '') or params.get('session_api_key', '')
    body = await request.body()
    send_body = _convert_action_to_sdk_message(body)
    url = f'{base_url}/api/conversations/{conversation_id}/events'
    headers: dict = {'Content-Type': 'application/json'}
    if key:
        headers['X-Session-API-Key'] = key
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            await client.post(url, content=send_body, headers=headers)
    except Exception:
        pass
    return Response(content='{"success":true}', status_code=200, media_type='application/json')


# ── HTTP catch-all 代理 ──
@agent_proxy_router.api_route('/{path:path}', methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH'])
async def proxy_http(request: Request, path: str):
    # Extract conversation_id from path if present
    m = re.search(r'conversations/([a-f0-9]{32})', path)
    conv_id = m.group(1) if m else None
    base_url = await _get_agent_server_url(conv_id) if conv_id else 'http://127.0.0.1:8000'
    url = f'{base_url}/{path}'
    params = dict(request.query_params)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ('host', 'content-length', 'transfer-encoding', 'connection')}
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.request(
                method=request.method, url=url,
                params=params, headers=headers, content=body,
            )
            resp_headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in ('content-encoding', 'transfer-encoding', 'connection')}
            return Response(content=resp.content, status_code=resp.status_code, headers=resp_headers)
    except Exception as e:
        return Response(content=str(e), status_code=502)
PYEOF

sudo docker cp /tmp/bridge_agent_server_proxy.py openhands-app-bridge:/app/openhands/server/routes/agent_server_proxy.py

# ─────────────────────────────────────────────────────────────
# bridge-P2b：rate limiter 修复（klogin 共享 IP + SSE 重连风暴）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_rate_limiter.py << 'PYEOF'
with open('/app/openhands/server/middleware.py') as f:
    src = f.read()

old_check = (
    "    def is_rate_limited_request(self, request: StarletteRequest) -> bool:\n"
    "        if request.url.path.startswith('/assets'):\n"
    "            return False\n"
    "        # Put Other non rate limited checks here\n"
    "        return True\n"
)
new_check = (
    "    def is_rate_limited_request(self, request: StarletteRequest) -> bool:\n"
    "        path = request.url.path\n"
    "        if path.startswith('/assets'):\n"
    "            return False\n"
    "        # SSE/streaming: long-lived connections, not rapid requests, skip rate limit\n"
    "        if '/sockets/events/' in path and path.endswith('/sse'):\n"
    "            return False\n"
    "        if '/api/proxy/events/' in path and path.endswith('/stream'):\n"
    "            return False\n"
    "        return True\n"
)
old_key = "        key = request.client.host\n"
new_key = (
    "        # klogin proxies all traffic through a single IP; use X-Forwarded-For for real client\n"
    "        key = request.headers.get('x-forwarded-for', '').split(',')[0].strip() or (request.client.host if request.client else '127.0.0.1')\n"
)

if 'sockets/events' in src and '/sse' in src and 'return False' in src[src.find('sockets/events'):]:
    print('rate limiter SSE 排除已存在 ✓')
elif old_check in src:
    src = src.replace(old_check, new_check, 1)
    print('SSE 路径排除限流 ✓')
else:
    print('WARNING: is_rate_limited_request pattern 未匹配，跳过')

if 'x-forwarded-for' in src:
    print('X-Forwarded-For key 已存在 ✓')
elif old_key in src:
    src = src.replace(old_key, new_key, 1)
    print('X-Forwarded-For key 修复 ✓')
else:
    print('WARNING: key pattern 未匹配，跳过')

with open('/app/openhands/server/middleware.py', 'w') as f:
    f.write(src)
PYEOF
sudo docker cp /tmp/bridge_patch_rate_limiter.py openhands-app-bridge:/tmp/bridge_patch_rate_limiter.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_rate_limiter.py

# ─────────────────────────────────────────────────────────────
# bridge-P2c：CacheControlMiddleware 改为 no-cache（防浏览器 immutable 缓存 JS）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_cache_control.py << 'PYEOF'
with open('/app/openhands/server/middleware.py') as f:
    src = f.read()

if 'no-cache, must-revalidate' in src and 'immutable' not in src:
    print('CacheControlMiddleware 已设置 no-cache ✓')
else:
    src = src.replace(
        "'public, max-age=2592000, immutable'",
        "'no-cache, must-revalidate'"
    ).replace(
        '"public, max-age=2592000, immutable"',
        '"no-cache, must-revalidate"'
    )
    with open('/app/openhands/server/middleware.py', 'w') as f:
        f.write(src)
    print('CacheControlMiddleware: immutable → no-cache, must-revalidate ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_cache_control.py openhands-app-bridge:/tmp/bridge_patch_cache_control.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_cache_control.py

# ─────────────────────────────────────────────────────────────
# bridge-P3：socket.io polling（V0 Disconnected）
# ─────────────────────────────────────────────────────────────
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_FILE=/tmp/bridge-${JS_ASSET}
    sudo docker cp openhands-app-bridge:/app/frontend/build/assets/${JS_ASSET} $JS_FILE 2>/dev/null || continue
    sudo chmod 666 $JS_FILE
    if ! grep -q 'polling.*websocket' $JS_FILE 2>/dev/null; then
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_FILE
        sudo docker cp $JS_FILE openhands-app-bridge:/app/frontend/build/assets/${JS_ASSET}
        echo "socket.io polling: ${JS_ASSET} ✓"
    else
        echo "socket.io polling 已存在: ${JS_ASSET} ✓"
    fi
done

# ─────────────────────────────────────────────────────────────
# bridge-P4：v1-conversation-service.js 路由改走 /agent-server-proxy
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_v1svc.py << 'PYEOF'
path = '/app/frontend/build/assets/v1-conversation-service.api-BE_2IImp.js'
with open(path) as f:
    src = f.read()

if 'agent-server-proxy' in src:
    print('v1-svc.js 路由补丁已存在 ✓')
    exit(0)

old_C = 'function C(i){const t=v(i),a=h(i);return`${window.location.protocol==="https:"?"https:":"http:"}//${t}${a}`}'
new_C = 'function C(i){return`${window.location.protocol==="https:"?"https:":"http:"}//${window.location.host}/agent-server-proxy`}'
old_D = 'function $(i,t){if(!i)return null;const a=v(t),s=h(t);return`${window.location.protocol==="https:"?"wss:":"ws:"}//${a}${s}/sockets/events/${i}`}'
new_D = 'function $(i,t){if(!i)return null;return`${window.location.protocol==="https:"?"wss:":"ws:"}//${window.location.host}/agent-server-proxy/sockets/events/${i}`}'

ok = True
if old_C in src:
    src = src.replace(old_C, new_C, 1)
else:
    print('WARNING: C() pattern not found'); ok = False
if old_D in src:
    src = src.replace(old_D, new_D, 1)
else:
    print('WARNING: $() pattern not found'); ok = False

if ok:
    with open(path, 'w') as f:
        f.write(src)
    print('v1-svc.js 路由补丁已应用 ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_v1svc.py openhands-app-bridge:/tmp/bridge_patch_v1svc.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_v1svc.py

# ─────────────────────────────────────────────────────────────
# bridge-P5：should-render-event.js 还原为原版
# index.html FakeWS 全局 override window.WebSocket，BMHP.js 内的 new WebSocket(L) 自动被拦截。
# 原来往 BMHP.js 注入 EventSource 代码会产生 broken regex，被浏览器缓存为 immutable，已废弃。
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_sre.py << 'PYEOF'
import os, shutil

ASSETS = '/app/frontend/build/assets'
bmhp = os.path.join(ASSETS, 'should-render-event-D7h-BMHP.js')
bmhpx = os.path.join(ASSETS, 'should-render-event-D7h-BMHPx.js')

with open(bmhp) as f:
    src = f.read()

if 'EventSource' in src:
    print('WARNING: BMHP.js has EventSource injection - should be restored to original')
else:
    print('should-render-event.js 已是原版（无 FakeWS 注入）✓')
    if not os.path.exists(bmhpx) or open(bmhpx).read() != src:
        shutil.copy2(bmhp, bmhpx)
        print('BMHPx.js 已同步为原版 ✓')
    else:
        print('BMHPx.js 已是原版 ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_sre.py openhands-app-bridge:/tmp/bridge_patch_sre.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sre.py

# ─────────────────────────────────────────────────────────────
# bridge-P5b：cache busting — 重命名已修改的 JS 文件（bust proxy/browser immutable cache）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_cache_bust.py << 'PYEOF'
import os, shutil

ASSETS = '/app/frontend/build/assets'
INDEX  = '/app/frontend/build/index.html'

def copy_if_missing(src, dst, label):
    if os.path.exists(dst):
        print(f'{label} already exists ✓')
        return False
    shutil.copy2(src, dst)
    print(f'Copied {label}')
    return True

# Step 1: should-render-event-D7h-BMHP.js → BMHPx.js
sre_old = os.path.join(ASSETS, 'should-render-event-D7h-BMHP.js')
sre_new = os.path.join(ASSETS, 'should-render-event-D7h-BMHPx.js')
copy_if_missing(sre_old, sre_new, 'should-render-event-D7h-BMHPx.js')

# Step 2: update all files that reference old SRE name
sre_refs = [
    'conversation-uXvJtyCL.js', 'planner-tab-BB0IaNpo.js',
    'served-tab-Ath35J_c.js', 'shared-conversation-ly3fwRqE.js',
    'conversation-fHdubO7R.js', 'changes-tab-CXgkYeVu.js',
    'vscode-tab-CFaq3Fn-.js', 'manifest-8c9a7105.js',
]
for fname in sre_refs:
    p = os.path.join(ASSETS, fname)
    if not os.path.exists(p):
        continue
    with open(p) as f:
        src = f.read()
    if 'should-render-event-D7h-BMHP.js' in src and 'BMHPx' not in src:
        src = src.replace('should-render-event-D7h-BMHP.js', 'should-render-event-D7h-BMHPx.js')
        with open(p, 'w') as f:
            f.write(src)
        print(f'Updated SRE ref in {fname}')

# Step 3: conversation-fHdubO7R.js → Rx
conv_old = os.path.join(ASSETS, 'conversation-fHdubO7R.js')
conv_new = os.path.join(ASSETS, 'conversation-fHdubO7Rx.js')
copy_if_missing(conv_old, conv_new, 'conversation-fHdubO7Rx.js')

# Step 4: update manifest to reference new conversation file
mf = os.path.join(ASSETS, 'manifest-8c9a7105.js')
if os.path.exists(mf):
    with open(mf) as f:
        src = f.read()
    if 'conversation-fHdubO7R.js' in src:
        src = src.replace('conversation-fHdubO7R.js', 'conversation-fHdubO7Rx.js')
        with open(mf, 'w') as f:
            f.write(src)
        print('Updated conversation ref in manifest-8c9a7105.js')

# Step 5: manifest-8c9a7105.js → x
mf_new = os.path.join(ASSETS, 'manifest-8c9a7105x.js')
copy_if_missing(mf, mf_new, 'manifest-8c9a7105x.js')

# Step 6: update index.html to reference new manifest
with open(INDEX) as f:
    idx = f.read()
if 'manifest-8c9a7105.js' in idx:
    idx = idx.replace('manifest-8c9a7105.js', 'manifest-8c9a7105x.js')
    with open(INDEX, 'w') as f:
        f.write(idx)
    print('Updated manifest ref in index.html')
elif 'manifest-8c9a7105x.js' in idx:
    print('index.html already references manifest-8c9a7105x.js ✓')
else:
    print('WARNING: manifest not found in index.html')

# Step 7: z-suffix round — 为可能已被浏览器缓存为 immutable 的 x-suffix 文件创建全新 URL
conv_rx = os.path.join(ASSETS, 'conversation-fHdubO7Rx.js')
conv_rz = os.path.join(ASSETS, 'conversation-fHdubO7Rz.js')
mf_x = os.path.join(ASSETS, 'manifest-8c9a7105x.js')
mf_z = os.path.join(ASSETS, 'manifest-8c9a7105z.js')

if os.path.exists(conv_rx):
    shutil.copy2(conv_rx, conv_rz)
    print(f'Created conversation-fHdubO7Rz.js ✓')
else:
    print('WARNING: conversation-fHdubO7Rx.js not found, skipping z-rename')

if os.path.exists(mf_x):
    with open(mf_x) as f:
        mf_src = f.read()
    mf_src = mf_src.replace('conversation-fHdubO7Rx.js', 'conversation-fHdubO7Rz.js')
    with open(mf_z, 'w') as f:
        f.write(mf_src)
    print(f'Created manifest-8c9a7105z.js (refs Rz) ✓')

# Update index.html to reference manifest-z (supersedes manifest-x step above)
with open(INDEX) as f:
    idx = f.read()
if 'manifest-8c9a7105z.js' in idx:
    print('index.html already references manifest-z ✓')
elif 'manifest-8c9a7105x.js' in idx or 'manifest-8c9a7105.js' in idx:
    idx = idx.replace('manifest-8c9a7105x.js', 'manifest-8c9a7105z.js')
    idx = idx.replace('manifest-8c9a7105.js', 'manifest-8c9a7105z.js')
    with open(INDEX, 'w') as f:
        f.write(idx)
    print('Updated index.html: manifest → manifest-z ✓')

print('cache busting 完成 ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_cache_bust.py openhands-app-bridge:/tmp/bridge_patch_cache_bust.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_cache_bust.py

# ─────────────────────────────────────────────────────────────
# bridge-P6：app.py 路由注入
#   /api/proxy/events/{id}/stream — SSE（FakeWS EventSource 用）
#   /api/proxy/conversations/{id}/events — HTTP POST 格式转换后转发给 agent-server
#   两者都通过 _get_agent_server_url() 动态获取每个 conversation 的 agent-server URL
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_app.py << 'PYEOF'
import re as _re

with open('/app/openhands/server/app.py') as f:
    src = f.read()

if 'agent_server_proxy' in src and 'api/proxy/events' in src and '_convert_action_to_sdk_message_bridge' in src and 'heartbeat' in src:
    print('app.py 所有路由（含 heartbeat）已存在 ✓')
    exit(0)

# 注入 import
if 'agent_server_proxy' not in src:
    old_import = 'from openhands.server.routes.public import app as public_api_router'
    new_import = ('from openhands.server.routes.agent_server_proxy import agent_proxy_router\n'
                  'from openhands.server.routes.public import app as public_api_router')
    src = src.replace(old_import, new_import, 1)

    old_include = 'app.include_router(public_api_router)'
    new_include = 'app.include_router(agent_proxy_router)\napp.include_router(public_api_router)'
    src = src.replace(old_include, new_include, 1)
    print('app.py agent_proxy_router 已注入 ✓')
else:
    print('agent_proxy_router 已存在，跳过 ✓')

MARKER = 'app.include_router(agent_proxy_router)'
if MARKER not in src:
    print('WARNING: include_router(agent_proxy_router) not found in app.py')
    exit(1)

# 注入 /api/proxy/events SSE + send 路由（动态 URL + heartbeat）
if 'api/proxy/events' not in src or '_convert_action_to_sdk_message_bridge' not in src or 'heartbeat' not in src:
    # Remove old injection if present (missing heartbeat)
    if 'api/proxy/events' in src and 'heartbeat' not in src:
        src = _re.sub(
            r'\n@app\.get\("/api/proxy/events/\{conversation_id\}/stream".*?(?=\n@app\.|$)',
            '', src, flags=_re.DOTALL)
        src = _re.sub(
            r'\ndef _convert_action_to_sdk_message_bridge.*?(?=\n@app\.|$)',
            '', src, flags=_re.DOTALL)
        src = _re.sub(
            r'\n@app\.post\("/api/proxy/conversations/\{conversation_id\}/events".*?(?=\n@app\.|$)',
            '', src, flags=_re.DOTALL)
        print('旧路由已移除（补充 heartbeat）')

    new_routes = '''
@app.get("/api/proxy/events/{conversation_id}/stream", include_in_schema=False)
async def api_proxy_events_stream(request: Request, conversation_id: str):
    """SSE via /api/* - klogin只转发/api/*，此端点让浏览器收到V1实时事件。
    Bridge mode: uses _get_agent_server_url() to dynamically resolve per-conversation WS URL."""
    import websockets as _ws
    from starlette.responses import StreamingResponse as _SR
    from openhands.server.routes.agent_server_proxy import _get_agent_server_url, _to_ws
    params = dict(request.query_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    base_url = await _get_agent_server_url(conversation_id)
    ws_url = f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
    if qs:
        ws_url += f"?{qs}"
    async def _gen():
        import asyncio as _aio
        yield ":heartbeat\\n\\n"  # flush headers immediately (prevents BaseHTTPMiddleware cancel)
        first = True
        _base_qs = "&".join(f"{k}={v}" for k, v in params.items() if k != "resend_all")
        while True:
            try:
                _url = ws_url if first else f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
                if not first and _base_qs:
                    _url += f"?{_base_qs}"
                async with _ws.connect(_url) as ws:
                    if first:
                        yield "data: __connected__\\n\\n"
                        first = False
                    async for msg in ws:
                        data = msg if isinstance(msg, str) else msg.decode()
                        data = data.replace("\\n", "\\\\n")
                        yield f"data: {data}\\n\\n"
            except Exception:
                if first:
                    yield "data: __closed__\\n\\n"
                    return
            await _aio.sleep(1)
    return _SR(_gen(), media_type="text/event-stream",
               headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

def _convert_action_to_sdk_message_bridge(body: bytes) -> bytes:
    """Convert old OpenHands action format to agent-server v1.10.0-python SendMessageRequest format."""
    import json as _json
    try:
        data = _json.loads(body)
        if data.get("action") == "message" and "args" in data:
            content_str = data["args"].get("content", "")
            image_urls = data["args"].get("image_urls") or []
            content_items: list = [{"type": "text", "text": content_str}]
            for url in image_urls:
                content_items.append({"type": "image_url", "image_url": {"url": url}})
            return _json.dumps({
                "role": "user",
                "content": content_items,
                "run": True,
            }).encode()
    except Exception:
        pass
    return body

@app.post("/api/proxy/conversations/{conversation_id}/events", include_in_schema=False)
async def api_proxy_send_event(conversation_id: str, request: Request):
    # Bridge mode: convert action format + HTTP POST to per-conversation agent-server URL.
    from openhands.server.routes.agent_server_proxy import _get_agent_server_url
    body = await request.body()
    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")
    send_body = _convert_action_to_sdk_message_bridge(body)
    base_url = await _get_agent_server_url(conversation_id)
    url = f"{base_url}/api/conversations/{conversation_id}/events"
    headers = {"Content-Type": "application/json"}
    if key:
        headers["X-Session-API-Key"] = key
    try:
        import httpx as _httpx
        async with _httpx.AsyncClient(timeout=60.0) as client:
            await client.post(url, content=send_body, headers=headers)
    except Exception:
        pass
    return JSONResponse({"success": True})

'''
    src = src.replace(MARKER, MARKER + '\n' + new_routes, 1)
    print('api/proxy/events 路由（含 heartbeat + 动态 URL）已注入 ✓')
else:
    print('api/proxy/events 路由已存在 ✓')

with open('/app/openhands/server/app.py', 'w') as f:
    f.write(src)
PYEOF

sudo docker cp /tmp/bridge_patch_app.py openhands-app-bridge:/tmp/bridge_patch_app.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_app.py

# ─────────────────────────────────────────────────────────────
# bridge-P7：index.html FakeWS（最可靠，bypass klogin asset 缓存）
# ─────────────────────────────────────────────────────────────
sudo docker cp openhands-app-bridge:/app/frontend/build/index.html /tmp/bridge-index.html
sudo chmod 666 /tmp/bridge-index.html

python3 << 'PYEOF'
import re
with open('/tmp/bridge-index.html') as f:
    html = f.read()

# 清除旧注入
if 'FakeWS' in html:
    html = re.sub(r'<script>\(function\(\)\{[^<]*FakeWS[^<]*\}\)\(\);</script>', '', html, flags=re.DOTALL)
    print('旧 FakeWS 已移除')

inject = (
    '<script>(function(){'
    'var _f=window.fetch;window.fetch=function(u,o){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1")>=0&&u.indexOf(":80")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:\\d+/,"/agent-server-proxy");}'
    'return _f.call(this,u,o);};'
    'var _X=window.XMLHttpRequest.prototype.open;'
    'window.XMLHttpRequest.prototype.open=function(m,u){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1")>=0&&u.indexOf(":80")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:\\d+/,"/agent-server-proxy");}'
    'return _X.apply(this,arguments);};'
    'var _WS=window.WebSocket;'
    'function FakeWS(url,proto){'
    'var self=this;self.readyState=0;self.onopen=null;self.onmessage=null;self.onclose=null;self.onerror=null;self._es=null;'
    'var m=url.match(/\\/sockets\\/events\\/([^?]+)/);'
    'var id=m?m[1]:"";'
    'var queryStr=url.indexOf("?")>=0?url.split("?")[1]:"";'
    'var params=new URLSearchParams(queryStr);'
    'var key=params.get("session_api_key")||"";'
    'var sseUrl="/api/proxy/events/"+id+"/stream?resend_all=true";'
    'if(key)sseUrl+="&session_api_key="+encodeURIComponent(key);'
    'self.send=function(d){'
    'fetch("/api/proxy/conversations/"+id+"/events",'
    '{method:"POST",headers:{"Content-Type":"application/json","X-Session-API-Key":key},body:d})'
    '.catch(function(){});};'
    'self.close=function(){'
    'if(self._es){self._es.close();self._es=null;}'
    'self.readyState=3;if(self.onclose)self.onclose({code:1000,reason:"",wasClean:true});};'
    'var es=new EventSource(sseUrl);self._es=es;'
    'es.onopen=function(){self.readyState=1;if(self.onopen)self.onopen({});};'
    'es.onmessage=function(ev){'
    'if(ev.data==="__connected__")return;'
    'if(ev.data==="__closed__"){self.readyState=3;if(self.onclose)self.onclose({code:1000,wasClean:true});return;}'
    'if(self.onmessage)self.onmessage({data:ev.data});};'
    'es.onerror=function(){'
    'if(self._es){self._es.close();self._es=null;}'
    'self.readyState=3;if(self.onerror)self.onerror({});'
    'if(self.onclose)self.onclose({code:1006,reason:"",wasClean:false});};}'
    'FakeWS.CONNECTING=0;FakeWS.OPEN=1;FakeWS.CLOSING=2;FakeWS.CLOSED=3;'
    'window.WebSocket=function(url,proto){'
    'if(url&&url.indexOf("/sockets/events/")>=0){return new FakeWS(url,proto);}'
    'return new _WS(url,proto);};'
    'window.WebSocket.prototype=_WS.prototype;'
    'window.WebSocket.CONNECTING=0;window.WebSocket.OPEN=1;window.WebSocket.CLOSING=2;window.WebSocket.CLOSED=3;'
    '})();</script>'
)
html = html.replace('<head>', '<head>' + inject, 1)
with open('/tmp/bridge-index.html', 'w') as f:
    f.write(html)
print('index.html FakeWS 已注入 ✓')
PYEOF

sudo docker cp /tmp/bridge-index.html openhands-app-bridge:/app/frontend/build/index.html

# ─────────────────────────────────────────────────────────────
# bridge-P8：per-conversation workspace 隔离
# Bridge mode 每会话已有独立 sandbox 容器，但 working_dir 仍需隔离。
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_per_conv_workspace.py << 'PYEOF'
path = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(path) as f:
    src = f.read()

if 'per-conversation workspace isolation' in src:
    print('per-conversation workspace 补丁已存在 ✓')
    exit(0)

old_block = '''            assert sandbox_spec is not None

            # Run setup scripts
            remote_workspace = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=sandbox_spec.working_dir,
            )'''

new_block = '''            assert sandbox_spec is not None

            # --- per-conversation workspace isolation ---
            conv_working_dir = f"{sandbox_spec.working_dir}/{task.id.hex}"
            _tmp_ws = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=sandbox_spec.working_dir,
            )
            await _tmp_ws.execute_command(
                f"mkdir -p {conv_working_dir} && cd {conv_working_dir} && "
                f"[ -d .git ] || git init",
                timeout=10.0,
            )
            # --- end per-conversation workspace isolation ---

            # Run setup scripts
            remote_workspace = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=conv_working_dir,
            )'''

if old_block not in src:
    print('WARNING: 第一段 pattern 未匹配，跳过')
    exit(1)
src = src.replace(old_block, new_block, 1)

old_build = '                    sandbox_spec.working_dir,'
new_build = '                    conv_working_dir,  # per-conversation isolated dir'

if old_build in src:
    src = src.replace(old_build, new_build, 1)
else:
    print('WARNING: sandbox_spec.working_dir in _build 未匹配')

with open(path, 'w') as f:
    f.write(src)
print('per-conversation workspace 补丁已应用 ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_per_conv_workspace.py openhands-app-bridge:/tmp/bridge_patch_per_conv_workspace.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_per_conv_workspace.py

# ─────────────────────────────────────────────────────────────
# bridge-P9：sandbox port proxy（Code/App tab 浏览器访问）
# VSCode (8001), App 预览 (8011/8012) 的 URL 是 http://127.0.0.1:{port}，
# 在 openhands-app-bridge 注入 /api/sandbox-port/{port}/* 代理路由。
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_sandbox_port_proxy.py << 'PYEOF'
"""Patch 9: Add /api/sandbox-port/{port}/{path} reverse proxy for VSCode/App tabs."""
path = '/app/openhands/server/app.py'
with open(path) as f:
    src = f.read()

if 'sandbox-port' in src:
    print('sandbox-port 代理路由已存在 ✓')
    exit(0)

MARKER = 'app.include_router(agent_proxy_router)'
if MARKER not in src:
    print('WARNING: include_router(agent_proxy_router) not found in app.py')
    exit(1)

PROXY_ROUTES = '''

# --- Sandbox port proxy: VSCode (8001), App (8011/8012) ---
from fastapi import WebSocket as _FastAPIWebSocket
@app.api_route("/api/sandbox-port/{port}/{path:path}", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"], include_in_schema=False)
async def sandbox_port_proxy(port: int, path: str, request: Request):
    """Reverse proxy any sandbox port through openhands-app-bridge (port 3002)."""
    import httpx as _hx, re as _re
    target = f"http://127.0.0.1:{port}/{path}"
    qs = str(request.query_params)
    if qs:
        target += f"?{qs}"
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")}
    body = await request.body()
    proxy_base = f"/api/sandbox-port/{port}"
    try:
        async with _hx.AsyncClient(timeout=60.0, follow_redirects=False) as client:
            resp = await client.request(
                method=request.method, url=target, headers=headers, content=body)
            resp_headers = {}
            for k, v in resp.headers.multi_items():
                if k.lower() in ("content-encoding", "transfer-encoding", "connection",
                                  "content-security-policy"):
                    continue
                if k.lower() == "location":
                    if v.startswith("http://127.0.0.1") or v.startswith("http://localhost"):
                        v = _re.sub(r"https?://[^/]+", proxy_base, v, count=1)
                    elif v.startswith("/") and not v.startswith(proxy_base):
                        v = proxy_base + v
                resp_headers[k] = v
            content = resp.content
            ct = resp.headers.get("content-type", "")
            if "text/html" in ct and content:
                try:
                    html = content.decode("utf-8")
                    def _rewrite_abs(m):
                        attr, url = m.group(1), m.group(2)
                        if url.startswith(proxy_base):
                            return m.group(0)
                        return attr + proxy_base + url
                    html = _re.sub(
                        r"""((?:src|href|action)=["'])(/[^/"'#][^"']*)""",
                        _rewrite_abs, html)
                    html = html.replace(
                        "&quot;serverBasePath&quot;:&quot;/&quot;",
                        "&quot;serverBasePath&quot;:&quot;" + proxy_base + "/&quot;")
                    html = _re.sub(
                        r"(new URL\(')(/stable-[^']+)(')",
                        lambda m: m.group(1) + proxy_base + m.group(2) + m.group(3), html)
                    html = _re.sub(
                        r"&quot;remoteAuthority&quot;:&quot;[^&]*&quot;",
                        "&quot;remoteAuthority&quot;:&quot;&quot;", html)
                    content = html.encode("utf-8")
                except Exception:
                    pass
            from starlette.responses import Response as _Resp
            return _Resp(content=content, status_code=resp.status_code,
                        headers=resp_headers, media_type=ct or resp.headers.get("content-type"))
    except Exception as e:
        from starlette.responses import Response as _Resp
        return _Resp(content=str(e), status_code=502)

@app.api_route("/api/sandbox-port/{port}/", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"], include_in_schema=False)
async def sandbox_port_proxy_root(port: int, request: Request):
    """Root path variant for sandbox port proxy."""
    return await sandbox_port_proxy(port, "", request)

@app.websocket("/api/sandbox-port/{port}/{path:path}")
async def sandbox_port_ws_proxy(port: int, path: str, websocket: _FastAPIWebSocket):
    """WebSocket proxy for sandbox ports (VSCode needs WS for language server)."""
    import websockets as _ws
    await websocket.accept()
    qs = str(websocket.query_params)
    ws_url = f"ws://127.0.0.1:{port}/{path}"
    if qs:
        ws_url += f"?{qs}"
    try:
        async with _ws.connect(ws_url) as target_ws:
            import asyncio
            async def client_to_target():
                try:
                    while True:
                        data = await websocket.receive()
                        if "text" in data:
                            await target_ws.send(data["text"])
                        elif "bytes" in data and data["bytes"]:
                            await target_ws.send(data["bytes"])
                except Exception:
                    pass
            async def target_to_client():
                try:
                    async for msg in target_ws:
                        if isinstance(msg, bytes):
                            await websocket.send_bytes(msg)
                        else:
                            await websocket.send_text(msg)
                except Exception:
                    pass
            done, pending = await asyncio.wait(
                [asyncio.create_task(client_to_target()),
                 asyncio.create_task(target_to_client())],
                return_when=asyncio.FIRST_COMPLETED)
            for t in pending:
                t.cancel()
    except Exception:
        pass
    finally:
        try:
            await websocket.close()
        except Exception:
            pass
# --- End sandbox port proxy ---
'''

src = src.replace(MARKER, MARKER + PROXY_ROUTES, 1)
with open(path, 'w') as f:
    f.write(src)
print('sandbox-port 代理路由已注入 ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_sandbox_port_proxy.py openhands-app-bridge:/tmp/bridge_patch_sandbox_port_proxy.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sandbox_port_proxy.py

# ─────────────────────────────────────────────────────────────
# bridge-P10：exposed_urls 代理路径重写（VSCODE/WORKER → /api/sandbox-port/）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_sandbox_exposed_urls.py << 'PYEOF'
"""Patch 10: Rewrite VSCODE/WORKER exposed_urls to use /api/sandbox-port/{port} proxy path.
AGENT_SERVER URL must remain absolute (used internally for health checks)."""
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '/api/sandbox-port/' in src:
    print('exposed_urls 代理路径补丁已存在 ✓')
    exit(0)

old_return = '''        return SandboxInfo(
            id=container.name,
            created_by_user_id=None,
            sandbox_spec_id=container.image.tags[0],
            status=status,
            session_api_key=session_api_key,
            exposed_urls=exposed_urls,'''

new_return = '''        # Rewrite VSCODE/WORKER URLs to use proxy (AGENT_SERVER stays absolute for health checks)
        if exposed_urls:
            for _eu in exposed_urls:
                if _eu.name != 'AGENT_SERVER':
                    import re as _re
                    _eu.url = _re.sub(r'https?://[^/]+', f'/api/sandbox-port/{_eu.port}', _eu.url, count=1)

        return SandboxInfo(
            id=container.name,
            created_by_user_id=None,
            sandbox_spec_id=container.image.tags[0],
            status=status,
            session_api_key=session_api_key,
            exposed_urls=exposed_urls,'''

if old_return not in src:
    print('WARNING: return SandboxInfo pattern 未匹配')
    exit(1)

src = src.replace(old_return, new_return, 1)
with open(path, 'w') as f:
    f.write(src)
print('exposed_urls 代理路径补丁已应用（保留 AGENT_SERVER 不变）✓')
PYEOF
sudo docker cp /tmp/bridge_patch_sandbox_exposed_urls.py openhands-app-bridge:/tmp/bridge_patch_sandbox_exposed_urls.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sandbox_exposed_urls.py

# ─────────────────────────────────────────────────────────────
# bridge-P11：vscode-tab JS 修复 + z-suffix cache busting
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_vscode_tab.py << 'PYEOF'
import os, shutil, re

ASSETS = '/app/frontend/build/assets'

# 1. Fix vscode-tab JS files (both - and x suffix)
OLD_URL = 'if(r?.url)try{const f=new URL(r.url).protocol'
NEW_URL = 'if(r?.url)try{const f=new URL(r.url,window.location.origin).protocol'

for fname in ['vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-x.js']:
    p = os.path.join(ASSETS, fname)
    if not os.path.exists(p):
        print(f'{fname}: not found, skipping')
        continue
    with open(p) as f:
        src = f.read()
    if NEW_URL in src:
        print(f'{fname}: already patched ✓')
    elif OLD_URL in src:
        src = src.replace(OLD_URL, NEW_URL, 1)
        with open(p, 'w') as f:
            f.write(src)
        print(f'{fname}: URL parse fix applied ✓')
    else:
        print(f'{fname}: WARNING pattern not found')

# 2. Create vscode-tab-CFaq3Fn-z.js from patched original (prefer x if exists)
src_x = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-x.js')
src_orig = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-.js')
dst_z = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-z.js')
vt_src = src_x if os.path.exists(src_x) else src_orig
if os.path.exists(vt_src):
    shutil.copy2(vt_src, dst_z)
    print(f'Created vscode-tab-CFaq3Fn-z.js (from {os.path.basename(vt_src)}) ✓')
else:
    print('WARNING: no vscode-tab source found')

# 3. Determine uXvJtyCL source (prefer x if exists, fall back to plain)
conv_x    = os.path.join(ASSETS, 'conversation-uXvJtyCLx.js')
conv_orig = os.path.join(ASSETS, 'conversation-uXvJtyCL.js')
conv_src  = conv_x if os.path.exists(conv_x) else conv_orig

# 4. Create conversation-uXvJtyCLz.js (copy of best available source)
conv_z = os.path.join(ASSETS, 'conversation-uXvJtyCLz.js')
if os.path.exists(conv_src):
    shutil.copy2(conv_src, conv_z)
    print(f'Created conversation-uXvJtyCLz.js (from {os.path.basename(conv_src)}) ✓')
else:
    print('WARNING: no conversation-uXvJtyCL source found')

# 5. Update uXvJtyCLz.js to reference vscode-tab-z (replace all vscode-tab- variants)
if os.path.exists(conv_z):
    with open(conv_z) as f:
        csrc = f.read()
    if 'vscode-tab-CFaq3Fn-z.js' not in csrc:
        csrc2 = csrc.replace('vscode-tab-CFaq3Fn-x.js', 'vscode-tab-CFaq3Fn-z.js')
        csrc2 = csrc2.replace('vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-z.js')
        with open(conv_z, 'w') as f:
            f.write(csrc2)
        print('Updated uXvJtyCLz.js: vscode-tab → vscode-tab-z ✓')
    else:
        print('uXvJtyCLz.js already refs vscode-tab-z ✓')

# 6. Update conversation-fHdubO7Rz.js to import uXvJtyCLz
conv_rz = os.path.join(ASSETS, 'conversation-fHdubO7Rz.js')
if os.path.exists(conv_rz):
    with open(conv_rz) as f:
        rzc = f.read()
    if 'uXvJtyCLz' not in rzc:
        rzc2 = rzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        rzc2 = rzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if rzc2 != rzc:
            with open(conv_rz, 'w') as f:
                f.write(rzc2)
            print('Updated conversation-fHdubO7Rz.js → uXvJtyCLz ✓')
    else:
        print('fHdubO7Rz already refs uXvJtyCLz ✓')

# 7. Update manifest-z to reference uXvJtyCLz (for modulepreload hints)
mz = os.path.join(ASSETS, 'manifest-8c9a7105z.js')
if os.path.exists(mz):
    with open(mz) as f:
        mzc = f.read()
    if 'uXvJtyCLz' not in mzc:
        mzc2 = mzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        mzc2 = mzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if mzc2 != mzc:
            with open(mz, 'w') as f:
                f.write(mzc2)
            print('Updated manifest-z → uXvJtyCLz ✓')
    else:
        print('manifest-z already refs uXvJtyCLz ✓')

print('Chain: manifest-z → fHdubO7Rz → uXvJtyCLz → BMHPx + vscode-tab-z ✓')
PYEOF
sudo docker cp /tmp/bridge_patch_vscode_tab.py openhands-app-bridge:/tmp/bridge_patch_vscode_tab.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_vscode_tab.py

# ─────────────────────────────────────────────────────────────
# 重启 openhands-app-bridge 使所有 Python 补丁生效
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 重启 openhands-app-bridge..."
sudo docker restart openhands-app-bridge
for i in $(seq 1 30); do
    sudo docker logs openhands-app-bridge 2>&1 | grep -q "Uvicorn running" && echo "重启完成 ✓" && break
    sleep 2
done

# 重启后重新应用 JS 补丁（docker restart 保留 writable layer，做一次确认）
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_TMP=/tmp/bridge-${JS_ASSET}
    sudo docker cp openhands-app-bridge:/app/frontend/build/assets/${JS_ASSET} $JS_TMP 2>/dev/null || continue
    sudo chmod 666 $JS_TMP
    grep -q 'polling.*websocket' $JS_TMP 2>/dev/null || {
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_TMP
        sudo docker cp $JS_TMP openhands-app-bridge:/app/frontend/build/assets/${JS_ASSET}
        echo "重启后重新注入 polling: ${JS_ASSET}"
    }
done
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch1_prefix.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_rate_limiter.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_cache_control.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_v1svc.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sre.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_cache_bust.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_app.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_per_conv_workspace.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sandbox_port_proxy.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sandbox_exposed_urls.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_vscode_tab.py

# 重新注入 index.html FakeWS
sudo docker cp openhands-app-bridge:/app/frontend/build/index.html /tmp/bridge-index.html 2>/dev/null
sudo chmod 666 /tmp/bridge-index.html 2>/dev/null
python3 << 'PYEOF'
import re
with open('/tmp/bridge-index.html') as f:
    html = f.read()
if 'FakeWS' in html:
    print('index.html FakeWS 已存在（重启后保留）✓')
else:
    print('WARNING: FakeWS 丢失，请手动重新注入')
PYEOF

REMOTE

# ─────────────────────────────────────────────────────────────
# 配置 klogin ingress（bridge 独立入口，端口 3002）
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 配置 klogin ingress (openhands-bridge, port 3002)..."
klogin instances update "$INSTANCE_ID" --static-ip 2>/dev/null && echo "静态 IP 已设置 ✓" || echo "静态 IP 已存在或设置失败（可忽略）"
klogin ingresses create openhands-bridge --instance "$INSTANCE_ID" --port 3002 --access-control=false 2>/dev/null \
  && echo "ingress openhands-bridge 创建成功 ✓" \
  || echo "ingress 已存在或创建失败（可忽略，域名: https://openhands-bridge.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com）"

# ─────────────────────────────────────────────────────────────
# 本地 SSH 隧道（端口 3002，独立于主实例的 3001）
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 建立本地 SSH 隧道（3002 → 3002）..."
pkill -f "ssh.*-L 3002.*$INSTANCE_ID" 2>/dev/null || true
sleep 1
ssh -f -N -L 3002:127.0.0.1:3002 "$INSTANCE_ID"
sleep 2

# ─────────────────────────────────────────────────────────────
# 验证
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 验证..."

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/api/options/models)
[ "$HTTP_CODE" = "200" ] && echo "API 连通 (3002) ✓" || echo "警告: API 返回 $HTTP_CODE"

PROXY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/agent-server-proxy/health)
[ "$PROXY_CODE" = "200" ] && echo "agent-server-proxy 连通 ✓" || echo "注意: 代理返回 $PROXY_CODE（sandbox 未启动时正常）"

SPORT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:3002/api/sandbox-port/8001/")
echo "sandbox port proxy 路由: HTTP $SPORT_CODE（502 正常，需等 sandbox 启动）"

echo ""
echo ">>> 创建测试 V1 会话（触发 sandbox 启动）..."
CONV_RESP=$(curl -s -X POST http://localhost:3002/api/v1/app-conversations \
  -H 'Content-Type: application/json' \
  -d '{"initial_user_msg": "hello from bridge mode"}')
CONV_ID=$(echo "$CONV_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

if [ -z "$CONV_ID" ]; then
    echo "警告: V1 会话创建失败: $CONV_RESP"
else
    echo "V1 会话已创建: ${CONV_ID:0:12}... ✓"
    echo "等待 sandbox 就绪（bridge 模式首次启动需拉取镜像，约60-120s）..."
    for i in $(seq 1 60); do
        STATUS=$(curl -s "http://localhost:3002/api/conversations/$CONV_ID" | \
          python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''), d.get('runtime_status',''))" 2>/dev/null || true)
        if echo "$STATUS" | grep -q "RUNNING.*READY"; then
            echo "Sandbox 就绪 ✓ 验证动态 URL 路由..."

            # 验证 DB 中记录了独立的 agent_server_url
            ssh "$INSTANCE_ID" "sudo docker exec openhands-app-bridge python3 -c \"
import sqlite3
conn = sqlite3.connect('/.openhands/openhands.db')
cur = conn.cursor()
cur.execute('SELECT app_conversation_id, sandbox_id, agent_server_url FROM app_conversation_start_task ORDER BY created_at DESC LIMIT 3')
for r in cur.fetchall():
    print(f'conv={str(r[0])[:12]}... sandbox={str(r[1])[:15] if r[1] else None}... url={r[2]}')
conn.close()
\"" 2>/dev/null

            # 验证正在运行的 bridge sandbox 容器
            ssh "$INSTANCE_ID" "sudo docker ps --filter name=oh-bridge- --format '{{.Names}} {{.Ports}} {{.Status}}'" 2>/dev/null

            # 验证 SSE 事件流
            API_KEY=$(curl -s "http://localhost:3002/api/conversations/$CONV_ID" | \
              python3 -c "import sys,json; print(json.load(sys.stdin).get('session_api_key',''))" 2>/dev/null || true)
            if [ -n "$API_KEY" ]; then
                SSE_FIRST=$(curl -s -N --max-time 5 \
                  -H 'Accept: text/event-stream' \
                  "http://localhost:3002/api/proxy/events/$CONV_ID/stream?resend_all=true&session_api_key=$API_KEY" \
                  2>/dev/null | head -3)
                if echo "$SSE_FIRST" | grep -q '__connected__\|full_state'; then
                    echo "SSE 事件流正常 ✓（浏览器 V1 会话将显示 Connected）"
                else
                    echo "注意: SSE 响应: $SSE_FIRST"
                fi
            fi
            break
        fi
        [ "$i" -eq 60 ] && echo "警告: 120s 内未就绪，当前: $STATUS"
        sleep 2
    done
fi

echo ""
echo "========================================"
echo "✓ Bridge Mode 部署完成！所有补丁已应用："
echo "  - bridge-P1:  sandbox 前缀 oh-bridge-（与主实例隔离）"
echo "  - bridge-P2:  动态 agent_server_proxy（每会话独立 agent-server URL）"
echo "  - bridge-P2b: rate limiter 修复（SSE 排除 + X-Forwarded-For）"
echo "  - bridge-P2c: CacheControlMiddleware no-cache（防 immutable 缓存 JS 补丁）"
echo "  - bridge-P3:  socket.io polling 回退（V0 会话）"
echo "  - bridge-P4:  v1-svc.js 路由 → /agent-server-proxy"
echo "  - bridge-P5:  BMHP.js 还原原版（FakeWS 全局 override，无需修改 BMHP.js）"
echo "  - bridge-P5b: cache-bust x/z suffix（bypass 浏览器 immutable 缓存）"
echo "  - bridge-P6:  app.py 路由（SSE heartbeat + 动态 URL + 格式转换）"
echo "  - bridge-P7:  index.html FakeWS（WebSocket→EventSource→/api/proxy/events）"
echo "  - bridge-P8:  per-conversation workspace 隔离"
echo "  - bridge-P9:  sandbox port proxy（Code/App tab 访问，CSP stripped）"
echo "  - bridge-P10: exposed_urls 代理路径重写（VSCODE/WORKER → /api/sandbox-port/）"
echo "  - bridge-P11: vscode-tab URL parse fix + z-suffix cache busting"
echo ""
echo "访问方式（独立于主实例）:"
echo "  本地隧道: http://localhost:3002"
echo "  域名:     https://openhands-bridge.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com"
echo ""
echo "与主实例对比:"
echo "  主实例 (sandbox 复用): http://localhost:3001 — oh-agent-server-* 容器"
echo "  本实例 (bridge 独立):  http://localhost:3002 — oh-bridge-* 容器（每会话独立）"
echo "========================================"
