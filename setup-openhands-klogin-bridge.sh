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
# 3. 补丁1：修改 sandbox 容器名前缀（oh-bridge-，避免与主实例冲突）
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch1_prefix.py << 'PYEOF'
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if "container_name_prefix: str = 'oh-bridge-'" in src:
    print('prefix 补丁已存在 ✓')
    exit(0)

# 改 DockerSandboxServiceInjector 的默认前缀
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
# 4. 补丁2：动态 agent_server_proxy.py
#    根据 conversation_id 从 DB 查 agent_server_url（每个 sandbox 不同端口）
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

# ─────────────────────────────────────────────────────────────
# 5. 补丁3：app.py 路由注入
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_app.py << 'PYEOF'
with open('/app/openhands/server/app.py') as f:
    src = f.read()

if 'agent_server_proxy' in src and 'api/proxy/events' in src and '_convert_action_to_sdk_message_bridge' in src:
    print('app.py 所有路由已存在 ✓')
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

# 注入 /api/proxy/events SSE + send 路由
if 'api/proxy/events' not in src or '_convert_action_to_sdk_message_bridge' not in src:
    MARKER = 'app.include_router(agent_proxy_router)'
    new_routes = '''
@app.get("/api/proxy/events/{conversation_id}/stream", include_in_schema=False)
async def api_proxy_events_stream(request: Request, conversation_id: str):
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
        first = True
        _base_qs = qs.replace('resend_all=true&', '').replace('&resend_all=true', '').replace('resend_all=true', '')
        while True:
            try:
                _url = ws_url if first else f"{_to_ws(base_url)}/sockets/events/{conversation_id}"
                if not first and _base_qs:
                    _url += f'?{_base_qs}'
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
    # Convert old OpenHands action format to SDK SendMessageRequest, then HTTP POST to agent-server.
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
    print('api/proxy/events 路由已注入 ✓')
else:
    print('api/proxy/events 路由已存在 ✓')

with open('/app/openhands/server/app.py', 'w') as f:
    f.write(src)
PYEOF

sudo docker cp /tmp/bridge_agent_server_proxy.py openhands-app-bridge:/app/openhands/server/routes/agent_server_proxy.py
sudo docker cp /tmp/bridge_patch_app.py openhands-app-bridge:/tmp/bridge_patch_app.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_app.py

# ─────────────────────────────────────────────────────────────
# 6. 补丁4：socket.io polling（V0 Disconnected）
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
# 7. 补丁5：v1-conversation-service.js 路由改走 /agent-server-proxy
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
# 8. 补丁6：should-render-event.js WS→SSE
# ─────────────────────────────────────────────────────────────
cat > /tmp/bridge_patch_sre.py << 'PYEOF'
path = '/app/frontend/build/assets/should-render-event-D7h-BMHP.js'
with open(path) as f:
    src = f.read()

if 'EventSource' in src:
    print('should-render-event.js SSE 补丁已存在 ✓')
    exit(0)

B = chr(92)
old_ws = 'const O=new WebSocket(L);'
new_ws = (
    'const _m=L.match(/' + B + '/sockets' + B + '/events' + B + '/([^?]+)(?:' + B + '?(.*))?/);'
    'const _id=_m?_m[1]:"";'
    'const _key=(new URLSearchParams(_m&&_m[2]?_m[2]:"")).get("session_api_key")||"";'
    'const _su=L.replace(/^ws:/,"http:").replace(/^wss:/,"https:")'
    '.replace(/(/' + B + '/sockets' + B + '/events' + B + '/[^?]+)/,"$1/sse");'
    'const O={'
    'readyState:0,onopen:null,onmessage:null,onclose:null,onerror:null,_es:null,'
    'send:function(d){'
    'fetch("/agent-server-proxy/api/conversations/"+_id+"/events",'
    '{method:"POST",headers:{"Content-Type":"application/json","X-Session-API-Key":_key},body:d})'
    '.catch(function(){});'
    '},'
    'close:function(){'
    'if(O._es){O._es.close();O._es=null;}'
    'O.readyState=3;'
    'if(O.onclose)O.onclose({code:1000,reason:"",wasClean:true});'
    '}'
    '};'
    'const _es=new EventSource(_su);O._es=_es;'
    '_es.addEventListener("open",function(){O.readyState=1;if(O.onopen)O.onopen({})});'
    '_es.addEventListener("message",function(ev){'
    'if(ev.data==="__connected__")return;'
    'if(ev.data==="__closed__"){O.readyState=3;if(O.onclose)O.onclose({code:1000,wasClean:true});return;}'
    'if(O.onmessage)O.onmessage({data:ev.data});'
    '});'
    '_es.addEventListener("error",function(){'
    'if(O._es){O._es.close();O._es=null;}'
    'O.readyState=3;if(O.onerror)O.onerror({});'
    'if(O.onclose)O.onclose({code:1006,reason:"",wasClean:false});'
    '});'
)

if old_ws in src:
    src = src.replace(old_ws, new_ws, 1)
    with open(path, 'w') as f:
        f.write(src)
    print('should-render-event.js SSE 补丁已应用 ✓')
else:
    print('WARNING: WebSocket pattern not found')
PYEOF
sudo docker cp /tmp/bridge_patch_sre.py openhands-app-bridge:/tmp/bridge_patch_sre.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sre.py

# ─────────────────────────────────────────────────────────────
# 9. 补丁7：index.html FakeWS（最可靠，bypass klogin asset 缓存）
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
    # fetch 拦截：127.0.0.1:8000 → /agent-server-proxy
    'var _f=window.fetch;window.fetch=function(u,o){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1")>=0&&u.indexOf(":80")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:\\d+/,"/agent-server-proxy");}'
    'return _f.call(this,u,o);};'
    # XHR 拦截
    'var _X=window.XMLHttpRequest.prototype.open;'
    'window.XMLHttpRequest.prototype.open=function(m,u){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1")>=0&&u.indexOf(":80")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:\\d+/,"/agent-server-proxy");}'
    'return _X.apply(this,arguments);};'
    # FakeWS：/sockets/events/ → EventSource（SSE）
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
# 10. 重启 bridge 容器使所有 Python 补丁生效
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 重启 openhands-app-bridge..."
sudo docker restart openhands-app-bridge
for i in $(seq 1 30); do
    sudo docker logs openhands-app-bridge 2>&1 | grep -q "Uvicorn running" && echo "重启完成 ✓" && break
    sleep 2
done

# 重启后重新注入 JS（docker restart 保留 writable layer，做一次确认）
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
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_v1svc.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_sre.py
sudo docker exec openhands-app-bridge python3 /tmp/bridge_patch_app.py

# 重新注入 index.html
sudo docker cp openhands-app-bridge:/app/frontend/build/index.html /tmp/bridge-index.html 2>/dev/null
sudo chmod 666 /tmp/bridge-index.html 2>/dev/null
python3 << 'PYEOF'
import re
with open('/tmp/bridge-index.html') as f: html = f.read()
if 'FakeWS' in html:
    print('index.html FakeWS 已存在（重启后保留）✓')
else:
    print('WARNING: FakeWS 丢失，请手动重新注入')
PYEOF

REMOTE

# ─────────────────────────────────────────────────────────────
# 11. 本地 SSH 隧道（端口 3002，独立于主实例的 3001）
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 建立本地 SSH 隧道（3002 → 3002）..."
pkill -f "ssh.*-L 3002.*$INSTANCE_ID" 2>/dev/null || true
sleep 1
ssh -f -N -L 3002:127.0.0.1:3002 "$INSTANCE_ID"
sleep 2

# ─────────────────────────────────────────────────────────────
# 12. 验证
# ─────────────────────────────────────────────────────────────
echo ""
echo ">>> 验证..."

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/api/options/models)
[ "$HTTP_CODE" = "200" ] && echo "API 连通 (3002) ✓" || echo "警告: API 返回 $HTTP_CODE"

PROXY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3002/agent-server-proxy/health)
[ "$PROXY_CODE" = "200" ] && echo "agent-server-proxy 连通 ✓" || echo "注意: 代理返回 $PROXY_CODE（sandbox 未启动时正常）"

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
            echo "Sandbox 就绪 ✓ 验证 DB 路由..."

            # 验证 DB 中记录了独立的 agent_server_url
            ssh "$INSTANCE_ID" "sudo docker exec openhands-app-bridge python3 -c \"
import sqlite3
conn = sqlite3.connect('/.openhands/openhands.db')
cur = conn.cursor()
cur.execute('SELECT app_conversation_id, sandbox_id, agent_server_url FROM app_conversation_start_task ORDER BY created_at DESC LIMIT 3')
for r in cur.fetchall():
    print(f'conv={str(r[0])[:12]}... sandbox={str(r[1])[:15]}... url={r[2]}')
conn.close()
\"" 2>/dev/null

            # 验证正在运行的 bridge sandbox 容器
            ssh "$INSTANCE_ID" "sudo docker ps --filter name=oh-bridge- --format '{{.Names}} {{.Ports}} {{.Status}}'" 2>/dev/null
            break
        fi
        [ "$i" -eq 60 ] && echo "警告: 120s 内未就绪，当前: $STATUS"
        sleep 2
    done
fi

echo ""
echo "========================================"
echo "✓ Bridge Mode 部署完成！"
echo ""
echo "访问方式（独立于主实例）:"
echo "  本地隧道: http://localhost:3002"
echo "  域名:     https://openhands.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com"
echo "            （域名只转发到 port 3000，用隧道访问 3002）"
echo ""
echo "与主实例对比:"
echo "  主实例 (sandbox 复用): http://localhost:3001 — oh-agent-server-* 容器"
echo "  本实例 (bridge 独立):  http://localhost:3002 — oh-bridge-* 容器"
echo ""
echo "回滚到主实例方案: git checkout v1-sandbox-reuse -- setup-openhands-klogin.sh"
echo "========================================"
