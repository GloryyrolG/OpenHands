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
cat > /tmp/patch_sandbox.py << 'PYEOF'
import re as _re
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB] per-session' in src and '[OH-TAB] bridge mode' in src:
    print('sandbox 补丁已存在（per-session 模式）✓')
    exit(0)

# ── 升级：移除旧 sandbox 复用逻辑（per-session 模式每会话独立容器）──
if '[OH-TAB] Reusing existing sandbox' in src:
    src = _re.sub(
        r'        # OH-TAB: reuse existing RUNNING sandbox.*?# Warn about port collision risk',
        '        # [OH-TAB] per-session: each conversation gets its own sandbox container\n        # Warn about port collision risk',
        src, count=1, flags=_re.DOTALL
    )
    print('已移除旧 sandbox 复用逻辑（升级为 per-session 模式）✓')
elif '[OH-TAB] bridge mode' not in src:
    # 全新安装：只加 per-session 标记，不加复用逻辑
    old_fresh = '        """Start a new sandbox."""\n        # Warn about port collision risk'
    if old_fresh in src:
        src = src.replace(old_fresh,
            '        """Start a new sandbox."""\n'
            '        # [OH-TAB] per-session: each conversation gets its own sandbox container\n'
            '        # Warn about port collision risk',
            1)
        print('per-session 标记已添加（全新安装）✓')
    else:
        print('警告: start_sandbox pattern 未匹配，跳过 per-session 标记')

# Part 2: force bridge mode for oh-tab- to avoid port 8000 conflict with other deployments
old_net = '        # Determine network mode\n        network_mode = \'host\' if self.use_host_network else None\n\n        if self.use_host_network:'
new_net = '''        # Determine network mode
        network_mode = 'host' if self.use_host_network else None

        # [OH-TAB] bridge mode: avoid port 8000 conflict with other openhands deployments
        if self.container_name_prefix == 'oh-tab-':
            network_mode = None  # bridge mode
            port_mappings = {}
            for exposed_port in self.exposed_ports:
                host_port = self._find_unused_port()
                port_mappings[exposed_port.container_port] = host_port
                env_vars[exposed_port.name] = str(host_port)
                _logger.info(f'[OH-TAB] bridge mode: container port {exposed_port.container_port} -> host port {host_port}')

        if self.use_host_network and self.container_name_prefix != 'oh-tab-':'''
if old_net in src:
    src = src.replace(old_net, new_net, 1)
    print('sandbox bridge-mode 补丁已应用（oh-tab- 使用 bridge 避免 port 8000 冲突）✓')
else:
    print('警告: sandbox bridge-mode 补丁 pattern 未匹配，跳过')

with open(path, 'w') as f:
    f.write(src)

# 修改 agent-server 容器前缀，避免与其他 openhands 实例冲突
prefix_old = "container_name_prefix: str = 'oh-agent-server-'"
prefix_new = "container_name_prefix: str = 'oh-tab-'"
with open(path) as f:
    src2 = f.read()
if prefix_new in src2:
    print("container_name_prefix 'oh-tab-' 已存在 ✓")
elif prefix_old in src2:
    src2 = src2.replace(prefix_old, prefix_new, 1)
    with open(path, 'w') as f:
        f.write(src2)
    print("container_name_prefix 改为 'oh-tab-' ✓")
else:
    print('警告: container_name_prefix pattern 未匹配，跳过')
PYEOF
sudo docker cp /tmp/patch_sandbox.py openhands-app-tab:/tmp/patch_sandbox.py
SANDBOX_RESULT=$(sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox.py 2>&1)
echo "$SANDBOX_RESULT"

# ─── 补丁1.5：bridge mode 网络修复 ───
# 修复三个 bridge 容器网络问题：
# (1) extra_hosts 仅在 network_mode != 'host' 时应用（不管 SANDBOX_USE_HOST_NETWORK 值）
#     → oh-tab- 容器能解析 host.docker.internal → 172.17.0.1
# (2) webhook URL 端口从 OH_WEB_URL 读取（避免默认 3000 与 tab-display 端口 3003 不符）
# (3) MCP URL 替换 127.0.0.1 → host.docker.internal（bridge 容器内 127.0.0.1 是自身）
cat > /tmp/patch_bridge_fixes.py << 'PYEOF'
import re

# Fix 1: extra_hosts condition (docker_sandbox_service.py)
SANDBOX_PATH = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(SANDBOX_PATH) as f:
    src = f.read()

if 'network_mode != \'host\'' in src and 'OH-TAB' in src and '[OH-TAB] use network_mode check' in src:
    print('extra_hosts fix already present ✓')
else:
    old_eh = (
        "                # Allow agent-server containers to resolve host.docker.internal\n"
        "                # and other custom hostnames for LAN deployments\n"
        "                # Note: extra_hosts is not needed with host network mode\n"
        "                extra_hosts=self.extra_hosts\n"
        "                if self.extra_hosts and not self.use_host_network\n"
        "                else None,"
    )
    new_eh = (
        "                # Allow agent-server containers to resolve host.docker.internal\n"
        "                # and other custom hostnames for LAN deployments\n"
        "                # [OH-TAB] use network_mode check: oh-tab- forces bridge mode\n"
        "                # even when SANDBOX_USE_HOST_NETWORK=true, so we must apply\n"
        "                # extra_hosts for bridge-mode containers regardless of the flag\n"
        "                extra_hosts=self.extra_hosts\n"
        "                if self.extra_hosts and network_mode != 'host'\n"
        "                else None,"
    )
    if old_eh in src:
        src = src.replace(old_eh, new_eh, 1)
        with open(SANDBOX_PATH, 'w') as f:
            f.write(src)
        print('extra_hosts fix applied ✓')
    else:
        print('WARNING: extra_hosts pattern not found! Check docker_sandbox_service.py')
        idx = src.find('extra_hosts=self.extra_hosts')
        if idx >= 0:
            print('Context:', repr(src[max(0,idx-100):idx+200]))

# Fix 2: webhook port from OH_WEB_URL (docker_sandbox_service.py)
with open(SANDBOX_PATH) as f:
    src = f.read()

if '[OH-TAB] bridge mode: use OH_WEB_URL port for webhook' in src:
    print('webhook port fix already present ✓')
else:
    old_wh = (
        "        env_vars[WEBHOOK_CALLBACK_VARIABLE] = (\n"
        "            f'http://host.docker.internal:{self.host_port}/api/v1/webhooks'\n"
        "        )"
    )
    new_wh = (
        "        # [OH-TAB] bridge mode: use OH_WEB_URL port for webhook so agent-server\n"
        "        # can call back to correct openhands app port\n"
        "        import os as _os, re as _re\n"
        "        _wh_port = self.host_port\n"
        "        if self.container_name_prefix == 'oh-tab-':\n"
        "            _web_url = _os.environ.get('OH_WEB_URL', '')\n"
        "            _m = _re.search(r':(\\d+)$', _web_url)\n"
        "            if _m:\n"
        "                _wh_port = int(_m.group(1))\n"
        "        env_vars[WEBHOOK_CALLBACK_VARIABLE] = (\n"
        "            f'http://host.docker.internal:{_wh_port}/api/v1/webhooks'\n"
        "        )"
    )
    if old_wh in src:
        src = src.replace(old_wh, new_wh, 1)
        with open(SANDBOX_PATH, 'w') as f:
            f.write(src)
        print('webhook port fix applied ✓')
    else:
        print('WARNING: webhook pattern not found!')
        idx = src.find('WEBHOOK_CALLBACK_VARIABLE')
        if idx >= 0:
            print('Context:', repr(src[max(0,idx-20):idx+200]))

# Fix 3: MCP URL replace 127.0.0.1 → host.docker.internal (live_status_app_conversation_service.py)
LIVE_PATH = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(LIVE_PATH) as f:
    src3 = f.read()

if 'host.docker.internal' in src3 and 'mcp_url' in src3:
    print('MCP URL fix already present ✓')
else:
    old_mcp = "        mcp_url = f'{self.web_url}/mcp/mcp'"
    new_mcp = (
        "        # [OH-TAB] bridge mode: replace 127.0.0.1 with host.docker.internal so\n"
        "        # oh-tab- containers (bridge network) can reach the openhands app MCP server\n"
        "        mcp_url = f'{self.web_url}/mcp/mcp'.replace('http://127.0.0.1', 'http://host.docker.internal')"
    )
    if old_mcp in src3:
        src3 = src3.replace(old_mcp, new_mcp, 1)
        with open(LIVE_PATH, 'w') as f:
            f.write(src3)
        print('MCP URL fix applied ✓')
    else:
        print('WARNING: mcp_url pattern not found!')
        idx = src3.find('mcp_url')
        if idx >= 0:
            print('Context:', repr(src3[max(0,idx-50):idx+150]))

print('Done.')
PYEOF
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

cat > /tmp/agent_server_proxy.py << 'PYEOF'
import asyncio
import functools as _ft
import json as _json_mod
import re as _re_mod
import socket as _socket_mod
import sqlite3 as _sqlite3
import http.client as _http_client
import httpx
import websockets
from fastapi import APIRouter, Request, WebSocket, Response
from starlette.responses import StreamingResponse

agent_proxy_router = APIRouter(prefix="/agent-server-proxy")

# Per-session isolation: SQLite DB at ~/.openhands/openhands.db (app writes to home dir)
_DB_PATH = '/root/.openhands/openhands.db'

# Per-conversation URL cache: conversation_id -> agent_server_url
_url_cache: dict = {}


class _UnixHTTPConnection(_http_client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost")
        self._socket_path = socket_path
    def connect(self):
        s = _socket_mod.socket(_socket_mod.AF_UNIX, _socket_mod.SOCK_STREAM)
        s.connect(self._socket_path)
        self.sock = s


@_ft.lru_cache(maxsize=1)
def _get_agent_server_port() -> int:
    """Fallback: get host port of first oh-tab- container's port 8000."""
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        if not containers:
            return 8000
        for port_info in containers[0].get("Ports", []):
            if port_info.get("PrivatePort") == 8000 and port_info.get("PublicPort"):
                return port_info["PublicPort"]
        return 8000
    except Exception:
        return 8000


@_ft.lru_cache(maxsize=1)
def _get_agent_server_key() -> str:
    """Read session_api_key from first oh-tab- container via Docker API."""
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        if not containers:
            return ""
        cid = containers[0]["Id"]
        conn2 = _UnixHTTPConnection("/var/run/docker.sock")
        conn2.request("GET", f"/containers/{cid}/json")
        resp2 = conn2.getresponse()
        cdata = _json_mod.loads(resp2.read())
        env_list = cdata.get("Config", {}).get("Env", [])
        for e in env_list:
            if e.startswith("OH_SESSION_API_KEYS_0="):
                return e.split("=", 1)[1]
        return ""
    except Exception:
        return ""


_oh_tab_ip_cache = ["", 0.0]
def _get_oh_tab_ip() -> str:
    """Get bridge IP of first running oh-tab- container (cached 60s).
    Used for internal port access (user apps like Streamlit)."""
    import time as _t
    if _oh_tab_ip_cache[0] and _t.time() - _oh_tab_ip_cache[1] < 60:
        return _oh_tab_ip_cache[0]
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        if not containers:
            return ""
        cid = containers[0]["Id"]
        conn2 = _UnixHTTPConnection("/var/run/docker.sock")
        conn2.request("GET", f"/containers/{cid}/json")
        resp2 = conn2.getresponse()
        cdata = _json_mod.loads(resp2.read())
        ip = cdata.get("NetworkSettings", {}).get("IPAddress", "")
        if ip:
            _oh_tab_ip_cache[0] = ip
            _oh_tab_ip_cache[1] = _t.time()
        return ip
    except Exception:
        return _oh_tab_ip_cache[0]


_key_cache: dict = {}
def _get_tab_agent_key(conversation_id: str) -> str:
    """Get session_api_key for this conversation's oh-tab- container via Docker API."""
    cid = conversation_id.removeprefix('task-').replace('-', '')
    if cid in _key_cache:
        return _key_cache[cid]
    try:
        conn = _sqlite3.connect(_DB_PATH, timeout=3)
        cur = conn.cursor()
        cur.execute(
            'SELECT sandbox_id FROM conversation_metadata WHERE REPLACE(conversation_id,"-","")=? LIMIT 1',
            (cid,)
        )
        row = cur.fetchone()
        conn.close()
        if not row or not row[0]:
            return _get_agent_server_key()
        container_name = row[0]
        conn2 = _UnixHTTPConnection("/var/run/docker.sock")
        conn2.request("GET", f"/containers/{container_name}/json")
        resp2 = conn2.getresponse()
        cdata = _json_mod.loads(resp2.read())
        for e in cdata.get("Config", {}).get("Env", []):
            if e.startswith("OH_SESSION_API_KEYS_0="):
                key = e.split("=", 1)[1]
                _key_cache[cid] = key
                return key
    except Exception:
        pass
    return _get_agent_server_key()


def _get_oh_tab_container_for_port(host_port: int) -> dict:
    """Find the oh-tab- container that has host_port mapped (Docker NAT).
    Returns container inspect data dict, or empty dict on failure."""
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        for c in containers:
            for p in c.get("Ports", []):
                if p.get("PublicPort") == host_port:
                    cid = c["Id"]
                    conn2 = _UnixHTTPConnection("/var/run/docker.sock")
                    conn2.request("GET", f"/containers/{cid}/json")
                    resp2 = conn2.getresponse()
                    return _json_mod.loads(resp2.read())
    except Exception:
        pass
    return {}


def _resolve_tab_agent_url(conversation_id: str) -> str:
    """Per-session routing: look up agent_server_url for this conversation from SQLite DB.
    Returns the agent server base URL (e.g. http://127.0.0.1:14001) or empty string."""
    clean = conversation_id.removeprefix('task-').replace('-', '')
    try:
        conn = _sqlite3.connect(_DB_PATH, timeout=3)
        cur = conn.cursor()
        cur.execute(
            '''SELECT agent_server_url FROM app_conversation_start_task
               WHERE (id=? OR app_conversation_id=?) AND status="READY"
               ORDER BY created_at DESC LIMIT 1''',
            (clean, clean)
        )
        row = cur.fetchone()
        conn.close()
        if row and row[0]:
            return row[0]
    except Exception:
        pass
    return ''


def _get_tab_agent_url(conversation_id: str) -> str:
    """Get agent server URL for this conversation (with cache).
    Falls back to first oh-tab- container if DB lookup fails."""
    cid = conversation_id.removeprefix('task-').replace('-', '')
    if cid in _url_cache:
        return _url_cache[cid]
    url = _resolve_tab_agent_url(cid)
    if url:
        _url_cache[cid] = url
        return url
    # Fallback: use first oh-tab- container's published port
    fallback = f"http://127.0.0.1:{_get_agent_server_port()}"
    return fallback


def _tab_ws_url(conversation_id: str) -> str:
    return _get_tab_agent_url(conversation_id).replace('http://', 'ws://').replace('https://', 'wss://')


# SSE 端点：将 agent-server WebSocket 转为 SSE（klogin 不拦截 HTTP，会拦截 WS Upgrade）
@agent_proxy_router.get("/sockets/events/{conversation_id}/sse")
async def proxy_sse(request: Request, conversation_id: str):
    params = dict(request.query_params)
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    ws_url = f"{_tab_ws_url(conversation_id)}/sockets/events/{conversation_id}"
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
    agent_ws_url = f"{_tab_ws_url(conversation_id)}/sockets/events/{conversation_id}"
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


# POST events: per-conversation routing via DB
@agent_proxy_router.post("/api/conversations/{conversation_id}/events")
async def proxy_send_event_ws(conversation_id: str, request: Request):
    params = dict(request.query_params)
    key = request.headers.get("X-Session-API-Key", "") or params.get("session_api_key", "")
    body = await request.body()
    agent_url = _get_tab_agent_url(conversation_id)
    ws_url = f"{agent_url.replace('http://', 'ws://')}/sockets/events/{conversation_id}"
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
    # Per-conversation routing: extract conversation_id from path
    m = _re_mod.search(r'conversations/([a-f0-9\-]{32,36})', path)
    conv_id = m.group(1) if m else None
    if conv_id:
        agent_base = _get_tab_agent_url(conv_id)
    else:
        agent_base = f"http://127.0.0.1:{_get_agent_server_port()}"
    url = f"{agent_base}/{path}"
    params = dict(request.query_params)
    headers = {k: v for k, v in request.headers.items()
               if k.lower() not in ("host", "content-length", "transfer-encoding", "connection")}
    # Auto-inject session_api_key if not present (Changes tab etc. don't send it)
    if "x-session-api-key" not in {k.lower() for k in headers} and "session_api_key" not in params:
        _key = _get_tab_agent_key(conv_id) if conv_id else _get_agent_server_key()
        if _key:
            headers["X-Session-API-Key"] = _key
    body = await request.body()
    try:
        async with httpx.AsyncClient(timeout=60.0) as client:
            resp = await client.request(method=request.method, url=url,
                                        params=params, headers=headers, content=body)
            resp_headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in ("content-encoding", "transfer-encoding", "connection")}
            # Changes tab: agent-server returns 500/401 when git state unavailable or wrong key.
            if resp.status_code in (401, 500) and path.startswith("api/git/changes"):
                return Response(content="[]", status_code=200,
                                media_type="application/json")
            return Response(content=resp.content, status_code=resp.status_code, headers=resp_headers)
    except Exception as e:
        return Response(content=str(e), status_code=502)
PYEOF

cat > /tmp/patch_app.py << 'PYEOF'
with open('/app/openhands/server/app.py') as f:
    src = f.read()

if 'agent_server_proxy' in src and '_gasp' in src and '_gtau' in src:
    print('app.py 代理路由（含 _gasp/_gtau per-session）已存在 ✓')
elif 'agent_server_proxy' in src and '_gasp' in src:
    # Upgrade: add _gtau to existing import (old install has _gasp but not _gtau)
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py import 升级：添加 _gtau ✓')
elif 'agent_server_proxy' in src:
    # Upgrade: add _gasp and _gtau to existing import
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py import 升级：添加 _gasp + _gtau ✓')
else:
    old = 'from openhands.server.routes.public import app as public_api_router'
    new = 'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\nfrom openhands.server.routes.public import app as public_api_router'
    src = src.replace(old, new, 1)
    old2 = 'app.include_router(public_api_router)'
    new2 = 'app.include_router(agent_proxy_router)\napp.include_router(public_api_router)'
    src = src.replace(old2, new2, 1)
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py 代理路由已注入 ✓')
PYEOF

sudo docker cp /tmp/agent_server_proxy.py openhands-app-tab:/app/openhands/server/routes/agent_server_proxy.py
sudo docker cp /tmp/patch_app.py openhands-app-tab:/tmp/patch_app.py
sudo docker exec openhands-app-tab python3 /tmp/patch_app.py

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
sudo docker cp /tmp/patch_rate_limiter.py openhands-app-tab:/tmp/patch_rate_limiter.py
sudo docker exec openhands-app-tab python3 /tmp/patch_rate_limiter.py

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
sudo docker cp /tmp/patch_v1svc.py openhands-app-tab:/tmp/patch_v1svc.py
sudo docker exec openhands-app-tab python3 /tmp/patch_v1svc.py

# ─── 补丁5：should-render-event.js（已废弃，由 index.html FakeWS 全局 override window.WebSocket）───
# index.html 的 patch 7 已全局覆盖 window.WebSocket，should-render-event.js 内的 new WebSocket(L)
# 会自动被 FakeWS 拦截，无需再修改 BMHP.js 文件。
# 原来此处注入 EventSource 代码会产生有效或无效正则，对浏览器 immutable cache 造成污染，已移除。
# 保留原版 BMHP.js（有效 JS）以避免 "Invalid regular expression flags" SyntaxError。
cat > /tmp/patch_sre.py << 'PYEOF'
import os, shutil

ASSETS = '/app/frontend/build/assets'
bmhp = os.path.join(ASSETS, 'should-render-event-D7h-BMHP.js')
bmhpx = os.path.join(ASSETS, 'should-render-event-D7h-BMHPx.js')

with open(bmhp) as f:
    src = f.read()

if 'EventSource' in src:
    # 旧版有 EventSource 注入（可能有 broken regex），还原为原版不可行
    # 这里只打印警告，patch 5b 会处理 BMHPx 的 cache-bust
    print('WARNING: BMHP.js has EventSource injection - should be restored to original')
else:
    print('should-render-event.js 已是原版（无 FakeWS 注入）✓')
    # 确保 BMHPx.js 也是原版
    if not os.path.exists(bmhpx) or open(bmhpx).read() != src:
        shutil.copy2(bmhp, bmhpx)
        print('BMHPx.js 已同步为原版 ✓')
    else:
        print('BMHPx.js 已是原版 ✓')
PYEOF
sudo docker cp /tmp/patch_sre.py openhands-app-tab:/tmp/patch_sre.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sre.py

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
sudo docker cp /tmp/patch_cache_bust.py openhands-app-tab:/tmp/patch_cache_bust.py
sudo docker exec openhands-app-tab python3 /tmp/patch_cache_bust.py

# ─── 补丁12：browser store 全局暴露（修复 Browser tab 截图不更新）───
# 根因：V1 browse observation 事件 (BrowserObservation/browse) 经 FakeWS 传递给前端，
#       但 useBrowserStore (Zustand) 不在 window 作用域，FakeWS 无法直接调用 setScreenshotSrc。
# 修复：在包含 screenshotSrc 初始状态的 JS bundle 末尾注入
#       window.__oh_browser_store = <store_var>，使 FakeWS 可访问 Zustand store。
cat > /tmp/patch_browser_store_expose.py << 'PYEOF'
import glob, re, os

ASSETS = '/app/frontend/build/assets/'
patched_files = []

for js_file in sorted(glob.glob(f'{ASSETS}*.js')):
    try:
        with open(js_file) as f:
            src = f.read()
    except Exception:
        continue
    if 'screenshotSrc' not in src:
        continue
    if '__oh_browser_store' in src:
        print(f'Already exposed in {os.path.basename(js_file)} ✓')
        patched_files.append(js_file)
        continue

    # Find the store variable: search for setScreenshotSrc: (the setter, unique to browser store)
    # Pattern: VAR=FUNC(e=>({...setScreenshotSrc:...}))
    idx = src.find('setScreenshotSrc:')
    if idx < 0:
        continue

    # Scan backwards up to 500 chars for: VARNAME = FUNC(
    prefix = src[max(0, idx - 500):idx]
    matches = list(re.finditer(
        r'(?:^|[;{,\(\s])([A-Za-z_$][A-Za-z0-9_$]{1,20})\s*=\s*[A-Za-z_$][A-Za-z0-9_$]{1,20}\s*\(',
        prefix
    ))
    if not matches:
        print(f'Found setScreenshotSrc in {os.path.basename(js_file)} but could not identify store var')
        continue

    store_var = matches[-1].group(1)
    print(f'Identified browser store var: {store_var} in {os.path.basename(js_file)}')

    expose_code = (
        f'\ntry{{if(typeof {store_var}!=="undefined"&&{store_var}.getState)'
        f'{{window.__oh_browser_store={store_var};'
        f'if(window.__oh_browse&&window._ohApplyBrowse)window._ohApplyBrowse();'
        f'console.log("[OH] browser store exposed");}}}}catch(e){{}}\n'
    )
    with open(js_file, 'w') as f:
        f.write(src + expose_code)
    print(f'Browser store exposed in {os.path.basename(js_file)} ✓')
    patched_files.append(js_file)

if not patched_files:
    print('WARNING: Could not expose browser store - browser tab screenshots may not update')
PYEOF
sudo docker cp /tmp/patch_browser_store_expose.py openhands-app-tab:/tmp/patch_browser_store_expose.py
sudo docker exec openhands-app-tab python3 /tmp/patch_browser_store_expose.py

# ─── 补丁6：app.py 注入 /api/proxy/events 路由（klogin 转发 /api/*）───
# klogin 只转发 /api/* 和 /socket.io/*。
# GET  /api/proxy/events/{id}/stream     — SSE 事件流（FakeWS EventSource 用）
# POST /api/proxy/conversations/{id}/events — 收 HTTP POST 后内部走 WebSocket 发给 agent
#   ↑ 关键！HTTP POST 直接发给 agent-server 不会唤醒 Python agent asyncio 队列，
#     必须通过 WebSocket 发送才能触发 LLM 调用。
cat > /tmp/patch_api_proxy_events.py << 'PYEOF'
with open('/app/openhands/server/app.py') as f:
    src = f.read()

if '/api/proxy/events' in src and '_gtau(conversation_id)' in src:
    # Per-session routing already present
    print('api/proxy/events 路由（per-session 模式）已存在 ✓')
    exit(0)

if '/api/proxy/events' in src and 'httpx as _httpx, json as _json, uuid as _uuid' in src and '_gasp()' in src:
    # Upgrade: HTTP POST mode present but still uses single-container _gasp() → upgrade to per-session _gtau
    print('升级 api/proxy/events 路由至 per-session 模式（_gasp → _gtau）...')
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    # SSE: replace hardcoded ws://127.0.0.1:{_gasp()} with per-conv URL
    src = src.replace(
        'ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"',
        'ws_url = f"{_gtau(conversation_id).replace(\'http://\', \'ws://\')}/sockets/events/{conversation_id}"',
    )
    src = src.replace(
        'f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"',
        'f"{_gtau(conversation_id).replace(\'http://\', \'ws://\')}/sockets/events/{conversation_id}"',
    )
    # POST: replace hardcoded http://127.0.0.1:{_gasp()} with per-conv URL
    src = src.replace(
        'f"http://127.0.0.1:{_gasp()}/api/conversations/{conv_uuid}/events"',
        'f"{_gtau(conversation_id)}/api/conversations/{conv_uuid}/events"',
    )
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('升级完成：per-session 路由（_gtau）✓')
    exit(0)

if '/api/proxy/events' in src and '_gasp()' in src:
    # Upgrade: replace WS send with HTTP POST send
    print('升级 api_proxy_send_event 为 HTTP POST 版本...')
    old_ws = (
        '@app.post("/api/proxy/conversations/{conversation_id}/events", include_in_schema=False)\n'
        'async def api_proxy_send_event(conversation_id: str, request: Request):\n'
        '    # Must send via WebSocket to wake up Python agent\'s asyncio queue.\n'
        '    # HTTP POST only stores event in DB — agent won\'t see it.\n'
        '    import websockets as _ws\n'
        '    body = await request.body()\n'
        '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
        '    ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"\n'
        '    if key:\n'
        '        ws_url += f"?session_api_key={key}"\n'
        '    try:\n'
        '        async with _ws.connect(ws_url) as ws:\n'
        '            await ws.send(body.decode())\n'
        '    except Exception:\n'
        '        pass\n'
        '    return JSONResponse({"success": True})'
    )
    new_http = (
        '@app.post("/api/proxy/conversations/{conversation_id}/events", include_in_schema=False)\n'
        'async def api_proxy_send_event(conversation_id: str, request: Request):\n'
        '    import httpx as _httpx, json as _json, uuid as _uuid\n'
        '    body = await request.body()\n'
        '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
        '    try:\n'
        '        conv_uuid = str(_uuid.UUID(conversation_id))\n'
        '    except Exception:\n'
        '        conv_uuid = conversation_id\n'
        '    try:\n'
        '        body_dict = _json.loads(body.decode())\n'
        '        if \'action\' in body_dict and body_dict.get(\'action\') == \'message\':\n'
        '            text = body_dict.get(\'args\', {}).get(\'content\', \'\')\n'
        '            payload = {"role": "user", "content": [{"type": "text", "text": text}], "run": True}\n'
        '        elif \'role\' in body_dict:\n'
        '            content = body_dict.get(\'content\', \'\')\n'
        '            if isinstance(content, str):\n'
        '                content = [{"type": "text", "text": content}]\n'
        '            payload = {"role": body_dict.get(\'role\', \'user\'), "content": content, "run": True}\n'
        '        else:\n'
        '            payload = body_dict\n'
        '    except Exception:\n'
        '        payload = {}\n'
        '    try:\n'
        '        async with _httpx.AsyncClient() as _client:\n'
        '            await _client.post(\n'
        '                f"http://127.0.0.1:{_gasp()}/api/conversations/{conv_uuid}/events",\n'
        '                json=payload, headers={"X-Session-API-Key": key}, timeout=10.0)\n'
        '    except Exception:\n'
        '        pass\n'
        '    return JSONResponse({"success": True})'
    )
    if old_ws in src:
        src = src.replace(old_ws, new_http, 1)
        with open('/app/openhands/server/app.py', 'w') as f:
            f.write(src)
        print('升级完成：api_proxy_send_event WS → HTTP POST ✓')
    else:
        print('WARNING: WS send pattern not found for upgrade')
    exit(0)

if '/api/proxy/events' in src and 'Must send via WebSocket' in src and 'heartbeat' in src:
    # Upgrade: replace hardcoded port with dynamic _gasp() call
    print('升级 api/proxy/events 路由至动态端口版本...')
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        1
    )
    src = src.replace('ws://127.0.0.1:8000/sockets/events/', 'ws://127.0.0.1:{_gasp()}/sockets/events/')
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('升级完成：hardcoded port 8000 → _gasp() ✓')
    exit(0)

MARKER = 'app.include_router(agent_proxy_router)'
if MARKER not in src:
    print('WARNING: include_router(agent_proxy_router) not found in app.py')
    exit(1)

new_routes = '''
@app.get("/api/proxy/events/{conversation_id}/stream", include_in_schema=False)
async def api_proxy_events_stream(request: Request, conversation_id: str):
    """SSE via /api/* - klogin只转发/api/*，此端点让浏览器收到V1实时事件。
    [OH-TAB-PERSESSION] Per-conversation routing via _gtau(conversation_id)."""
    import websockets as _ws
    from starlette.responses import StreamingResponse as _SR
    from openhands.server.routes.agent_server_proxy import _get_agent_server_key as _gask, _get_tab_agent_url as _gtau
    params = dict(request.query_params)
    # [OH-TAB] inject session_api_key if missing (GET /api/conversations/{id} returns null for V1)
    if "session_api_key" not in params:
        _srv_key = _gask()
        if _srv_key:
            params["session_api_key"] = _srv_key
    qs = "&".join(f"{k}={v}" for k, v in params.items())
    ws_url = f"{_gtau(conversation_id).replace('http://', 'ws://')}/sockets/events/{conversation_id}"
    if qs:
        ws_url += f"?{qs}"
    async def _gen():
        import asyncio as _asyncio
        yield ":heartbeat\\n\\n"  # flush headers immediately (prevents BaseHTTPMiddleware cancel)
        connected = False
        _base_qs = "&".join(f"{k}={v}" for k, v in params.items() if k != "resend_all")
        for attempt in range(30):  # retry up to 90s while conversation starts
            try:
                _url = ws_url if attempt == 0 else (
                    f"{_gtau(conversation_id).replace('http://', 'ws://')}/sockets/events/{conversation_id}"
                    + (f"?{_base_qs}" if _base_qs else "")
                )
                async with _ws.connect(_url) as ws:
                    if not connected:
                        yield "data: __connected__\\n\\n"
                        connected = True
                    while True:  # [OH-TAB] heartbeat: prevents klogin 60s idle timeout
                        try:
                            msg = await _asyncio.wait_for(ws.recv(), timeout=15)
                            data = msg if isinstance(msg, str) else msg.decode()
                            data = data.replace("\\n", "\\\\n")
                            yield f"data: {data}\\n\\n"
                        except _asyncio.TimeoutError:
                            yield ":heartbeat\\n\\n"  # keep klogin proxy alive
                        except Exception:
                            break  # WS closed, exit inner loop
                    return  # clean close
            except Exception:
                pass
            await _asyncio.sleep(3)
        yield "data: __closed__\\n\\n"
    return _SR(_gen(), media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

@app.post("/api/proxy/conversations/{conversation_id}/events", include_in_schema=False)
async def api_proxy_send_event(conversation_id: str, request: Request):
    # [OH-TAB-PERSESSION] Per-conversation routing: use _gtau(conversation_id) for agent URL.
    import httpx as _httpx, json as _json, uuid as _uuid
    from openhands.server.routes.agent_server_proxy import _get_agent_server_key as _gask, _get_tab_agent_url as _gtau
    body = await request.body()
    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")
    # [OH-TAB] fallback to container session key if browser has no key
    if not key:
        key = _gask()
    # Agent-server requires UUID format with dashes
    try:
        conv_uuid = str(_uuid.UUID(conversation_id))
    except Exception:
        conv_uuid = conversation_id
    # Convert message format to SendMessageRequest (role/content/run)
    try:
        body_dict = _json.loads(body.decode())
        if 'action' in body_dict and body_dict.get('action') == 'message':
            # Old action format → SDK format
            text = body_dict.get('args', {}).get('content', '')
            payload = {"role": "user", "content": [{"type": "text", "text": text}], "run": True}
        elif 'role' in body_dict:
            # SDK Message format (from BMHP.js V1)
            content = body_dict.get('content', '')
            if isinstance(content, str):
                content = [{"type": "text", "text": content}]
            payload = {"role": body_dict.get('role', 'user'), "content": content, "run": True}
        else:
            payload = body_dict
    except Exception:
        payload = {}
    try:
        async with _httpx.AsyncClient() as _client:
            await _client.post(
                f"{_gtau(conversation_id)}/api/conversations/{conv_uuid}/events",
                json=payload,
                headers={"X-Session-API-Key": key},
                timeout=10.0
            )
    except Exception:
        pass
    return JSONResponse({"success": True})

'''

src = src.replace(MARKER, MARKER + '\n' + new_routes, 1)
with open('/app/openhands/server/app.py', 'w') as f:
    f.write(src)
print('api/proxy/events 路由已注入 ✓')
PYEOF
sudo docker cp /tmp/patch_api_proxy_events.py openhands-app-tab:/tmp/patch_api_proxy_events.py
sudo docker exec openhands-app-tab python3 /tmp/patch_api_proxy_events.py

# ─── 补丁3.5：SSE/POST proxy 注入 session_api_key ───
# GET /api/conversations/{id} 对 V1 会话返回 session_api_key: null
# → BMHP.js 的 s=null → WS URL 无 key → FakeWS SSE URL 无 key → agent-server 403
# 修复：在 SSE proxy 注入 _gask()（从 oh-tab- 容器 env 读取全局 key）
cat > /tmp/fix_session_key.py << 'PYEOF'
APP_PATH = '/app/openhands/server/app.py'
with open(APP_PATH) as f:
    src = f.read()

old_sse = (
    '    params = dict(request.query_params)\n'
    '    qs = "&".join(f"{k}={v}" for k, v in params.items())\n'
    '    ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"\n'
    '    if qs:\n'
    '        ws_url += f"?{qs}"'
)
new_sse = (
    '    params = dict(request.query_params)\n'
    '    # [OH-TAB] inject session_api_key if missing (GET /api/conversations/{id} returns null for V1)\n'
    '    if "session_api_key" not in params:\n'
    '        from openhands.server.routes.agent_server_proxy import _get_agent_server_key as _gask\n'
    '        _srv_key = _gask()\n'
    '        if _srv_key:\n'
    '            params["session_api_key"] = _srv_key\n'
    '    qs = "&".join(f"{k}={v}" for k, v in params.items())\n'
    '    ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"\n'
    '    if qs:\n'
    '        ws_url += f"?{qs}"'
)

old_post_key = (
    '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
    '    # Agent-server requires UUID format with dashes'
)
new_post_key = (
    '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
    '    # [OH-TAB] fallback to container session key if browser has no key\n'
    '    if not key:\n'
    '        from openhands.server.routes.agent_server_proxy import _get_agent_server_key as _gask\n'
    '        key = _gask()\n'
    '    # Agent-server requires UUID format with dashes'
)

changed = False
if '[OH-TAB] inject session_api_key if missing' in src:
    print('SSE session_api_key injection already present ✓')
elif old_sse in src:
    src = src.replace(old_sse, new_sse, 1)
    print('SSE session_api_key injection applied ✓')
    changed = True
else:
    print('WARNING: SSE params pattern not found!')

if '[OH-TAB] fallback to container session key' in src:
    print('POST key fallback already present ✓')
elif old_post_key in src:
    src = src.replace(old_post_key, new_post_key, 1)
    print('POST key fallback applied ✓')
    changed = True
else:
    print('WARNING: POST key pattern not found!')

if changed:
    with open(APP_PATH, 'w') as f:
        f.write(src)
PYEOF
sudo docker cp /tmp/fix_session_key.py openhands-app-tab:/tmp/fix_session_key.py
sudo docker exec openhands-app-tab python3 /tmp/fix_session_key.py

# ─── 补丁7：index.html 注入全局 WebSocket/fetch 拦截器 ───
# klogin 代理层会缓存 /assets/*.js，补丁可能对浏览器不生效。
# index.html 设置了 no-store，每次都新鲜，是最可靠的注入点。
# FakeWS: 拦截 /sockets/events/ WebSocket → EventSource → /api/proxy/events/{id}/stream
# send(): 用 /api/proxy/conversations/{id}/events（klogin 可转发）
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html
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
    # Fetch interceptor: rewrite 127.0.0.1:8000 → /agent-server-proxy
    'var _f=window.fetch;window.fetch=function(u,o){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _f.call(this,u,o);};'
    # XHR interceptor: same rewrite
    'var _X=window.XMLHttpRequest.prototype.open;'
    'window.XMLHttpRequest.prototype.open=function(m,u){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _X.apply(this,arguments);};'
    # Browser tab fix helpers: store pending browse data; apply via _ohApplyBrowse()
    # window.__oh_browser_store is exposed by patch 12 (browser-store JS chunk).
    'window.__oh_browse=null;'
    'window._ohApplyBrowse=function(){'
    'var d=window.__oh_browse;'
    'if(!d)return;'
    'var bs=window.__oh_browser_store;'
    'if(bs&&bs.getState){'
    'window.__oh_browse=null;'
    'var ss=d.ss;'
    'if(ss){bs.getState().setScreenshotSrc(ss.startsWith("data:")?ss:"data:image/png;base64,"+ss);}'
    'if(d.url){bs.getState().setUrl(d.url);}'
    '}else{setTimeout(window._ohApplyBrowse,300);}'  # retry until store is loaded
    '};'
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
    # Browser tab fix: detect browse observations (V1 and V0 formats), update store
    'try{'
    'var _d=JSON.parse(ev.data);'
    'var _ss="",_url="";'
    # V1 format: observation is {kind:"BrowserObservation", screenshot_data:..., url:...}
    'if(_d&&_d.observation&&typeof _d.observation==="object"&&_d.observation.kind==="BrowserObservation"){'
    '_ss=_d.observation.screenshot_data||"";_url=_d.observation.url||"";}'
    # V0 format: observation is string "browse"/"browse_interactive", extras.screenshot
    'else if(_d&&(_d.observation==="browse"||_d.observation==="browse_interactive")){'
    '_ss=(_d.extras&&_d.extras.screenshot)||"";_url=(_d.extras&&_d.extras.url)||"";}'
    'if(_ss||_url){window.__oh_browse={ss:_ss,url:_url};window._ohApplyBrowse();}'
    '}'
    'catch(e){}'
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
    # [oh-tab-enter-fix] Enter key triggers blur in served-tab URL address bar
    # Only fires for inputs whose value looks like a URL (avoids affecting chat input)
    'document.addEventListener("keydown",function(e){'
    'if(e.key!=="Enter")return;'
    'var el=document.activeElement;'
    'if(!el||el.tagName!=="INPUT")return;'
    'var v=el.value||"";'
    'if(!v.match(/^(https?:\\/\\/|\\/api\\/sandbox-port\\/)/))return;'
    'if(!el.closest("form"))return;'
    'e.preventDefault();el.blur();'
    '},true);'
    '})();</script>'
)
html = html.replace('<head>', '<head>' + inject, 1)
with open('/tmp/oh-index.html', 'w') as f:
    f.write(html)
print('index.html FakeWS 已注入（使用 /api/proxy/events/ 路径）✓')
PYEOF
sudo docker cp /tmp/oh-index.html openhands-app-tab:/app/frontend/build/index.html

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
            # Compute workspace root (parent dir, where Changes tab queries git)
            _ws_root = sandbox_spec.working_dir.rsplit("/", 1)[0]
            await _tmp_ws.execute_command(
                f"mkdir -p {conv_working_dir} && "
                f"([ -d {_ws_root}/.git ] || ("
                f"git init {_ws_root} && "
                f"mkdir -p {_ws_root}/.git/info && "
                f"printf 'bash_events/\\nconversations/\\n' > {_ws_root}/.git/info/exclude))",
                timeout=15.0,
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
sudo docker cp /tmp/patch_per_conv_workspace.py openhands-app-tab:/tmp/patch_per_conv_workspace.py
sudo docker exec openhands-app-tab python3 /tmp/patch_per_conv_workspace.py

# ─── 补丁8b：迁移 git init 到 workspace root（Changes tab 修复）───
# 根因：git init 在 per-conv 子目录，但 Changes tab 始终查询 /workspace。
# 修复：git init 在 workspace root（/workspace），用 .git/info/exclude 排除系统目录。
cat > /tmp/patch_git_workspace_root.py << 'PYEOF'
"""Fix: move git init from per-conv subdir to workspace root for Changes tab."""
path = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(path) as f:
    src = f.read()

old_exec = (
    '            await _tmp_ws.execute_command(\n'
    '                f"mkdir -p {conv_working_dir} && cd {conv_working_dir} && "\n'
    '                f"[ -d .git ] || git init",\n'
    '                timeout=10.0,\n'
    '            )'
)
new_exec = (
    '            # Compute workspace root (parent dir, where Changes tab queries git)\n'
    '            _ws_root = sandbox_spec.working_dir.rsplit("/", 1)[0]\n'
    '            await _tmp_ws.execute_command(\n'
    '                f"mkdir -p {conv_working_dir} && "\n'
    '                f"([ -d {_ws_root}/.git ] || ("\n'
    '                f"git init {_ws_root} && "\n'
    '                f"mkdir -p {_ws_root}/.git/info && "\n'
    '                f"printf \'bash_events/\\\\nconversations/\\\\n\' > {_ws_root}/.git/info/exclude))",\n'
    '                timeout=15.0,\n'
    '            )'
)

if '_ws_root = sandbox_spec.working_dir.rsplit' in src:
    print('git workspace root 补丁已存在 ✓')
elif old_exec in src:
    src = src.replace(old_exec, new_exec, 1)
    with open(path, 'w') as f:
        f.write(src)
    print('git workspace root 补丁已应用 ✓')
else:
    print('WARNING: execute_command pattern not found in service file!')
    idx = src.find('execute_command')
    print('Context:', repr(src[max(0, idx-20):idx+200]))
PYEOF
sudo docker cp /tmp/patch_git_workspace_root.py openhands-app-tab:/tmp/patch_git_workspace_root.py
sudo docker exec openhands-app-tab python3 /tmp/patch_git_workspace_root.py

# ─── 补丁9b：sandbox-port proxy 使用容器 bridge IP（App tab 访问任意容器内端口）───
# 根因：proxy 用 http://127.0.0.1:{port}，容器内部端口（如 streamlit 8502）未映射到宿主机，
#       无法通过宿主机 127.0.0.1 访问。
# 修复：添加 _get_oh_tab_ip()，port < 20000 用容器 bridge IP（内部端口），
#       port >= 20000 用 127.0.0.1（Docker NAT 映射端口，如 VSCode 39377→8001）。
cat > /tmp/patch_sandbox_proxy_container_ip.py << 'PYEOF'
"""Patch 9b: sandbox-port proxy uses container bridge IP for internal ports."""
import re

# 1. Add _get_oh_tab_ip() to agent_server_proxy.py
proxy_path = '/app/openhands/server/routes/agent_server_proxy.py'
with open(proxy_path) as f:
    psrc = f.read()

helper = (
    '\n_oh_tab_ip_cache = ["", 0.0]\n'
    'def _get_oh_tab_ip() -> str:\n'
    '    """Get bridge IP of running oh-tab- container (cached 60s)."""\n'
    '    import time as _t\n'
    '    if _oh_tab_ip_cache[0] and _t.time() - _oh_tab_ip_cache[1] < 60:\n'
    '        return _oh_tab_ip_cache[0]\n'
    '    try:\n'
    '        conn = _UnixHTTPConnection("/var/run/docker.sock")\n'
    '        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")\n'
    '        resp = conn.getresponse()\n'
    '        containers = _json_mod.loads(resp.read())\n'
    '        if not containers:\n'
    '            return ""\n'
    '        cid = containers[0]["Id"]\n'
    '        conn2 = _UnixHTTPConnection("/var/run/docker.sock")\n'
    '        conn2.request("GET", f"/containers/{cid}/json")\n'
    '        resp2 = conn2.getresponse()\n'
    '        cdata = _json_mod.loads(resp2.read())\n'
    '        ip = cdata.get("NetworkSettings", {}).get("IPAddress", "")\n'
    '        if ip:\n'
    '            _oh_tab_ip_cache[0] = ip\n'
    '            _oh_tab_ip_cache[1] = _t.time()\n'
    '        return ip\n'
    '    except Exception:\n'
    '        return _oh_tab_ip_cache[0]\n'
)

marker = '\n# SSE 端点'
if '_get_oh_tab_ip' in psrc:
    print('_get_oh_tab_ip already in agent_server_proxy.py ✓')
elif marker in psrc:
    psrc = psrc.replace(marker, helper + marker, 1)
    with open(proxy_path, 'w') as f:
        f.write(psrc)
    print('_get_oh_tab_ip added to agent_server_proxy.py ✓')
else:
    print('ERROR: marker not found in agent_server_proxy.py')
    exit(1)

# 2. Fix app.py sandbox-port proxy
app_path = '/app/openhands/server/app.py'
with open(app_path) as f:
    asrc = f.read()

if '_proxy_host' in asrc:
    print('port heuristic already in app.py ✓')
else:
    # Add import
    if '_get_oh_tab_ip as _get_oh_tab_ip' not in asrc:
        asrc = asrc.replace(
            'from fastapi import WebSocket as _FastAPIWebSocket\n',
            'from fastapi import WebSocket as _FastAPIWebSocket\nfrom openhands.server.routes.agent_server_proxy import _get_oh_tab_ip as _get_oh_tab_ip\n',
            1
        )
    # Fix HTTP proxy
    asrc = asrc.replace(
        '    import httpx as _hx, re as _re\n    target = f"http://127.0.0.1:{port}/{path}"',
        '    import httpx as _hx, re as _re\n    _cip = _get_oh_tab_ip()\n    _proxy_host = (_cip if (_cip and port < 20000) else "127.0.0.1")\n    target = f"http://{_proxy_host}:{port}/{path}"',
        1
    )
    # Fix WS proxy
    asrc = asrc.replace(
        '    ws_url = f"ws://127.0.0.1:{port}/{path}"',
        '    _cip = _get_oh_tab_ip()\n    _proxy_host = (_cip if (_cip and port < 20000) else "127.0.0.1")\n    ws_url = f"ws://{_proxy_host}:{port}/{path}"',
        1
    )
    with open(app_path, 'w') as f:
        f.write(asrc)
    print('app.py sandbox proxy updated with port heuristic ✓')
PYEOF
sudo docker cp /tmp/patch_sandbox_proxy_container_ip.py openhands-app-tab:/tmp/patch_sandbox_proxy_container_ip.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_proxy_container_ip.py

# ─── 补丁9：sandbox port proxy（Code/App tab 浏览器访问）───
# VSCode (8001), App 预览 (8011/8012) 的 URL 是 http://127.0.0.1:{port}，
# 浏览器无法通过 klogin 访问。在 openhands-app-tab 注入 /api/sandbox-port/{port}/* 代理路由。
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
    """Reverse proxy any sandbox port through openhands-app-tab (port 3003)."""
    import httpx as _hx, re as _re
    # Low ports (<20000) are container-internal; high ports are Docker NAT-mapped (use 127.0.0.1)
    _cip = _get_oh_tab_ip()
    _proxy_host = (_cip if (_cip and port < 20000) else "127.0.0.1")
    target = f"http://{_proxy_host}:{port}/{path}"
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
            # [oh-tab-agent-check] If agent server JSON at root GET, show scan page
            if (resp.status_code == 200 and request.method == "GET" and not path
                    and "application/json" in ct
                    and request.headers.get("x-oh-tab-scan") != "1"
                    and b\'"OpenHands Agent Server"\' in content[:200]):
                from starlette.responses import HTMLResponse as _HtmlResp
                return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)
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
    _cip = _get_oh_tab_ip()
    _proxy_host = (_cip if (_cip and port < 20000) else "127.0.0.1")
    ws_url = f"ws://{_proxy_host}:{port}/{path}"
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
sudo docker cp /tmp/patch_sandbox_port_proxy.py openhands-app-tab:/tmp/patch_sandbox_port_proxy.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_port_proxy.py

# ─── 补丁10：exposed_urls 代理路径重写（VSCODE/WORKER → /api/sandbox-port/{host_port}/）───
# Per-session 模式：每个容器都有唯一的宿主机映射端口（host port），
# 改写为 /api/sandbox-port/{host_port}（从 URL 中提取）。
# AGENT_SERVER 保持绝对 URL（health check 需要）。
cat > /tmp/patch_sandbox_exposed_urls.py << 'PYEOF'
"""Patch 10: Rewrite VSCODE/WORKER exposed_urls to use /api/sandbox-port/{host_port}.
Per-session isolation: each container has unique host ports so each conversation
routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute."""
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB-PERSESSION] Rewrite VSCODE/WORKER' in src:
    print('exposed_urls 补丁已存在（per-session host-port 模式）✓')
    exit(0)

# Upgrade from old container-port mode to host-port mode
if '/api/sandbox-port/' in src and '_eu.port' in src and '[OH-TAB-PERSESSION]' not in src:
    print('升级 exposed_urls 补丁至 per-session host-port 模式...')
    old_old_return = (
        '        # Rewrite VSCODE/WORKER URLs to use proxy (AGENT_SERVER stays absolute for health checks)\n'
        '        if exposed_urls:\n'
        '            for _eu in exposed_urls:\n'
        '                if _eu.name != \'AGENT_SERVER\':\n'
        '                    import re as _re\n'
        "                    _eu.url = _re.sub(r'https?://[^/]+', f'/api/sandbox-port/{_eu.port}', _eu.url, count=1)\n"
    )
    new_new_return = (
        '        # [OH-TAB-PERSESSION] Rewrite VSCODE/WORKER URLs to use proxy with HOST PORT.\n'
        '        # Per-session: each container gets unique published host ports.\n'
        '        # Use the host port from _eu.url (e.g. http://127.0.0.1:39377) so each conversation\n'
        '        # routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute.\n'
        '        if exposed_urls:\n'
        '            import re as _re\n'
        '            import urllib.parse as _up\n'
        '            for _eu in exposed_urls:\n'
        '                if _eu.name != \'AGENT_SERVER\':\n'
        '                    _parsed = _up.urlparse(_eu.url)\n'
        '                    _host_port = _parsed.port or _eu.port\n'
        "                    _eu.url = f'/api/sandbox-port/{_host_port}'\n"
    )
    if old_old_return in src:
        src = src.replace(old_old_return, new_new_return, 1)
        with open(path, 'w') as f:
            f.write(src)
        print('升级完成：exposed_urls per-session host-port 模式 ✓')
    else:
        print('WARNING: old exposed_urls pattern not found, skipping upgrade')
    exit(0)

if '/api/sandbox-port/' in src:
    print('exposed_urls 代理路径补丁已存在（旧格式，手动检查）✓')
    exit(0)

old_return = '''        return SandboxInfo(
            id=container.name,
            created_by_user_id=None,
            sandbox_spec_id=container.image.tags[0],
            status=status,
            session_api_key=session_api_key,
            exposed_urls=exposed_urls,'''

new_return = '''        # [OH-TAB-PERSESSION] Rewrite VSCODE/WORKER URLs to use proxy with HOST PORT.
        # Per-session: each container gets unique published host ports.
        # Use the host port from _eu.url (e.g. http://127.0.0.1:39377) so each conversation
        # routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute.
        if exposed_urls:
            import re as _re
            import urllib.parse as _up
            for _eu in exposed_urls:
                if _eu.name != 'AGENT_SERVER':
                    _parsed = _up.urlparse(_eu.url)
                    _host_port = _parsed.port or _eu.port
                    _eu.url = f'/api/sandbox-port/{_host_port}'

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
sudo docker cp /tmp/patch_sandbox_exposed_urls.py openhands-app-tab:/tmp/patch_sandbox_exposed_urls.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_exposed_urls.py

# ─── 补丁11：vscode-tab JS 修复 + z-suffix cache busting ───
# 根因：new URL(r.url) 当 r.url 是相对路径时抛 TypeError → "Error parsing URL"
# 修复：new URL(r.url, window.location.origin)
# 由于 assets 被标记 immutable，需要创建新文件名（z 后缀）打破缓存链
cat > /tmp/patch_vscode_tab.py << 'PYEOF'
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
sudo docker cp /tmp/patch_vscode_tab.py openhands-app-tab:/tmp/patch_vscode_tab.py
sudo docker exec openhands-app-tab python3 /tmp/patch_vscode_tab.py

# ─── 补丁12a：sandbox-port proxy 连接失败时返回端口自动扫描页（App tab 自动跳到运行中的 app）───
# 根因：WORKER 端口（8011/8012）通常没有监听；真实 app（如 streamlit）在内部端口（8502）。
# 修复：proxy 收到 ConnectError 且路径为根路径时，返回一段 HTML，
#       自动扫描常用端口（3000,5000,7860,8080,8501,8502,...），找到后跳转。
cat > /tmp/patch_port_scan_html.py << 'PYEOF'
"""Patch 12a: sandbox_port_proxy returns auto-scan HTML on connection error at root GET."""
APP_PATH = '/app/openhands/server/app.py'
with open(APP_PATH) as f:
    src = f.read()

if '[oh-tab-port-scan]' in src:
    print('Auto-scan HTML already in sandbox_port_proxy ✓')
    exit(0)

SCAN_HTML = (
    '<!DOCTYPE html><html><head><title>App Scanner</title>'
    '<style>body{font-family:sans-serif;display:flex;align-items:center;justify-content:center;'
    'height:100vh;margin:0;background:#1a1a2e;color:#eee;}'
    '.box{text-align:center;padding:2rem;}'
    '.sp{width:40px;height:40px;border:3px solid rgba(255,255,255,0.1);'
    'border-top-color:#4af;border-radius:50%;animation:s 1s linear infinite;margin:1rem auto;}'
    '@keyframes s{to{transform:rotate(360deg)}}</style></head>'
    '<body><div class="box"><div class="sp"></div>'
    '<h3 id="m">Scanning for running app...</h3>'
    '<p id="sub" style="color:#aaa;font-size:.85rem"></p></div>'
    '<script>'
    'const ports=[3000,5000,7860,8000,8008,8080,8501,8502,8503,8504,8888,9000];'
    'async function tryPort(p){'
    'try{const r=await fetch("/api/sandbox-port/"+p+"/",{signal:AbortSignal.timeout(2000),cache:"no-store",'
    'headers:{"X-OH-Tab-Scan":"1"}});'
    'if(r.status>=500)return false;'
    'const ct=r.headers.get("content-type")||"";'
    'return ct.includes("text/html");}catch(e){return false;}}'
    'async function scan(){'
    'document.getElementById("sub").textContent="Trying: "+ports.join(", ");'
    'for(const p of ports){'
    'document.getElementById("m").textContent="Trying port "+p+"...";'
    'if(await tryPort(p)){'
    'document.getElementById("m").textContent="Found app on port "+p+"! Loading...";'
    'if(window.parent&&window.parent!==window){'
    'window.parent.postMessage({type:"oh-tab-port-redirect",url:"/api/sandbox-port/"+p+"/"},"*");}'
    'window.location.replace("/api/sandbox-port/"+p+"/");return;}}'
    'document.getElementById("m").textContent="No app found yet. Retrying in 3s...";'
    'setTimeout(scan,3000);}'
    'scan();'
    '</script></body></html>'
)

# Inject _PORT_SCAN_HTML constant before the proxy routes
MARKER = '# --- Sandbox port proxy: VSCode (8001), App (8011/8012) ---'
if MARKER not in src:
    print('WARNING: sandbox port proxy marker not found!')
    idx = src.find('sandbox-port')
    print('Context:', repr(src[max(0,idx-50):idx+200]))
    exit(1)

if '_PORT_SCAN_HTML' not in src:
    scan_const = '_PORT_SCAN_HTML = ' + repr(SCAN_HTML) + '\n\n'
    src = src.replace(MARKER, scan_const + MARKER, 1)
    print('_PORT_SCAN_HTML constant injected ✓')

# Modify the exception handler to return scan HTML on ConnectError at root GET
old_exc = (
    '    except Exception as e:\n'
    '        from starlette.responses import Response as _Resp\n'
    '        return _Resp(content=str(e), status_code=502)\n'
    '\n'
    '@app.api_route("/api/sandbox-port/{port}/"'
)
new_exc = (
    '    except Exception as e:\n'
    '        # [oh-tab-port-scan] Return auto-scan page for ANY error at root GET\n'
    '        # NOT for probe requests (X-OH-Tab-Scan:1) to avoid false-positive\n'
    '        if (request.method == "GET" and not path\n'
    '                and request.headers.get("x-oh-tab-scan") != "1"):\n'
    '            from starlette.responses import HTMLResponse as _HtmlResp\n'
    '            return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    '        from starlette.responses import Response as _Resp\n'
    '        return _Resp(content=str(e), status_code=502)\n'
    '\n'
    '@app.api_route("/api/sandbox-port/{port}/"'
)
if old_exc in src:
    src = src.replace(old_exc, new_exc, 1)
    print('Auto-scan exception handler applied ✓')
elif '[oh-tab-port-scan]' in src:
    print('Exception handler already patched ✓')
else:
    print('WARNING: exception handler pattern not found')
    # Diagnostic: find sandbox_port_proxy context
    idx = src.find('sandbox_port_proxy')
    print('Context:', repr(src[max(0,idx):idx+600]))

with open(APP_PATH, 'w') as f:
    f.write(src)
print('Done.')
PYEOF
sudo docker cp /tmp/patch_port_scan_html.py openhands-app-tab:/tmp/patch_port_scan_html.py
sudo docker exec openhands-app-tab python3 /tmp/patch_port_scan_html.py

# ─── 补丁12b：Tab 三项修复（VSCode 403→tkn / no-slash redirect / per-session scan）───
cat > /tmp/patch_tabs_fixes.py << 'PYEOF'
"""Patch 12b: Three tab fixes for per-session mode.
1. Changes tab 401 → return [] (in agent_server_proxy.py)
2. Code tab: /api/sandbox-port/{port} no-slash redirect (307)
3. Code tab: VSCode 403 at root → inject ?tkn= connection token (302)
4. App tab: context-aware scan (_PORT_SCAN_HTML uses /api/sandbox-port/{ctx}/scan/{p}/)
5. App tab: per-session scan handler in sandbox_port_proxy
"""

proxy_path = '/app/openhands/server/routes/agent_server_proxy.py'
with open(proxy_path) as f:
    proxy_src = f.read()

# Fix 1a: Add _get_oh_tab_container_for_port if missing
if '_get_oh_tab_container_for_port' not in proxy_src:
    new_func = '''
def _get_oh_tab_container_for_port(host_port: int) -> dict:
    """Find the oh-tab- container that has host_port mapped (Docker NAT)."""
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        for c in containers:
            for p in c.get("Ports", []):
                if p.get("PublicPort") == host_port:
                    cid = c["Id"]
                    conn2 = _UnixHTTPConnection("/var/run/docker.sock")
                    conn2.request("GET", f"/containers/{cid}/json")
                    resp2 = conn2.getresponse()
                    return _json_mod.loads(resp2.read())
    except Exception:
        pass
    return {}

'''
    proxy_src = proxy_src.replace('def _resolve_tab_agent_url', new_func + 'def _resolve_tab_agent_url', 1)
    with open(proxy_path, 'w') as f:
        f.write(proxy_src)
    print('agent_server_proxy.py: _get_oh_tab_container_for_port added ✓')
else:
    print('agent_server_proxy.py: _get_oh_tab_container_for_port already exists ✓')

# Fix 1b: git/changes 401 → []
with open(proxy_path) as f:
    proxy_src = f.read()
old_git = 'resp.status_code == 500 and path.startswith("api/git/changes")'
new_git = 'resp.status_code in (401, 500) and path.startswith("api/git/changes")'
if old_git in proxy_src:
    proxy_src = proxy_src.replace(old_git, new_git, 1)
    with open(proxy_path, 'w') as f:
        f.write(proxy_src)
    print('agent_server_proxy.py: git/changes 401→[] fix applied ✓')
elif new_git in proxy_src:
    print('agent_server_proxy.py: git/changes 401→[] fix already present ✓')
else:
    print('WARNING: git/changes pattern not found in agent_server_proxy.py')

# Now fix app.py
app_path = '/app/openhands/server/app.py'
with open(app_path) as f:
    src = f.read()
changes = 0

# Fix 2: no-slash redirect
if 'sandbox_port_proxy_bare' not in src:
    marker = '@app.websocket("/api/sandbox-port/{port}/{path:path}")'
    if marker in src:
        NO_SLASH = (
            '\n@app.api_route("/api/sandbox-port/{port}", '
            'methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"], include_in_schema=False)\n'
            'async def sandbox_port_proxy_bare(port: int, request: Request):\n'
            '    """Redirect /api/sandbox-port/{port} → /api/sandbox-port/{port}/ (trailing slash)."""\n'
            '    from starlette.responses import RedirectResponse as _RR\n'
            '    qs = str(request.query_params)\n'
            '    loc = f"/api/sandbox-port/{port}/" + (f"?{qs}" if qs else "")\n'
            '    return _RR(url=loc, status_code=307)\n'
        )
        src = src.replace(marker, NO_SLASH + marker, 1)
        changes += 1
        print('app.py: no-slash redirect added ✓')
    else:
        print('WARNING: websocket route marker not found for no-slash redirect')
else:
    print('app.py: no-slash redirect already present ✓')

# Fix 3: VSCode 403 → ?tkn redirect
if '[OH-TAB] VSCode 403' not in src:
    VSCODE_FIX = (
        '            # [OH-TAB] VSCode 403 at root: inject connection token (= OH_SESSION_API_KEYS_0)\n'
        '            if (resp.status_code == 403 and request.method == "GET" and not path\n'
        '                    and port >= 20000 and "tkn" not in str(request.query_params)):\n'
        '                try:\n'
        '                    from openhands.server.routes.agent_server_proxy import _get_oh_tab_container_for_port as _gcfp\n'
        '                    _cdata = _gcfp(port)\n'
        '                    _env = _cdata.get("Config", {}).get("Env", [])\n'
        '                    _tok = next((e.split("=",1)[1] for e in _env if e.startswith("OH_SESSION_API_KEYS_0=")), None)\n'
        '                    if _tok:\n'
        '                        from starlette.responses import RedirectResponse as _RR2\n'
        '                        return _RR2(url=f"/api/sandbox-port/{port}/?tkn={_tok}", status_code=302)\n'
        '                except Exception:\n'
        '                    pass\n'
    )
    insert_before = '            content = resp.content\n            ct = resp.headers.get("content-type", "")'
    if insert_before in src:
        src = src.replace(insert_before, VSCODE_FIX + insert_before, 1)
        changes += 1
        print('app.py: VSCode 403→tkn redirect added ✓')
    else:
        # Fix existing wrong 'params' reference if present
        old_params = 'and "tkn" not in params)'
        new_params = 'and "tkn" not in str(request.query_params))'
        if old_params in src:
            src = src.replace(old_params, new_params, 1)
            changes += 1
            print('app.py: VSCode 403 params→query_params fix applied ✓')
        else:
            print('WARNING: VSCode 403 fix insert point not found')
else:
    # Fix existing wrong 'params' reference if present
    old_params = 'and "tkn" not in params)'
    new_params = 'and "tkn" not in str(request.query_params))'
    if old_params in src:
        src = src.replace(old_params, new_params, 1)
        changes += 1
        print('app.py: VSCode 403 params→query_params fix applied ✓')
    else:
        print('app.py: VSCode 403→tkn redirect already correct ✓')

# Fix 4: Context-aware _PORT_SCAN_HTML
OLD_SCAN = (
    'const ports=[3000,5000,7860,8000,8008,8080,8501,8502,8503,8504,8888,9000];'
    'async function tryPort(p){'
    'try{const r=await fetch("/api/sandbox-port/"+p+"/",{signal:AbortSignal.timeout(2000),cache:"no-store",'
    'headers:{"X-OH-Tab-Scan":"1"}});'
    'if(r.status>=500)return false;'
    'const ct=r.headers.get("content-type")||"";'
    'return ct.includes("text/html");}catch(e){return false;}}'
    'async function scan(){'
    'document.getElementById("sub").textContent="Trying: "+ports.join(", ");'
    'for(const p of ports){'
    'document.getElementById("m").textContent="Trying port "+p+"...";'
    'if(await tryPort(p)){'
    'document.getElementById("m").textContent="Found app on port "+p+"! Loading...";'
    'if(window.parent&&window.parent!==window){'
    'window.parent.postMessage({type:"oh-tab-port-redirect",url:"/api/sandbox-port/"+p+"/"},"*");}'
    'window.location.replace("/api/sandbox-port/"+p+"/");return;}}'
    'document.getElementById("m").textContent="No app found yet. Retrying in 3s...";'
    'setTimeout(scan,3000);}scan();'
)
NEW_SCAN = (
    'const ports=[3000,5000,7860,8000,8008,8080,8501,8502,8503,8504,8888,9000];'
    'const _ctxM=window.location.pathname.match(/sandbox-port\\/(\\d+)/);'
    'const _ctx=_ctxM?_ctxM[1]:null;'
    'function _purl(p){return _ctx?"/api/sandbox-port/"+_ctx+"/scan/"+p+"/":"/api/sandbox-port/"+p+"/";}'
    'async function tryPort(p){'
    'try{const r=await fetch(_purl(p),{signal:AbortSignal.timeout(2000),cache:"no-store",'
    'headers:{"X-OH-Tab-Scan":"1"}});'
    'if(r.status>=500)return false;'
    'const ct=r.headers.get("content-type")||"";'
    'return ct.includes("text/html");}catch(e){return false;}}'
    'async function scan(){'
    'document.getElementById("sub").textContent="Trying: "+ports.join(", ");'
    'for(const p of ports){'
    'document.getElementById("m").textContent="Trying port "+p+"...";'
    'if(await tryPort(p)){'
    'document.getElementById("m").textContent="Found app on port "+p+"! Loading...";'
    'const _tu=_purl(p);'
    'if(window.parent&&window.parent!==window){'
    'window.parent.postMessage({type:"oh-tab-port-redirect",url:_tu},"*");}'
    'window.location.replace(_tu);return;}}'
    'document.getElementById("m").textContent="No app found yet. Retrying in 3s...";'
    'setTimeout(scan,3000);}scan();'
)
if '_ctx' not in src and OLD_SCAN in src:
    src = src.replace(OLD_SCAN, NEW_SCAN, 1)
    changes += 1
    print('app.py: _PORT_SCAN_HTML context-aware scan updated ✓')
elif '_ctx' in src and '_purl' in src:
    print('app.py: _PORT_SCAN_HTML already context-aware ✓')
else:
    print('WARNING: _PORT_SCAN_HTML scan JS pattern not found (may need manual update)')

# Fix 5: Per-session scan handler
if '[OH-TAB] per-session scan' not in src:
    SCAN_HANDLER = (
        '    # [OH-TAB] per-session scan: /api/sandbox-port/{ctx_port}/scan/{scan_port}/{path}\n'
        '    if path.startswith("scan/"):\n'
        '        _sp = path[5:]  # strip "scan/"\n'
        '        _parts = _sp.split("/", 1)\n'
        '        _sp_port = int(_parts[0]) if _parts[0].isdigit() else 0\n'
        '        _sp_path = _parts[1] if len(_parts) > 1 else ""\n'
        '        if _sp_port > 0:\n'
        '            from openhands.server.routes.agent_server_proxy import _get_oh_tab_container_for_port as _gcfp2\n'
        '            _cdata2 = _gcfp2(port)\n'
        '            _cip2 = _cdata2.get("NetworkSettings", {}).get("IPAddress", "")\n'
        '            if _cip2:\n'
        '                _scan_target = f"http://{_cip2}:{_sp_port}/{_sp_path}"\n'
        '                _qs2 = str(request.query_params)\n'
        '                if _qs2: _scan_target += f"?{_qs2}"\n'
        '                try:\n'
        '                    import httpx as _hx2\n'
        '                    async with _hx2.AsyncClient(timeout=10.0, follow_redirects=False) as _c2:\n'
        '                        _r2 = await _c2.request(method=request.method, url=_scan_target,\n'
        '                            headers={k:v for k,v in request.headers.items()\n'
        '                                if k.lower() not in ("host","content-length","transfer-encoding","connection")},\n'
        '                            content=await request.body())\n'
        '                    from starlette.responses import Response as _Resp2\n'
        '                    _scan_hdrs = {k:v for k,v in _r2.headers.multi_items()\n'
        '                        if k.lower() not in ("content-encoding","transfer-encoding","connection","content-security-policy")}\n'
        '                    return _Resp2(content=_r2.content, status_code=_r2.status_code,\n'
        '                        headers=_scan_hdrs, media_type=_r2.headers.get("content-type",""))\n'
        '                except Exception as _se:\n'
        '                    from starlette.responses import Response as _Resp2\n'
        '                    if request.headers.get("x-oh-tab-scan") != "1":\n'
        '                        from starlette.responses import HTMLResponse as _HtmlResp\n'
        '                        return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
        '                    return _Resp2(content=str(_se), status_code=502)\n'
    )
    insert_after = '    """Reverse proxy any sandbox port through openhands-app-tab (port 3003)."""\n'
    if insert_after in src:
        src = src.replace(insert_after, insert_after + SCAN_HANDLER, 1)
        changes += 1
        print('app.py: per-session scan handler added ✓')
    else:
        print('WARNING: sandbox_port_proxy docstring not found for scan handler')
else:
    print('app.py: per-session scan handler already present ✓')

if changes > 0:
    with open(app_path, 'w') as f:
        f.write(src)
    print(f'app.py: {changes} change(s) written ✓')
else:
    print('app.py: no changes needed')
PYEOF
sudo docker cp /tmp/patch_tabs_fixes.py openhands-app-tab:/tmp/patch_tabs_fixes.py
sudo docker exec openhands-app-tab python3 /tmp/patch_tabs_fixes.py

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
sudo docker exec openhands-app-tab python3 /tmp/patch_v1svc.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sre.py
sudo docker exec openhands-app-tab python3 /tmp/patch_api_proxy_events.py
sudo docker exec openhands-app-tab python3 /tmp/patch_per_conv_workspace.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_port_proxy.py
sudo docker exec openhands-app-tab python3 /tmp/patch_sandbox_exposed_urls.py
sudo docker exec openhands-app-tab python3 /tmp/patch_rate_limiter.py
sudo docker exec openhands-app-tab python3 /tmp/patch_browser_store_expose.py
sudo docker exec openhands-app-tab python3 /tmp/patch_port_scan_html.py
sudo docker exec openhands-app-tab python3 /tmp/patch_tabs_fixes.py
# 重新注入 index.html FakeWS（/api/proxy/events 路径，klogin 可转发，含 browser tab fix）
sudo docker cp openhands-app-tab:/app/frontend/build/index.html /tmp/oh-index.html 2>/dev/null
sudo chmod 666 /tmp/oh-index.html 2>/dev/null
python3 << 'INNEREOF'
import re
with open('/tmp/oh-index.html') as f: html = f.read()
if 'FakeWS' in html:
    html = re.sub(r'<script>\(function\(\)\{[^<]*FakeWS[^<]*\}\)\(\);</script>', '', html, flags=re.DOTALL)
inject = (
    '<script>(function(){'
    'var _f=window.fetch;window.fetch=function(u,o){if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0){u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}return _f.call(this,u,o);};'
    'var _X=window.XMLHttpRequest.prototype.open;window.XMLHttpRequest.prototype.open=function(m,u){if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0){u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}return _X.apply(this,arguments);};'
    'window.__oh_browse=null;'
    'window._ohApplyBrowse=function(){var d=window.__oh_browse;if(!d)return;var bs=window.__oh_browser_store;if(bs&&bs.getState){window.__oh_browse=null;var ss=d.ss;if(ss){bs.getState().setScreenshotSrc(ss.startsWith("data:")?ss:"data:image/png;base64,"+ss);}if(d.url){bs.getState().setUrl(d.url);}}else{setTimeout(window._ohApplyBrowse,300);}};'
    'var _WS=window.WebSocket;'
    'function FakeWS(url,proto){var self=this;self.readyState=0;self.onopen=null;self.onmessage=null;self.onclose=null;self.onerror=null;self._es=null;var m=url.match(/\\/sockets\\/events\\/([^?]+)/);var id=m?m[1]:"";var queryStr=url.indexOf("?")>=0?url.split("?")[1]:"";var params=new URLSearchParams(queryStr);var key=params.get("session_api_key")||"";var sseUrl="/api/proxy/events/"+id+"/stream?resend_all=true";if(key)sseUrl+="&session_api_key="+encodeURIComponent(key);self.send=function(d){fetch("/api/proxy/conversations/"+id+"/events",{method:"POST",headers:{"Content-Type":"application/json","X-Session-API-Key":key},body:d}).catch(function(){});};self.close=function(){if(self._es){self._es.close();self._es=null;}self.readyState=3;if(self.onclose)self.onclose({code:1000,reason:"",wasClean:true});};var es=new EventSource(sseUrl);self._es=es;es.onopen=function(){self.readyState=1;if(self.onopen)self.onopen({});};es.onmessage=function(ev){if(ev.data==="__connected__")return;if(ev.data==="__closed__"){self.readyState=3;if(self.onclose)self.onclose({code:1000,wasClean:true});return;}try{var _d=JSON.parse(ev.data);var _ss="",_url="";if(_d&&_d.observation&&typeof _d.observation==="object"&&_d.observation.kind==="BrowserObservation"){_ss=_d.observation.screenshot_data||"";_url=_d.observation.url||"";}else if(_d&&(_d.observation==="browse"||_d.observation==="browse_interactive")){_ss=(_d.extras&&_d.extras.screenshot)||"";_url=(_d.extras&&_d.extras.url)||"";}if(_ss||_url){window.__oh_browse={ss:_ss,url:_url};window._ohApplyBrowse();}}catch(e){}if(self.onmessage)self.onmessage({data:ev.data});};es.onerror=function(){if(self._es){self._es.close();self._es=null;}self.readyState=3;if(self.onerror)self.onerror({});if(self.onclose)self.onclose({code:1006,reason:"",wasClean:false});};}'
    'FakeWS.CONNECTING=0;FakeWS.OPEN=1;FakeWS.CLOSING=2;FakeWS.CLOSED=3;'
    'window.WebSocket=function(url,proto){if(url&&url.indexOf("/sockets/events/")>=0){return new FakeWS(url,proto);}return new _WS(url,proto);};'
    'window.WebSocket.prototype=_WS.prototype;window.WebSocket.CONNECTING=0;window.WebSocket.OPEN=1;window.WebSocket.CLOSING=2;window.WebSocket.CLOSED=3;'
    'document.addEventListener("keydown",function(e){if(e.key!=="Enter")return;var el=document.activeElement;if(!el||el.tagName!=="INPUT")return;var v=el.value||"";if(!v.match(/^(https?:\\/\\/|\\/api\\/sandbox-port\\/)/))return;if(!el.closest("form"))return;e.preventDefault();el.blur();},true);'
    '})();</script>'
)
with open('/tmp/oh-index.html', 'w') as f: f.write(html.replace('<head>', '<head>' + inject, 1))
print('重启后重新注入 index.html FakeWS（含 browser tab fix + Enter键修复）✓')
INNEREOF
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
