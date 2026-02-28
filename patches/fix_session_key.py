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
