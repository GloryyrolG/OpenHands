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
from openhands.server.routes.agent_server_proxy import _get_oh_tab_ip as _get_oh_tab_ip
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
    # [oh-tab-scan-ws-v2] Forward subprotocols (Streamlit uses "streamlit")
    _sw_subproto_hdr = websocket.headers.get("sec-websocket-protocol", "")
    _sw_subprotos = [s.strip() for s in _sw_subproto_hdr.split(",") if s.strip()]
    await websocket.accept(subprotocol=_sw_subprotos[0] if _sw_subprotos else None)
    qs = str(websocket.query_params)
    # [oh-tab-scan-ws] scan/{sp_port}/{path} -> container bridge IP (e.g. Streamlit WS)
    if path.startswith("scan/"):
        _sw_rest = path[5:]
        _sw_parts = _sw_rest.split("/", 1)
        _sw_sp_port = int(_sw_parts[0]) if _sw_parts[0].isdigit() else 0
        _sw_sp_path = _sw_parts[1] if len(_sw_parts) > 1 else ""
        if not _sw_sp_port:
            await websocket.close(1003); return
        from openhands.server.routes.agent_server_proxy import _get_oh_tab_container_for_port as _gcfp_ws
        _cdata_ws = _gcfp_ws(port)
        _ns_ws = _cdata_ws.get("NetworkSettings", {})
        _cip_ws = (_ns_ws.get("IPAddress", "") or
            next((v.get("IPAddress","") for v in _ns_ws.get("Networks",{}).values()
                  if v.get("IPAddress","")), ""))
        if not _cip_ws:
            await websocket.close(1011); return
        ws_url = f"ws://{_cip_ws}:{_sw_sp_port}/{_sw_sp_path}"
        if qs: ws_url += f"?{qs}"
    else:
        _cip = _get_oh_tab_ip()
        _proxy_host = (_cip if (_cip and port < 20000) else "127.0.0.1")
        ws_url = f"ws://{_proxy_host}:{port}/{path}"
        if qs:
            ws_url += f"?{qs}"
    try:
        _sw_connect_kwargs = {}
        if _sw_subprotos: _sw_connect_kwargs["subprotocols"] = _sw_subprotos
        async with _ws.connect(ws_url, **_sw_connect_kwargs) as target_ws:
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
