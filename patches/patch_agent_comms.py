"""patch_agent_comms.py: Agent-server communication chain patches.
Merges: patch_sandbox_proxy_container_ip(Part1 only) + patch_app
        + patch_api_proxy_events + fix_session_key + patch_rate_limiter
"""

# ══════════════════════════════════════════════════════
# Section 1: Add _get_oh_tab_ip() to agent_server_proxy.py
# (Part 1 only from patch_sandbox_proxy_container_ip.py — Part 2 dropped)
# ══════════════════════════════════════════════════════
_PROXY_PATH = '/app/openhands/server/routes/agent_server_proxy.py'
with open(_PROXY_PATH) as f:
    _psrc = f.read()

if '_get_oh_tab_ip' in _psrc:
    print('_get_oh_tab_ip already in agent_server_proxy.py ✓')
else:
    _helper = (
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

    _marker = '\n# SSE 端点'
    if _marker in _psrc:
        _psrc = _psrc.replace(_marker, _helper + _marker, 1)
        with open(_PROXY_PATH, 'w') as f:
            f.write(_psrc)
        print('_get_oh_tab_ip added to agent_server_proxy.py ✓')
    else:
        raise RuntimeError('ERROR: marker not found in agent_server_proxy.py')

# ══════════════════════════════════════════════════════
# Section 2: patch_app — import + router in app.py
# ══════════════════════════════════════════════════════
_APP_PATH = '/app/openhands/server/app.py'
with open(_APP_PATH) as f:
    _src = f.read()

if 'agent_server_proxy' in _src and '_gasp' in _src and '_gtau' in _src:
    print('app.py 代理路由（含 _gasp/_gtau per-session）已存在 ✓')
elif 'agent_server_proxy' in _src and '_gasp' in _src:
    # Upgrade: add _gtau to existing import (old install has _gasp but not _gtau)
    _src = _src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('app.py import 升级：添加 _gtau ✓')
elif 'agent_server_proxy' in _src:
    # Upgrade: add _gasp and _gtau to existing import
    _src = _src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('app.py import 升级：添加 _gasp + _gtau ✓')
else:
    _old = 'from openhands.server.routes.public import app as public_api_router'
    _new = 'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\nfrom openhands.server.routes.public import app as public_api_router'
    _src = _src.replace(_old, _new, 1)
    _old2 = 'app.include_router(public_api_router)'
    _new2 = 'app.include_router(agent_proxy_router)\napp.include_router(public_api_router)'
    _src = _src.replace(_old2, _new2, 1)
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('app.py 代理路由已注入 ✓')

# ══════════════════════════════════════════════════════
# Section 3: patch_api_proxy_events — SSE + POST routes
# ══════════════════════════════════════════════════════
with open(_APP_PATH) as f:
    _src = f.read()

if '/api/proxy/events' in _src and '_gtau(conversation_id)' in _src:
    # Per-session routing already present
    print('api/proxy/events 路由（per-session 模式）已存在 ✓')
elif '/api/proxy/events' in _src and 'httpx as _httpx, json as _json, uuid as _uuid' in _src and '_gasp()' in _src:
    # Upgrade: HTTP POST mode present but still uses single-container _gasp() → upgrade to per-session _gtau
    print('升级 api/proxy/events 路由至 per-session 模式（_gasp → _gtau）...')
    _src = _src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    # SSE: replace hardcoded ws://127.0.0.1:{_gasp()} with per-conv URL
    _src = _src.replace(
        'ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"',
        'ws_url = f"{_gtau(conversation_id).replace(\'http://\', \'ws://\')}/sockets/events/{conversation_id}"',
    )
    _src = _src.replace(
        'f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"',
        'f"{_gtau(conversation_id).replace(\'http://\', \'ws://\')}/sockets/events/{conversation_id}"',
    )
    # POST: replace hardcoded http://127.0.0.1:{_gasp()} with per-conv URL
    _src = _src.replace(
        'f"http://127.0.0.1:{_gasp()}/api/conversations/{conv_uuid}/events"',
        'f"{_gtau(conversation_id)}/api/conversations/{conv_uuid}/events"',
    )
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('升级完成：per-session 路由（_gtau）✓')
elif '/api/proxy/events' in _src and '_gasp()' in _src:
    # Upgrade: replace WS send with HTTP POST send
    print('升级 api_proxy_send_event 为 HTTP POST 版本...')
    _old_ws = (
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
    _new_http = (
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
    if _old_ws in _src:
        _src = _src.replace(_old_ws, _new_http, 1)
        with open(_APP_PATH, 'w') as f:
            f.write(_src)
        print('升级完成：api_proxy_send_event WS → HTTP POST ✓')
    else:
        print('WARNING: WS send pattern not found for upgrade')
elif '/api/proxy/events' in _src and 'Must send via WebSocket' in _src and 'heartbeat' in _src:
    # Upgrade: replace hardcoded port with dynamic _gasp() call
    print('升级 api/proxy/events 路由至动态端口版本...')
    _src = _src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        1
    )
    _src = _src.replace('ws://127.0.0.1:8000/sockets/events/', 'ws://127.0.0.1:{_gasp()}/sockets/events/')
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('升级完成：hardcoded port 8000 → _gasp() ✓')
else:
    _MARKER = 'app.include_router(agent_proxy_router)'
    if _MARKER not in _src:
        raise RuntimeError('WARNING: include_router(agent_proxy_router) not found in app.py')

    _new_routes = '''
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

    _src = _src.replace(_MARKER, _MARKER + '\n' + _new_routes, 1)
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('api/proxy/events 路由已注入 ✓')

# ══════════════════════════════════════════════════════
# Section 4: fix_session_key — upgrade SSE session key (no-op on fresh install)
# ══════════════════════════════════════════════════════
_APP_PATH2 = '/app/openhands/server/app.py'
with open(_APP_PATH2) as f:
    _src = f.read()

_old_sse = (
    '    params = dict(request.query_params)\n'
    '    qs = "&".join(f"{k}={v}" for k, v in params.items())\n'
    '    ws_url = f"ws://127.0.0.1:{_gasp()}/sockets/events/{conversation_id}"\n'
    '    if qs:\n'
    '        ws_url += f"?{qs}"'
)
_new_sse = (
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

_old_post_key = (
    '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
    '    # Agent-server requires UUID format with dashes'
)
_new_post_key = (
    '    key = request.headers.get("X-Session-API-Key", "") or dict(request.query_params).get("session_api_key", "")\n'
    '    # [OH-TAB] fallback to container session key if browser has no key\n'
    '    if not key:\n'
    '        from openhands.server.routes.agent_server_proxy import _get_agent_server_key as _gask\n'
    '        key = _gask()\n'
    '    # Agent-server requires UUID format with dashes'
)

_changed = False
if '[OH-TAB] inject session_api_key if missing' in _src:
    print('SSE session_api_key injection already present ✓')
elif _old_sse in _src:
    _src = _src.replace(_old_sse, _new_sse, 1)
    print('SSE session_api_key injection applied ✓')
    _changed = True
else:
    print('WARNING: SSE params pattern not found!')

if '[OH-TAB] fallback to container session key' in _src:
    print('POST key fallback already present ✓')
elif _old_post_key in _src:
    _src = _src.replace(_old_post_key, _new_post_key, 1)
    print('POST key fallback applied ✓')
    _changed = True
else:
    print('WARNING: POST key pattern not found!')

if _changed:
    with open(_APP_PATH2, 'w') as f:
        f.write(_src)

# ══════════════════════════════════════════════════════
# Section 5: patch_rate_limiter — middleware.py
# ══════════════════════════════════════════════════════
_MW_PATH = '/app/openhands/server/middleware.py'
with open(_MW_PATH) as f:
    _src = f.read()

_old_check = (
    "    def is_rate_limited_request(self, request: StarletteRequest) -> bool:\n"
    "        if request.url.path.startswith('/assets'):\n"
    "            return False\n"
    "        # Put Other non rate limited checks here\n"
    "        return True\n"
)
_new_check = (
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
_old_key = "        key = request.client.host\n"
_new_key = (
    "        # klogin proxies all traffic through a single IP; use X-Forwarded-For for real client\n"
    "        key = request.headers.get('x-forwarded-for', '').split(',')[0].strip() or (request.client.host if request.client else '127.0.0.1')\n"
)

if 'sockets/events' in _src and '/sse' in _src and 'return False' in _src[_src.find('sockets/events'):]:
    print('rate limiter SSE 排除已存在 ✓')
elif _old_check in _src:
    _src = _src.replace(_old_check, _new_check, 1)
    print('SSE 路径排除限流 ✓')
else:
    print('WARNING: is_rate_limited_request pattern 未匹配，跳过')

if 'x-forwarded-for' in _src:
    print('X-Forwarded-For key 已存在 ✓')
elif _old_key in _src:
    _src = _src.replace(_old_key, _new_key, 1)
    print('X-Forwarded-For key 修复 ✓')
else:
    print('WARNING: key pattern 未匹配，跳过')

with open(_MW_PATH, 'w') as f:
    f.write(_src)
