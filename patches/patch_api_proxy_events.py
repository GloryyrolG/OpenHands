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
