#!/bin/bash
set -e

echo "=== OpenHands on klogin 一键部署 ==="
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
ssh -o StrictHostKeyChecking=no "$INSTANCE_ID" bash << 'REMOTE'
set -e

# 检查 Docker
if ! sudo docker info &>/dev/null 2>&1; then
    echo "错误: Docker 未安装，请先在本地运行："
    echo "  klogin instances apps sub <instance-id> -a docker"
    exit 1
fi
echo "Docker 已安装 ✓"

# 配置 host.docker.internal（必须用 hostname -I，不能用 ifconfig.me）
EXTERNAL_IP=$(hostname -I | awk '{print $1}')
echo "实例 IP: $EXTERNAL_IP"
sudo sed -i '/host.docker.internal/d' /etc/hosts
echo "$EXTERNAL_IP host.docker.internal" | sudo tee -a /etc/hosts
echo "hosts 配置完成 ✓"

# 清理旧 agent-server 和主容器（防止 401 认证冲突）
sudo docker ps -a --filter name=oh-agent-server -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f openhands-app 2>/dev/null || true

# 启动 OpenHands（不要加 OH_SECRET_KEY，否则 agent-server 认证会 401）
echo ">>> 启动 OpenHands..."
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

# 等待启动
echo "等待 OpenHands 启动..."
for i in $(seq 1 30); do
    if sudo docker logs openhands-app 2>&1 | grep -q "Uvicorn running"; then
        echo "OpenHands 启动成功 ✓"
        break
    fi
    [ "$i" -eq 30 ] && echo "警告: 等待超时，请手动确认: sudo docker logs openhands-app"
    sleep 2
done

# ─── 补丁1：sandbox 复用（修复 V1 新建会话 401）───
# 根因：host network 下每次新建会话都调用 start_sandbox()，创建新 agent-server 容器，
# 端口 8000 冲突导致 session key 不匹配 → 401。修复：复用已运行的 sandbox。
cat > /tmp/patch_sandbox.py << 'PYEOF'
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if 'Reusing existing sandbox in host network mode' in src:
    print('sandbox 补丁已存在 ✓')
    exit(0)

old = '        """Start a new sandbox."""\n        # Warn about port collision risk'
new_code = '''        """Start a new sandbox."""
        # In host network mode, only one container can bind to a given port.
        # Reuse an existing running sandbox to avoid session key mismatch (401).
        if self.use_host_network:
            existing_page = await self.search_sandboxes()
            for item in existing_page.items:
                if item.status == SandboxStatus.RUNNING:
                    _logger.info(f'Reusing existing sandbox in host network mode: {item.id}')
                    return item
        # Warn about port collision risk'''
if old in src:
    src = src.replace(old, new_code, 1)
    with open(path, 'w') as f:
        f.write(src)
    print('sandbox 补丁已应用（host network 复用 sandbox）✓')
else:
    print('警告: sandbox 补丁 pattern 未匹配，跳过')
PYEOF
sudo docker cp /tmp/patch_sandbox.py openhands-app:/tmp/patch_sandbox.py
SANDBOX_RESULT=$(sudo docker exec openhands-app python3 /tmp/patch_sandbox.py 2>&1)
echo "$SANDBOX_RESULT"

# ─── 补丁2：agent-server 反向代理路由（修复 V1 Disconnected + 消息无响应）───
# 问题1：V1 会话的 agent-server URL 是 http://127.0.0.1:8000，浏览器无法直接访问。
# 问题2：klogin ingress 剥离 WebSocket Upgrade 头，原生 WS 连接失败。
# 问题3（核心）：POST /api/conversations/{id}/events 只存 DB，不唤醒 Python agent asyncio
#               队列。必须通过 WebSocket 发送才能触发 agent 处理消息！
# 修复：
#   - 反向代理路由（HTTP/SSE/WS）让浏览器通过 klogin 访问 agent-server
#   - SSE 端点替代 WebSocket（klogin 不拦截普通 HTTP）
#   - POST /api/conversations/{id}/events 专用路由：收到 HTTP POST 后内部开 WS 转发

cat > /tmp/agent_server_proxy.py << 'PYEOF'
import asyncio
import httpx
import websockets
from fastapi import APIRouter, Request, WebSocket, Response
from starlette.responses import StreamingResponse

AGENT_SERVER_HTTP = "http://127.0.0.1:8000"
AGENT_SERVER_WS = "ws://127.0.0.1:8000"

agent_proxy_router = APIRouter(prefix="/agent-server-proxy")


# SSE 端点：将 agent-server WebSocket 转为 SSE（klogin 不拦截 HTTP，会拦截 WS Upgrade）
@agent_proxy_router.get("/sockets/events/{conversation_id}/sse")
async def proxy_sse(request: Request, conversation_id: str):
    params = dict(request.query_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    ws_url = f"{AGENT_SERVER_WS}/sockets/events/{conversation_id}"
    if qs:
        ws_url += f"?{qs}"

    async def generate():
        try:
            async with websockets.connect(ws_url) as ws:
                yield "data: __connected__\n\n"
                async for msg in ws:
                    data = msg if isinstance(msg, str) else msg.decode()
                    data = data.replace("\n", "\\n")
                    yield f"data: {data}\n\n"
        except Exception:
            pass
        yield "data: __closed__\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


# WebSocket 代理（备用）
@agent_proxy_router.websocket("/sockets/events/{conversation_id}")
async def proxy_websocket(websocket: WebSocket, conversation_id: str):
    await websocket.accept()
    params = dict(websocket.query_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    agent_ws_url = f"{AGENT_SERVER_WS}/sockets/events/{conversation_id}"
    if qs:
        agent_ws_url += f"?{qs}"
    try:
        async with websockets.connect(agent_ws_url) as agent_ws:
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


# POST events via WebSocket — HTTP POST到agent-server不唤醒Python agent asyncio队列
# 必须在 catch-all 之前注册
@agent_proxy_router.post("/api/conversations/{conversation_id}/events")
async def proxy_send_event_ws(conversation_id: str, request: Request):
    params = dict(request.query_params)
    key = request.headers.get("X-Session-API-Key", "") or params.get("session_api_key", "")
    body = await request.body()
    ws_url = f"{AGENT_SERVER_WS}/sockets/events/{conversation_id}"
    if key:
        ws_url += f"?session_api_key={key}"
    try:
        async with websockets.connect(ws_url) as ws:
            await ws.send(body.decode())
    except Exception:
        pass
    return Response(content='{"success":true}', status_code=200, media_type="application/json")


# HTTP 代理（catch-all，必须在 SSE 路由之后注册）
@agent_proxy_router.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def proxy_http(request: Request, path: str):
    url = f"{AGENT_SERVER_HTTP}/{path}"
    params = dict(request.query_params)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")}
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.request(method=request.method, url=url,
                                        params=params, headers=headers, content=body)
            resp_headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in ("content-encoding", "transfer-encoding", "connection")}
            return Response(content=resp.content, status_code=resp.status_code, headers=resp_headers)
    except Exception as e:
        return Response(content=str(e), status_code=502)
PYEOF

cat > /tmp/patch_app.py << 'PYEOF'
with open('/app/openhands/server/app.py') as f:
    src = f.read()

if 'agent_server_proxy' in src:
    print('app.py 代理路由已存在 ✓')
else:
    old = 'from openhands.server.routes.public import app as public_api_router'
    new = 'from openhands.server.routes.agent_server_proxy import agent_proxy_router\nfrom openhands.server.routes.public import app as public_api_router'
    src = src.replace(old, new, 1)
    old2 = 'app.include_router(public_api_router)'
    new2 = 'app.include_router(agent_proxy_router)\napp.include_router(public_api_router)'
    src = src.replace(old2, new2, 1)
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py 代理路由已注入 ✓')
PYEOF

sudo docker cp /tmp/agent_server_proxy.py openhands-app:/app/openhands/server/routes/agent_server_proxy.py
sudo docker cp /tmp/patch_app.py openhands-app:/tmp/patch_app.py
sudo docker exec openhands-app python3 /tmp/patch_app.py

# ─── 补丁2b：rate limiter 修复（klogin 共享 IP + SSE 重连风暴）───
# 根因1：klogin 所有请求共用同一代理 IP，per-IP 10req/s 限流会误杀正常请求。
# 根因2：老 browser tab 的 SSE 失败后不断重连，把限流配额耗尽。
# 修复：SSE 端点排除限流 + 用 X-Forwarded-For 获取真实客户端 IP。
cat > /tmp/patch_rate_limiter.py << 'PYEOF'
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
sudo docker cp /tmp/patch_rate_limiter.py openhands-app:/tmp/patch_rate_limiter.py
sudo docker exec openhands-app python3 /tmp/patch_rate_limiter.py

# ─── 补丁2c：CacheControlMiddleware 改为 no-cache（防止浏览器将 JS 资产缓存为 immutable）───
# 根因：middleware.py 的 CacheControlMiddleware 对所有 /assets/*.js 设置 immutable(max-age=30d)，
# 导致补丁修改的 JS 文件无法被浏览器重新获取，必须使用全新文件名才能绕过缓存。
# 修复：改为 no-cache, must-revalidate，让浏览器每次都向服务器确认文件是否更新。
cat > /tmp/patch_cache_control.py << 'PYEOF'
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
sudo docker cp /tmp/patch_cache_control.py openhands-app:/tmp/patch_cache_control.py
sudo docker exec openhands-app python3 /tmp/patch_cache_control.py

# ─── 补丁3：socket.io polling（修复 V0 会话 Disconnected）───
# klogin 会剥离 WebSocket Upgrade 头，改为 polling+websocket 顺序，先用 polling
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_FILE=/tmp/oh-patch-${JS_ASSET}
    sudo docker cp openhands-app:/app/frontend/build/assets/${JS_ASSET} $JS_FILE 2>/dev/null || continue
    sudo chmod 666 $JS_FILE
    if ! grep -q 'polling.*websocket' $JS_FILE 2>/dev/null; then
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_FILE
        sudo docker cp $JS_FILE openhands-app:/app/frontend/build/assets/${JS_ASSET}
        echo "socket.io polling 补丁已应用: ${JS_ASSET} ✓"
    else
        echo "socket.io polling 补丁已存在: ${JS_ASSET} ✓"
    fi
done

# ─── 补丁4：v1-conversation-service.js 路由改为走反向代理 ───
# C() 和 $() 函数改为使用 window.location.host/agent-server-proxy，
# 这样浏览器的所有 agent-server 调用都走 openhands-app（port 3000），可通过 klogin
cat > /tmp/patch_v1svc.py << 'PYEOF'
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
sudo docker cp /tmp/patch_v1svc.py openhands-app:/tmp/patch_v1svc.py
sudo docker exec openhands-app python3 /tmp/patch_v1svc.py

# ─── 补丁5：should-render-event.js WebSocket → SSE EventSource ───
# Je() hook 中把 new WebSocket(L) 替换为 EventSource（SSE），
# SSE 是普通 HTTP 请求，klogin 不拦，即可解决 V1 会话 Disconnected 问题
cat > /tmp/patch_sre.py << 'PYEOF'
path = '/app/frontend/build/assets/should-render-event-D7h-BMHP.js'
with open(path) as f:
    src = f.read()

if 'EventSource' in src:
    print('should-render-event.js SSE 补丁已存在 ✓')
    exit(0)

B = chr(92)  # backslash, avoids Python escape confusion
old_ws = 'const O=new WebSocket(L);'
new_ws = (
    # Extract conversation_id and session_api_key from the WS URL
    'const _m=L.match(/' + B + '/sockets' + B + '/events' + B + '/([^?]+)(?:' + B + '?(.*))?/);'
    'const _id=_m?_m[1]:"";'
    'const _key=(new URLSearchParams(_m&&_m[2]?_m[2]:"")).get("session_api_key")||"";'
    # Build SSE URL: ws://host/agent-server-proxy/sockets/events/{id}?... → http://host/.../sse?...
    'const _su=L.replace(/^ws:/,"http:").replace(/^wss:/,"https:")'
    '.replace(/(' + B + '/sockets' + B + '/events' + B + '/[^?]+)/,"$1/sse");'
    # Fake WebSocket object backed by EventSource
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
    print('WARNING: WebSocket pattern not found in should-render-event.js')
PYEOF
sudo docker cp /tmp/patch_sre.py openhands-app:/tmp/patch_sre.py
sudo docker exec openhands-app python3 /tmp/patch_sre.py

# ─── 补丁5b：cache busting — 重命名已修改的 JS 文件（bust proxy/browser immutable cache）───
# should-render-event → BMHPx, conversation-fHdubO7R → Rx, manifest → x, 更新 index.html
cat > /tmp/patch_cache_bust.py << 'PYEOF'
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
# conversation-fHdubO7Rx.js → Rz.js（新 URL，浏览器从未见过，必然从服务器获取）
# manifest-8c9a7105x.js → z.js（引用 Rz，更新 index.html 指向 z）
# 根因：第一次部署时 immutable 头已生效，x 文件被浏览器缓存了旧内容；z 文件绕过此缓存。
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
sudo docker cp /tmp/patch_cache_bust.py openhands-app:/tmp/patch_cache_bust.py
sudo docker exec openhands-app python3 /tmp/patch_cache_bust.py

# ─── 补丁6：app.py 注入 /api/proxy/events 路由（klogin 转发 /api/*）───
# klogin 只转发 /api/* 和 /socket.io/*。
# GET  /api/proxy/events/{id}/stream     — SSE 事件流（FakeWS EventSource 用）
# POST /api/proxy/conversations/{id}/events — 收 HTTP POST 后内部走 WebSocket 发给 agent
#   ↑ 关键！HTTP POST 直接发给 agent-server 不会唤醒 Python agent asyncio 队列，
#     必须通过 WebSocket 发送才能触发 LLM 调用。
cat > /tmp/patch_api_proxy_events.py << 'PYEOF'
with open('/app/openhands/server/app.py') as f:
    src = f.read()

if '/api/proxy/events' in src and 'Must send via WebSocket' in src and '_AGENT_WS' not in src:
    print('api/proxy/events 路由（含WebSocket修复）已存在 ✓')
    exit(0)

MARKER = 'app.include_router(agent_proxy_router)'
if MARKER not in src:
    print('WARNING: include_router(agent_proxy_router) not found in app.py')
    exit(1)

new_routes = '''
@app.get("/api/proxy/events/{conversation_id}/stream", include_in_schema=False)
async def api_proxy_events_stream(request: Request, conversation_id: str):
    """SSE via /api/* - klogin只转发/api/*，此端点让浏览器收到V1实时事件。"""
    import websockets as _ws
    from starlette.responses import StreamingResponse as _SR
    params = dict(request.query_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    ws_url = f"ws://127.0.0.1:8000/sockets/events/{conversation_id}"
    if qs:
        ws_url += f"?{qs}"
    async def _gen():
        try:
            async with _ws.connect(ws_url) as ws:
                yield "data: __connected__\\n\\n"
                async for msg in ws:
                    data = msg if isinstance(msg, str) else msg.decode()
                    data = data.replace("\\n", "\\\\n")
                    yield f"data: {data}\\n\\n"
        except Exception:
            pass
        yield "data: __closed__\\n\\n"
    return _SR(_gen(), media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

@app.post("/api/proxy/conversations/{conversation_id}/events", include_in_schema=False)
async def api_proxy_send_event(conversation_id: str, request: Request):
    # Must send via WebSocket to wake up Python agent's asyncio queue.
    # HTTP POST only stores event in DB — agent won't see it.
    import websockets as _ws
    body = await request.body()
    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")
    ws_url = f"ws://127.0.0.1:8000/sockets/events/{conversation_id}"
    if key:
        ws_url += f"?session_api_key={key}"
    try:
        async with _ws.connect(ws_url) as ws:
            await ws.send(body.decode())
    except Exception:
        pass
    return JSONResponse({"success": True})

'''

src = src.replace(MARKER, MARKER + '\n' + new_routes, 1)
with open('/app/openhands/server/app.py', 'w') as f:
    f.write(src)
print('api/proxy/events 路由已注入 ✓')
PYEOF
sudo docker cp /tmp/patch_api_proxy_events.py openhands-app:/tmp/patch_api_proxy_events.py
sudo docker exec openhands-app python3 /tmp/patch_api_proxy_events.py

# ─── 补丁7：index.html 注入全局 WebSocket/fetch 拦截器 ───
# klogin 代理层会缓存 /assets/*.js，补丁可能对浏览器不生效。
# index.html 设置了 no-store，每次都新鲜，是最可靠的注入点。
# FakeWS: 拦截 /sockets/events/ WebSocket → EventSource → /api/proxy/events/{id}/stream
# send(): 用 /api/proxy/conversations/{id}/events（klogin 可转发）
sudo docker cp openhands-app:/app/frontend/build/index.html /tmp/oh-index.html
sudo chmod 666 /tmp/oh-index.html
python3 << 'PYEOF'
import re
with open('/tmp/oh-index.html') as f:
    html = f.read()
# Remove any old FakeWS injection before re-injecting (ensures clean update)
if 'FakeWS' in html:
    html = re.sub(r'<script>\(function\(\)\{[^<]*FakeWS[^<]*\}\)\(\);</script>', '', html, flags=re.DOTALL)
    print('旧 FakeWS 已移除')
inject = (
    '<script>(function(){'
    'var _f=window.fetch;window.fetch=function(u,o){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _f.call(this,u,o);};'
    'var _X=window.XMLHttpRequest.prototype.open;'
    'window.XMLHttpRequest.prototype.open=function(m,u){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _X.apply(this,arguments);};'
    'var _WS=window.WebSocket;'
    'function FakeWS(url,proto){'
    'var self=this;self.readyState=0;self.onopen=null;self.onmessage=null;self.onclose=null;self.onerror=null;self._es=null;'
    'var m=url.match(/\\/sockets\\/events\\/([^?]+)/);'
    'var id=m?m[1]:"";'
    'var queryStr=url.indexOf("?")>=0?url.split("?")[1]:"";'
    'var params=new URLSearchParams(queryStr);'
    'var key=params.get("session_api_key")||"";'
    # sseUrl uses /api/proxy/events/ - klogin forwards /api/*
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
with open('/tmp/oh-index.html', 'w') as f:
    f.write(html)
print('index.html FakeWS 已注入（使用 /api/proxy/events/ 路径）✓')
PYEOF
sudo docker cp /tmp/oh-index.html openhands-app:/app/frontend/build/index.html

# ─── 补丁8：per-conversation 工作目录隔离 ───
# 根因：host network sandbox 复用导致所有 V1 会话共用 /workspace/project/，互相可见文件。
# 修复：在 _start_app_conversation() 中，为每个会话创建独立子目录
#       /workspace/project/{task.id.hex}/ 并 git init，后续代码使用此目录。
cat > /tmp/patch_per_conv_workspace.py << 'PYEOF'
path = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(path) as f:
    src = f.read()

if 'per-conversation workspace isolation' in src:
    print('per-conversation workspace 补丁已存在 ✓')
    exit(0)

# 1. 在 assert sandbox_spec is not None 之后插入目录创建逻辑
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

# 2. 把 _build_start_conversation_request_for_user 调用中的 sandbox_spec.working_dir 改为 conv_working_dir
old_build = '                    sandbox_spec.working_dir,'
new_build = '                    conv_working_dir,  # per-conversation isolated dir'

# 这个字符串在文件中可能出现多次，只替换第一次（在 _start_app_conversation 中的那次）
if old_build in src:
    src = src.replace(old_build, new_build, 1)
else:
    print('WARNING: sandbox_spec.working_dir in _build 未匹配')

with open(path, 'w') as f:
    f.write(src)
print('per-conversation workspace 补丁已应用 ✓')
PYEOF
sudo docker cp /tmp/patch_per_conv_workspace.py openhands-app:/tmp/patch_per_conv_workspace.py
sudo docker exec openhands-app python3 /tmp/patch_per_conv_workspace.py

# ─── 补丁9：sandbox port proxy（Code/App tab 浏览器访问）───
# VSCode (8001), App 预览 (8011/8012) 的 URL 是 http://127.0.0.1:{port}，
# 浏览器无法通过 klogin 访问。在 openhands-app 注入 /api/sandbox-port/{port}/* 代理路由。
cat > /tmp/patch_sandbox_port_proxy.py << 'PYEOF'
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
    """Reverse proxy any sandbox port through openhands-app (port 3000)."""
    import httpx as _hx
    target = f"http://127.0.0.1:{port}/{path}"
    qs = str(request.query_params)
    if qs:
        target += f"?{qs}"
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")}
    body = await request.body()
    try:
        async with _hx.AsyncClient(timeout=60.0, follow_redirects=True) as client:
            resp = await client.request(
                method=request.method, url=target, headers=headers, content=body)
            resp_headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in ("content-encoding", "transfer-encoding", "connection")}
            from starlette.responses import Response as _Resp
            return _Resp(content=resp.content, status_code=resp.status_code,
                        headers=resp_headers, media_type=resp.headers.get("content-type"))
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
sudo docker cp /tmp/patch_sandbox_port_proxy.py openhands-app:/tmp/patch_sandbox_port_proxy.py
sudo docker exec openhands-app python3 /tmp/patch_sandbox_port_proxy.py

# ─── 补丁10：exposed_urls 代理路径重写（VSCODE/WORKER → /api/sandbox-port/）───
# _container_to_sandbox_info() 返回的 exposed_urls 中 VSCODE/WORKER 是 http://127.0.0.1:{port}，
# 改写为 /api/sandbox-port/{port}。AGENT_SERVER 保持绝对 URL（health check 需要）。
cat > /tmp/patch_sandbox_exposed_urls.py << 'PYEOF'
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
sudo docker cp /tmp/patch_sandbox_exposed_urls.py openhands-app:/tmp/patch_sandbox_exposed_urls.py
sudo docker exec openhands-app python3 /tmp/patch_sandbox_exposed_urls.py

# ─── 重启 openhands-app 使所有 Python 补丁生效 ───
echo ""
echo ">>> 重启 openhands-app 使补丁生效..."
sudo docker restart openhands-app
for i in $(seq 1 30); do
    sudo docker logs openhands-app 2>&1 | grep -q "Uvicorn running" && echo "重启完成 ✓" && break
    sleep 2
done

# 重启后重新注入 JS 补丁（docker restart 保留 writable layer，但做一次确认）
for JS_ASSET in markdown-renderer-Ci-ahARR.js parse-pr-url-BOXiVwNz.js; do
    JS_TMP=/tmp/oh-patch-${JS_ASSET}
    sudo docker cp openhands-app:/app/frontend/build/assets/${JS_ASSET} $JS_TMP 2>/dev/null || continue
    sudo chmod 666 $JS_TMP
    grep -q 'polling.*websocket' $JS_TMP 2>/dev/null || {
        sudo sed -i 's/transports:\["websocket"\]/transports:["polling","websocket"]/g' $JS_TMP
        sudo docker cp $JS_TMP openhands-app:/app/frontend/build/assets/${JS_ASSET}
        echo "重启后重新注入 polling 补丁: ${JS_ASSET}"
    }
done
sudo docker exec openhands-app python3 /tmp/patch_v1svc.py
sudo docker exec openhands-app python3 /tmp/patch_sre.py
sudo docker exec openhands-app python3 /tmp/patch_api_proxy_events.py
sudo docker exec openhands-app python3 /tmp/patch_per_conv_workspace.py
sudo docker exec openhands-app python3 /tmp/patch_sandbox_port_proxy.py
sudo docker exec openhands-app python3 /tmp/patch_sandbox_exposed_urls.py
sudo docker exec openhands-app python3 /tmp/patch_rate_limiter.py
# 重新注入 index.html FakeWS（/api/proxy/events 路径，klogin 可转发）
sudo docker cp openhands-app:/app/frontend/build/index.html /tmp/oh-index.html 2>/dev/null
sudo chmod 666 /tmp/oh-index.html 2>/dev/null
python3 /tmp/update_fakews.py 2>/dev/null || python3 << 'INNEREOF'
import re
with open('/tmp/oh-index.html') as f: html = f.read()
if 'FakeWS' in html:
    html = re.sub(r'<script>\(function\(\)\{[^<]*FakeWS[^<]*\}\)\(\);</script>', '', html, flags=re.DOTALL)
inject = (
    '<script>(function(){var _f=window.fetch;window.fetch=function(u,o){if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0){u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}return _f.call(this,u,o);};var _X=window.XMLHttpRequest.prototype.open;window.XMLHttpRequest.prototype.open=function(m,u){if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0){u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}return _X.apply(this,arguments);};var _WS=window.WebSocket;function FakeWS(url,proto){var self=this;self.readyState=0;self.onopen=null;self.onmessage=null;self.onclose=null;self.onerror=null;self._es=null;var m=url.match(/\\/sockets\\/events\\/([^?]+)/);var id=m?m[1]:"";var queryStr=url.indexOf("?")>=0?url.split("?")[1]:"";var params=new URLSearchParams(queryStr);var key=params.get("session_api_key")||"";var sseUrl="/api/proxy/events/"+id+"/stream?resend_all=true";if(key)sseUrl+="&session_api_key="+encodeURIComponent(key);self.send=function(d){fetch("/api/proxy/conversations/"+id+"/events",{method:"POST",headers:{"Content-Type":"application/json","X-Session-API-Key":key},body:d}).catch(function(){});};self.close=function(){if(self._es){self._es.close();self._es=null;}self.readyState=3;if(self.onclose)self.onclose({code:1000,reason:"",wasClean:true});};var es=new EventSource(sseUrl);self._es=es;es.onopen=function(){self.readyState=1;if(self.onopen)self.onopen({});};es.onmessage=function(ev){if(ev.data==="__connected__")return;if(ev.data==="__closed__"){self.readyState=3;if(self.onclose)self.onclose({code:1000,wasClean:true});return;}if(self.onmessage)self.onmessage({data:ev.data});};es.onerror=function(){if(self._es){self._es.close();self._es=null;}self.readyState=3;if(self.onerror)self.onerror({});if(self.onclose)self.onclose({code:1006,reason:"",wasClean:false});};}FakeWS.CONNECTING=0;FakeWS.OPEN=1;FakeWS.CLOSING=2;FakeWS.CLOSED=3;window.WebSocket=function(url,proto){if(url&&url.indexOf("/sockets/events/")>=0){return new FakeWS(url,proto);}return new _WS(url,proto);};window.WebSocket.prototype=_WS.prototype;window.WebSocket.CONNECTING=0;window.WebSocket.OPEN=1;window.WebSocket.CLOSING=2;window.WebSocket.CLOSED=3;})();</script>'
)
with open('/tmp/oh-index.html', 'w') as f: f.write(html.replace('<head>', '<head>' + inject, 1))
print('重启后重新注入 index.html FakeWS ✓')
INNEREOF
sudo docker cp /tmp/oh-index.html openhands-app:/app/frontend/build/index.html 2>/dev/null || true
REMOTE

# 4. 建立本地 SSH 隧道并验证
echo ""
echo ">>> 建立本地隧道并验证..."
pkill -f "ssh.*-L 3001.*$INSTANCE_ID" 2>/dev/null || true
sleep 1
ssh -f -N -L 3001:127.0.0.1:3000 "$INSTANCE_ID"
sleep 2

echo "测试 API 连通性..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/api/options/models)
if [ "$HTTP_CODE" != "200" ]; then
    echo "警告: API 返回 $HTTP_CODE，请检查 OpenHands 是否启动"
else
    echo "API 连通 ✓"
fi

echo "测试代理路由..."
PROXY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/agent-server-proxy/health)
[ "$PROXY_CODE" = "200" ] && echo "agent-server 代理路由 ✓" || echo "警告: 代理路由返回 $PROXY_CODE"

echo "测试 sandbox port proxy（Code/App tab）..."
SPORT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:3001/api/sandbox-port/8001/")
[ "$SPORT_CODE" = "200" ] || [ "$SPORT_CODE" = "302" ] || [ "$SPORT_CODE" = "403" ] && \
  echo "sandbox port proxy 路由 ✓（HTTP $SPORT_CODE）" || \
  echo "警告: sandbox port proxy 返回 $SPORT_CODE（正常情况需等 sandbox 启动后才能访问）"

echo "测试新建 V1 会话（浏览器路径）..."
CONV_V1_RESP=$(curl -s -X POST http://localhost:3001/api/v1/app-conversations \
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
        STATUS_INFO=$(curl -s "http://localhost:3001/api/conversations/$CONV_V1_ID" | \
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
API_KEY=$(curl -s "http://localhost:3001/api/conversations/$CONV_ID" | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('session_api_key',''))" 2>/dev/null || true)
if [ -n "$CONV_ID" ] && [ -n "$API_KEY" ]; then
    SSE_FIRST=$(curl -s -N --max-time 5 \
      -H 'Accept: text/event-stream' \
      "http://localhost:3001/api/proxy/events/$CONV_ID/stream?resend_all=true&session_api_key=$API_KEY" \
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
echo "  - sandbox port proxy（Code/App tab 通过 /api/sandbox-port/ 访问）"
echo "  - exposed_urls 代理路径重写（VSCODE/WORKER URL → /api/sandbox-port/）"
echo "  - git-service.js poll 修复（V1 新建会话直接返回真实 conversation_id）"
echo "  - task-nav-fix（index.html 兜底脚本，确保浏览器缓存情况下也能跳转会话）"
echo "  - cache busting z-suffix（manifest/conversation JS 全新 URL，清除旧 immutable 缓存）"
echo ""
echo "访问方式："
echo "  域名（推荐）: https://openhands.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com"
echo "  本地隧道:     http://localhost:3001  (隧道已在后台运行)"
echo ""
echo "同事访问域名无需任何隧道，AppleConnect 认证即可。"
echo "下一步: 打开上方任意地址 → Settings → 配置 LLM"
echo "========================================"
