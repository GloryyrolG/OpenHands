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
