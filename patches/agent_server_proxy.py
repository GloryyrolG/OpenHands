import asyncio
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

# Per-conversation URL cache: conversation_id -> (agent_server_url, timestamp)
_url_cache: dict = {}
_URL_CACHE_TTL = 3600  # 1 hour; URLs don't change once task is READY


class _UnixHTTPConnection(_http_client.HTTPConnection):
    def __init__(self, socket_path):
        super().__init__("localhost")
        self._socket_path = socket_path
    def connect(self):
        s = _socket_mod.socket(_socket_mod.AF_UNIX, _socket_mod.SOCK_STREAM)
        s.connect(self._socket_path)
        self.sock = s


_agent_port_cache = [0, 0.0]
def _get_agent_server_port() -> int:
    """Fallback: get host port of first oh-tab- container's port 8000 (cached 60s)."""
    import time as _t
    if _agent_port_cache[0] and _t.time() - _agent_port_cache[1] < 60:
        return _agent_port_cache[0]
    try:
        conn = _UnixHTTPConnection("/var/run/docker.sock")
        conn.request("GET", "/containers/json?filters=%7B%22name%22%3A%5B%22oh-tab-%22%5D%7D")
        resp = conn.getresponse()
        containers = _json_mod.loads(resp.read())
        if not containers:
            return 8000
        for port_info in containers[0].get("Ports", []):
            if port_info.get("PrivatePort") == 8000 and port_info.get("PublicPort"):
                port = port_info["PublicPort"]
                _agent_port_cache[0] = port
                _agent_port_cache[1] = _t.time()
                return port
        return 8000
    except Exception:
        return _agent_port_cache[0] or 8000


_agent_key_cache = ["", 0.0]
def _get_agent_server_key() -> str:
    """Read session_api_key from first oh-tab- container via Docker API (cached 60s)."""
    import time as _t
    if _agent_key_cache[0] and _t.time() - _agent_key_cache[1] < 60:
        return _agent_key_cache[0]
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
                key = e.split("=", 1)[1]
                _agent_key_cache[0] = key
                _agent_key_cache[1] = _t.time()
                return key
        return ""
    except Exception:
        return _agent_key_cache[0]


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


_key_cache: dict = {}  # cid -> (key, timestamp)
_KEY_CACHE_TTL = 3600  # 1 hour; keys don't change during container lifetime
def _get_tab_agent_key(conversation_id: str) -> str:
    """Get session_api_key for this conversation's oh-tab- container via Docker API."""
    import time as _t
    cid = conversation_id.removeprefix('task-').replace('-', '')
    if cid in _key_cache:
        key, ts = _key_cache[cid]
        if _t.time() - ts < _KEY_CACHE_TTL:
            return key
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
                _key_cache[cid] = (key, _t.time())
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
    import time as _t
    cid = conversation_id.removeprefix('task-').replace('-', '')
    if cid in _url_cache:
        url, ts = _url_cache[cid]
        if _t.time() - ts < _URL_CACHE_TTL:
            return url
    url = _resolve_tab_agent_url(cid)
    if url:
        _url_cache[cid] = (url, _t.time())
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
    # Per-conversation routing: extract conversation_id from path or Referer
    m = _re_mod.search(r'conversations/((?:task-)?[a-f0-9\-]{32,40})', path)
    if not m:
        # Try Referer header: browser sends Referer: .../conversations/{id} for API calls
        _referer = request.headers.get("referer", "")
        m = _re_mod.search(r'conversations/((?:task-)?[a-f0-9\-]{32,40})', _referer)
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
