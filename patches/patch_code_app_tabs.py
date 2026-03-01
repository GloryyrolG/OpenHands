"""patch_code_app_tabs.py: Code tab (VSCode) and App tab (scan proxy) patches.
Merges (strict dependency order):
  patch_sandbox_port_proxy -> patch_port_scan_html -> patch_tabs_fixes
  -> patch_dir_listing_scan -> patch_dir_listing_probe -> patch_vscode_tab
"""
import os as _os, shutil as _shutil, re as _re

_APP_PATH = '/app/openhands/server/app.py'
_PROXY_PATH = '/app/openhands/server/routes/agent_server_proxy.py'
_ASSETS = '/app/frontend/build/assets'

# ══════════════════════════════════════════════════════
# Section 1: patch_sandbox_port_proxy
# Injects /api/sandbox-port/* HTTP+WS routes into app.py
# Prerequisite: agent_proxy_router registered (by patch_agent_comms)
# Prerequisite: _get_oh_tab_ip() in agent_server_proxy.py (by patch_agent_comms)
# ══════════════════════════════════════════════════════
with open(_APP_PATH) as f:
    _src = f.read()

if 'sandbox-port' in _src:
    print('sandbox-port 代理路由已存在 ✓')
else:
    _MARKER = 'app.include_router(agent_proxy_router)'
    if _MARKER not in _src:
        print('WARNING: include_router(agent_proxy_router) not found in app.py')
        raise RuntimeError('include_router(agent_proxy_router) not found in app.py')

    _PROXY_ROUTES = '''

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
                        r"""((?:src|href|action)=["'])(/[^/"\'#][^"']*)""",
                        _rewrite_abs, html)
                    html = html.replace(
                        "&quot;serverBasePath&quot;:&quot;/&quot;",
                        "&quot;serverBasePath&quot;:&quot;" + proxy_base + "/&quot;")
                    html = _re.sub(
                        r"(new URL[(]')(/stable-[^']+)(')",
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

    _src = _src.replace(_MARKER, _MARKER + _PROXY_ROUTES, 1)
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('sandbox-port 代理路由已注入 ✓')

# ══════════════════════════════════════════════════════
# Section 2: patch_port_scan_html
# Injects _PORT_SCAN_HTML constant + exception handler
# Prerequisite: MARKER "# --- Sandbox port proxy: VSCode (8001)..." (from Section 1)
# ══════════════════════════════════════════════════════
with open(_APP_PATH) as f:
    _src = f.read()

if '[oh-tab-port-scan]' in _src and '_PORT_SCAN_HTML' in _src:
    print('Auto-scan HTML already in sandbox_port_proxy ✓')
else:
    if '[oh-tab-port-scan]' in _src and '_PORT_SCAN_HTML' not in _src:
        print('WARNING: [oh-tab-port-scan] present but _PORT_SCAN_HTML missing — re-injecting constant and continuing')

    _SCAN_HTML = (
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
    _S2_MARKER = '# --- Sandbox port proxy: VSCode (8001), App (8011/8012) ---'
    if _S2_MARKER not in _src:
        print('WARNING: sandbox port proxy marker not found!')
        _idx = _src.find('sandbox-port')
        print('Context:', repr(_src[max(0,_idx-50):_idx+200]))
        raise RuntimeError('sandbox port proxy marker not found in app.py')

    if '_PORT_SCAN_HTML' not in _src:
        _scan_const = '_PORT_SCAN_HTML = ' + repr(_SCAN_HTML) + '\n\n'
        _src = _src.replace(_S2_MARKER, _scan_const + _S2_MARKER, 1)
        print('_PORT_SCAN_HTML constant injected ✓')

    # Modify the exception handler to return scan HTML on ConnectError at root GET
    _old_exc = (
        '    except Exception as e:\n'
        '        from starlette.responses import Response as _Resp\n'
        '        return _Resp(content=str(e), status_code=502)\n'
        '\n'
        '@app.api_route("/api/sandbox-port/{port}/"'
    )
    _new_exc = (
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
    if _old_exc in _src:
        _src = _src.replace(_old_exc, _new_exc, 1)
        print('Auto-scan exception handler applied ✓')
    elif '[oh-tab-port-scan]' in _src:
        print('Exception handler already patched ✓')
    else:
        print('WARNING: exception handler pattern not found')
        # Diagnostic: find sandbox_port_proxy context
        _idx = _src.find('sandbox_port_proxy')
        print('Context:', repr(_src[max(0,_idx):_idx+600]))

    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('Done.')

# ══════════════════════════════════════════════════════
# Section 3: patch_tabs_fixes (9 sub-fixes)
# Uses its own local path vars to avoid collision
# ══════════════════════════════════════════════════════
_tf_proxy_path = '/app/openhands/server/routes/agent_server_proxy.py'
_tf_app_path = '/app/openhands/server/app.py'

proxy_path = _tf_proxy_path
with open(proxy_path) as f:
    proxy_src = f.read()

# Fix 1b: git/changes 401 -> []
with open(proxy_path) as f:
    proxy_src = f.read()
old_git = 'resp.status_code == 500 and path.startswith("api/git/changes")'
new_git = 'resp.status_code in (401, 500) and path.startswith("api/git/changes")'
if old_git in proxy_src:
    proxy_src = proxy_src.replace(old_git, new_git, 1)
    with open(proxy_path, 'w') as f:
        f.write(proxy_src)
    print('agent_server_proxy.py: git/changes 401->[] fix applied ✓')
elif new_git in proxy_src:
    print('agent_server_proxy.py: git/changes 401->[] fix already present ✓')
else:
    print('WARNING: git/changes pattern not found in agent_server_proxy.py')

# Now fix app.py
app_path = _tf_app_path
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
            '    """Redirect /api/sandbox-port/{port} -> /api/sandbox-port/{port}/ (trailing slash)."""\n'
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

# Fix 3: VSCode 403 -> ?tkn redirect
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
        print('app.py: VSCode 403->tkn redirect added ✓')
    else:
        # Fix existing wrong 'params' reference if present
        old_params = 'and "tkn" not in params)'
        new_params = 'and "tkn" not in str(request.query_params))'
        if old_params in src:
            src = src.replace(old_params, new_params, 1)
            changes += 1
            print('app.py: VSCode 403 params->query_params fix applied ✓')
        else:
            print('WARNING: VSCode 403 fix insert point not found')
else:
    # Fix existing wrong 'params' reference if present
    old_params = 'and "tkn" not in params)'
    new_params = 'and "tkn" not in str(request.query_params))'
    if old_params in src:
        src = src.replace(old_params, new_params, 1)
        changes += 1
        print('app.py: VSCode 403 params->query_params fix applied ✓')
    else:
        print('app.py: VSCode 403->tkn redirect already correct ✓')

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

# Fix 6: VSCode folder in 403 redirect (add &folder=<workdir>)
with open(app_path) as f:
    src = f.read()
old_rr2 = (
    '                    if _tok:\n'
    '                        from starlette.responses import RedirectResponse as _RR2\n'
    '                        return _RR2(url=f"/api/sandbox-port/{port}/?tkn={_tok}", status_code=302)\n'
)
new_rr2 = (
    '                    if _tok:\n'
    '                        _workdir = _cdata.get("Config", {}).get("WorkingDir", "/workspace")\n'
    '                        _folder = _workdir.lstrip("/") or "workspace"\n'
    '                        from starlette.responses import RedirectResponse as _RR2\n'
    '                        return _RR2(url=f"/api/sandbox-port/{port}/?tkn={_tok}&folder={_folder}", status_code=302)\n'
)
if old_rr2 in src:
    src = src.replace(old_rr2, new_rr2, 1)
    with open(app_path, 'w') as f:
        f.write(src)
    print('app.py: VSCode folder param added to redirect ✓')
elif '&folder=' in src and '_workdir' in src:
    print('app.py: VSCode folder param already present ✓')
else:
    print('WARNING: VSCode redirect pattern not found for folder fix')

# Fix 7: _docker_exec_http with method/body/cookie support
proxy_path = _tf_proxy_path
with open(proxy_path) as f:
    proxy_src = f.read()

NEW_EXEC_FUNC = '''
def _docker_exec_http(container_id: str, port: int, path: str,
                       method: str = "GET", body_bytes: bytes = b"",
                       req_headers: dict = None) -> tuple:
    """[OH-TAB-PY3] Proxy HTTP request via docker exec python3 (for 127.0.0.1-bound apps).
    Uses python3 http.client — no curl dependency. Forwards Cookie/Content-Type/body.
    Returns (status_code, headers_dict, body_bytes, content_type_str)."""
    import json as _j, base64 as _b64
    _cookie = ""
    _ct_hdr = ""
    if req_headers:
        _cookie = req_headers.get("cookie") or req_headers.get("Cookie", "")
        _ct_hdr = req_headers.get("content-type") or req_headers.get("Content-Type", "")
    _body_b64 = _b64.b64encode(body_bytes).decode() if body_bytes else ""
    _req_path = "/" + path if path else "/"
    # Build python3 one-liner: http.client request -> raw HTTP response on stdout
    _py = (
        "import http.client as _c,sys,base64 as _b;"
        "_h={'Connection':'close'};"
        + (f"_h['Cookie']={repr(_cookie)};" if _cookie else "")
        + (f"_h['Content-Type']={repr(_ct_hdr)};" if _ct_hdr else "")
        + f"_bd=_b.b64decode({repr(_body_b64)}) if {repr(_body_b64)} else b\'\';"
        f"conn=_c.HTTPConnection('127.0.0.1',{port},timeout=10);"
        f"conn.request({repr(method)},{repr(_req_path)},_bd,_h);"
        "r=conn.getresponse();"
        "sys.stdout.buffer.write(b'HTTP/1.1 '+str(r.status).encode()+b' OK\\r\\n');"
        "[(sys.stdout.buffer.write((k+': '+v+'\\r\\n').encode())) for k,v in r.getheaders()];"
        "sys.stdout.buffer.write(b'\\r\\n');"
        "sys.stdout.buffer.write(r.read())"
    )
    cmd = ["python3", "-c", _py]
    exec_body = _j.dumps({
        "Cmd": cmd, "AttachStdout": True, "AttachStderr": False, "User": "root"
    }).encode()
    conn = _UnixHTTPConnection("/var/run/docker.sock")
    conn.request("POST", f"/containers/{container_id}/exec", body=exec_body,
                 headers={"Content-Type": "application/json",
                          "Content-Length": str(len(exec_body))})
    resp = conn.getresponse()
    exec_info = _j.loads(resp.read())
    exec_id = exec_info.get("Id")
    if not exec_id:
        raise Exception("exec create failed")
    start_body = b\'{"Detach":false,"Tty":false}\'
    conn2 = _UnixHTTPConnection("/var/run/docker.sock")
    conn2.request("POST", f"/exec/{exec_id}/start", body=start_body,
                  headers={"Content-Type": "application/json",
                           "Content-Length": str(len(start_body))})
    resp2 = conn2.getresponse()
    raw = resp2.read()
    stdout = b""
    pos = 0
    while pos + 8 <= len(raw):
        stream_type = raw[pos]
        size = int.from_bytes(raw[pos+4:pos+8], "big")
        if size == 0:
            pos += 8
            continue
        if stream_type == 1:  # stdout only
            stdout += raw[pos+8:pos+8+size]
        pos += 8 + size
    if b"\\r\\n\\r\\n" not in stdout:
        raise Exception(f"no HTTP separator ({len(stdout)} bytes stdout)")
    headers_raw, body = stdout.split(b"\\r\\n\\r\\n", 1)
    lines = headers_raw.split(b"\\r\\n")
    status_code = int(lines[0].decode().split()[1]) if lines else 502
    hdrs = {}
    ct = ""
    for line in lines[1:]:
        if b": " in line:
            k, v = line.decode().split(": ", 1)
            hdrs[k.lower()] = v
            if k.lower() == "content-type":
                ct = v
    return status_code, hdrs, body, ct

'''

if '[OH-TAB-PY3]' in proxy_src or '[OH-TAB-PY3-V2]' in proxy_src:
    print('agent_server_proxy.py: _docker_exec_http already python3 version ✓')
elif '_docker_exec_http' not in proxy_src:
    proxy_src = proxy_src.replace('def _get_oh_tab_container_for_port', NEW_EXEC_FUNC + 'def _get_oh_tab_container_for_port', 1)
    with open(proxy_path, 'w') as f:
        f.write(proxy_src)
    print('agent_server_proxy.py: _docker_exec_http added (python3 version) ✓')
else:
    # Replace old curl/GET-only version with python3 version
    idx = proxy_src.find('def _docker_exec_http(')
    end_idx = proxy_src.find('\ndef ', idx + 1)
    if idx >= 0 and end_idx > idx:
        proxy_src = proxy_src[:idx] + NEW_EXEC_FUNC.strip() + '\n\n' + proxy_src[end_idx+1:]
        with open(proxy_path, 'w') as f:
            f.write(proxy_src)
        print('agent_server_proxy.py: _docker_exec_http upgraded to python3 (no curl needed) ✓')
    else:
        print('WARNING: could not find _docker_exec_http end boundary')

# Fix 8: Full scan handler: docker exec with Cookie/method/body + Location rewrite + <base> tag
with open(app_path) as f:
    src = f.read()

# 8a: httpx path - add Location rewrite + <base> tag + strip content-length
OLD_HTTPX_RET = (
    '                    from starlette.responses import Response as _Resp2\n'
    '                    _scan_hdrs = {k:v for k,v in _r2.headers.multi_items()\n'
    '                        if k.lower() not in ("content-encoding","transfer-encoding","connection","content-security-policy")}\n'
    '                    return _Resp2(content=_r2.content, status_code=_r2.status_code,\n'
    '                        headers=_scan_hdrs, media_type=_r2.headers.get("content-type",""))\n'
)
NEW_HTTPX_RET = (
    '                    from starlette.responses import Response as _Resp2\n'
    '                    _scan_hdrs = {k:v for k,v in _r2.headers.multi_items()\n'
    '                        if k.lower() not in ("content-encoding","transfer-encoding","connection","content-security-policy","content-length")}\n'
    '                    # Rewrite Location for app-internal redirects\n'
    '                    if 300 <= _r2.status_code < 400 and "location" in _scan_hdrs:\n'
    '                        import urllib.parse as _up3\n'
    '                        _loc = _scan_hdrs["location"]\n'
    '                        if _loc.startswith("http"):\n'
    '                            _lp = _up3.urlparse(_loc)\n'
    '                            _lpath = _lp.path.lstrip("/") + (("?" + _lp.query) if _lp.query else "")\n'
    '                        else:\n'
    '                            _lpath = _loc.lstrip("/")\n'
    '                        _scan_hdrs["location"] = f"/api/sandbox-port/{port}/scan/{_sp_port}/{_lpath}"\n'
    '                    # Rewrite root-relative URLs and inject <base> tag\n'
    '                    _r2_content = _r2.content\n'
    '                    _r2_ct = _r2.headers.get("content-type", "")\n'
    '                    if "text/html" in _r2_ct and _r2_content:\n'
    '                        import re as _re3\n'
    '                        _sb = f"/api/sandbox-port/{port}/scan/{_sp_port}"\n'
    '                        try:\n'
    '                            _hs = _r2_content.decode("utf-8", errors="replace")\n'
    '                            _hs = _re3.sub(\n'
    '                                r\'((?:href|action|src)=")(/(?!/)[^"]*)\',\n'
    '                                lambda m: m.group(1) + _sb + m.group(2) if not m.group(2).startswith(_sb) else m.group(0),\n'
    '                                _hs)\n'
    '                            _r2_content = _hs.encode("utf-8")\n'
    '                        except Exception:\n'
    '                            pass\n'
    '                        _base = f\'<base href="/api/sandbox-port/{port}/scan/{_sp_port}/">\'.encode()\n'
    '                        for _htag in (b"<head>", b"<Head>", b"<HEAD>"):\n'
    '                            if _htag in _r2_content:\n'
    '                                _r2_content = _r2_content.replace(_htag, _htag + _base, 1)\n'
    '                                break\n'
    '                        else:\n'
    '                            _r2_content = _base + _r2_content\n'
    '                    return _Resp2(content=_r2_content, status_code=_r2.status_code,\n'
    '                        headers=_scan_hdrs, media_type=_r2.headers.get("content-type",""))\n'
)
if 'r\'((?:href|action|src)=")(/(?!/)[^"]*)\'' in src:
    print('app.py: httpx scan URL rewrite+base tag already present ✓')
elif 'Rewrite Location for app-internal' in src:
    # old version without HTML rewrite, need to upgrade
    OLD_HTTPX_RET_V2 = (
        '                    # Inject <base> tag so relative URLs in HTML stay in scan proxy\n'
        '                    _r2_content = _r2.content\n'
    )
    if OLD_HTTPX_RET_V2 in src:
        # find the full old block and replace
        idx = src.find(OLD_HTTPX_RET_V2)
        end_marker = '                    return _Resp2(content=_r2_content, status_code=_r2.status_code,\n'
        end_idx = src.find(end_marker, idx)
        if end_idx > idx:
            end_idx = src.find('\n', end_idx) + 1
            src = src[:idx] + '\n'.join(NEW_HTTPX_RET.split('\n')) + src[end_idx:]
            print('app.py: httpx scan URL rewrite upgraded ✓')
        else:
            print('WARNING: could not find end of old httpx HTML block')
    else:
        print('app.py: httpx scan Location already present (no HTML block) ✓')
elif OLD_HTTPX_RET in src:
    src = src.replace(OLD_HTTPX_RET, NEW_HTTPX_RET, 1)
    print('app.py: httpx scan URL rewrite+Location+base tag fix added ✓')
else:
    print('WARNING: httpx scan return pattern not found')

# 8b: docker exec fallback - full version with Cookie/method/body + Location + base tag
OLD_SCAN_EXC = (
    '                except Exception as _se:\n'
    '                    from starlette.responses import Response as _Resp2\n'
    '                    if request.headers.get("x-oh-tab-scan") != "1":\n'
    '                        from starlette.responses import HTMLResponse as _HtmlResp\n'
    '                        return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    '                    return _Resp2(content=str(_se), status_code=502)\n'
)
OLD_SCAN_EXC_V2 = (
    '                except Exception as _se:\n'
    '                    # Fallback: try docker exec for 127.0.0.1-bound apps\n'
    '                    _cid2 = _cdata2.get("Id", "")\n'
    '                    if _cid2:\n'
    '                        try:\n'
    '                            import asyncio as _asyncio\n'
    '                            from openhands.server.routes.agent_server_proxy import _docker_exec_http as _deh\n'
    '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
    '                                None, _deh, _cid2, _sp_port, _sp_path)\n'
    '                            _scan_hdrs2 = {k:v for k,v in _hdrs2.items()\n'
    '                                if k.lower() not in ("content-encoding","transfer-encoding","connection","content-security-policy")}\n'
    '                            from starlette.responses import Response as _Resp2\n'
    '                            return _Resp2(content=_body2, status_code=_status2,\n'
    '                                headers=_scan_hdrs2, media_type=_ct2)\n'
    '                        except Exception:\n'
    '                            pass\n'
    '                    from starlette.responses import Response as _Resp2\n'
    '                    if request.headers.get("x-oh-tab-scan") != "1":\n'
    '                        from starlette.responses import HTMLResponse as _HtmlResp\n'
    '                        return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    '                    return _Resp2(content=str(_se), status_code=502)\n'
)
NEW_SCAN_EXC = (
    '                except Exception as _se:\n'
    '                    # Fallback: try docker exec for 127.0.0.1-bound apps\n'
    '                    _cid2 = _cdata2.get("Id", "")\n'
    '                    if _cid2:\n'
    '                        try:\n'
    '                            import asyncio as _asyncio\n'
    '                            from openhands.server.routes.agent_server_proxy import _docker_exec_http as _deh\n'
    '                            _exec_body = await request.body()\n'
    '                            _exec_hdrs = dict(request.headers)\n'
    '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
    '                                None, _deh, _cid2, _sp_port, _sp_path, request.method, _exec_body, _exec_hdrs)\n'
    '                            # Rewrite Location for app-internal redirects\n'
    '                            import urllib.parse as _up3\n'
    '                            _loc2 = _hdrs2.get("location", "")\n'
    '                            if _loc2:\n'
    '                                if _loc2.startswith("http"):\n'
    '                                    _lp2 = _up3.urlparse(_loc2)\n'
    '                                    _lpath2 = _lp2.path.lstrip("/") + (("?" + _lp2.query) if _lp2.query else "")\n'
    '                                else:\n'
    '                                    _lpath2 = _loc2.lstrip("/")\n'
    '                                _hdrs2["location"] = f"/api/sandbox-port/{port}/scan/{_sp_port}/{_lpath2}"\n'
    '                            # Rewrite root-relative URLs and inject <base> tag\n'
    '                            if "text/html" in _ct2 and _body2:\n'
    '                                import re as _re3\n'
    '                                _sb = f"/api/sandbox-port/{port}/scan/{_sp_port}"\n'
    '                                try:\n'
    '                                    _hs = _body2.decode("utf-8", errors="replace")\n'
    '                                    _hs = _re3.sub(\n'
    '                                        r\'((?:href|action|src)=")(/(?!/)[^"]*)\',\n'
    '                                        lambda m: m.group(1) + _sb + m.group(2) if not m.group(2).startswith(_sb) else m.group(0),\n'
    '                                        _hs)\n'
    '                                    _body2 = _hs.encode("utf-8")\n'
    '                                except Exception:\n'
    '                                    pass\n'
    '                                _base2 = f\'<base href="/api/sandbox-port/{port}/scan/{_sp_port}/">\'.encode()\n'
    '                                for _htag2 in (b"<head>", b"<Head>", b"<HEAD>"):\n'
    '                                    if _htag2 in _body2:\n'
    '                                        _body2 = _body2.replace(_htag2, _htag2 + _base2, 1)\n'
    '                                        break\n'
    '                                else:\n'
    '                                    _body2 = _base2 + _body2\n'
    '                            _scan_hdrs2 = {k:v for k,v in _hdrs2.items()\n'
    '                                if k.lower() not in ("content-encoding","transfer-encoding","connection","content-security-policy","content-length")}\n'
    '                            from starlette.responses import Response as _Resp2\n'
    '                            return _Resp2(content=_body2, status_code=_status2,\n'
    '                                headers=_scan_hdrs2, media_type=_ct2)\n'
    '                        except Exception:\n'
    '                            pass\n'
    '                    from starlette.responses import Response as _Resp2\n'
    '                    if request.headers.get("x-oh-tab-scan") != "1":\n'
    '                        from starlette.responses import HTMLResponse as _HtmlResp\n'
    '                        return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    '                    return _Resp2(content=str(_se), status_code=502)\n'
)
if 'r\'((?:href|action|src)=")(/(?!/)[^"]*)\'' in src and 'request.method, _exec_body, _exec_hdrs' in src:
    print('app.py: docker exec scan fallback already fully updated ✓')
elif OLD_SCAN_EXC_V2 in src:
    src = src.replace(OLD_SCAN_EXC_V2, NEW_SCAN_EXC, 1)
    print('app.py: docker exec scan fallback upgraded (method/cookie/location/base) ✓')
elif OLD_SCAN_EXC in src:
    src = src.replace(OLD_SCAN_EXC, NEW_SCAN_EXC, 1)
    print('app.py: docker exec scan fallback added (method/cookie/location/base) ✓')
else:
    print('WARNING: scan exception block pattern not found')

with open(app_path, 'w') as f:
    f.write(src)

# --- Fix 9: Upgrade _docker_exec_http to python3 (no curl dependency) ---
# The agent-server:1.10.0-python image may not have curl at the container top level.
# Python3 is always available. Detect old curl version and upgrade.
proxy_path = _tf_proxy_path
with open(proxy_path) as f:
    proxy_src = f.read()

if '[OH-TAB-PY3-V2]' in proxy_src:
    print('agent_server_proxy.py: _docker_exec_http already V2 (SIGCONT) ✓')
elif 'def _docker_exec_http(' in proxy_src:
    import base64 as _b64_fix9
    # Build V2: python3-based + SIGCONT recovery for SIGSTOP'd apps
    NEW_EXEC_PY3 = '''def _docker_exec_http(container_id: str, port: int, path: str,
                       method: str = "GET", body_bytes: bytes = b"",
                       req_headers: dict = None) -> tuple:
    """[OH-TAB-PY3-V2] Proxy HTTP request via docker exec python3 (for 127.0.0.1-bound apps).
    Uses python3 http.client — no curl. Handles SIGSTOP\'d apps: SIGCONTs all stopped
    processes in the container then retries. /proc/pid/status is world-readable for root.
    Returns (status_code, headers_dict, body_bytes, content_type_str)."""
    import json as _j, base64 as _b64, time as _time

    def _exec_cmd(cmd):
        eb = _j.dumps({"Cmd": cmd, "AttachStdout": True, "AttachStderr": False, "User": "root"}).encode()
        c1 = _UnixHTTPConnection("/var/run/docker.sock")
        c1.request("POST", f"/containers/{container_id}/exec", body=eb,
                   headers={"Content-Type": "application/json", "Content-Length": str(len(eb))})
        info = _j.loads(c1.getresponse().read())
        eid = info.get("Id")
        if not eid:
            return b""
        sb = b\'{"Detach":false,"Tty":false}\'
        c2 = _UnixHTTPConnection("/var/run/docker.sock")
        c2.request("POST", f"/exec/{eid}/start", body=sb,
                   headers={"Content-Type": "application/json", "Content-Length": str(len(sb))})
        raw = c2.getresponse().read()
        out = b""
        pos = 0
        while pos + 8 <= len(raw):
            stype = raw[pos]; sz = int.from_bytes(raw[pos+4:pos+8], "big")
            if sz == 0: pos += 8; continue
            if stype == 1: out += raw[pos+8:pos+8+sz]
            pos += 8 + sz
        return out

    _cookie = ""
    _ct_hdr = ""
    if req_headers:
        _cookie = req_headers.get("cookie") or req_headers.get("Cookie", "")
        _ct_hdr = req_headers.get("content-type") or req_headers.get("Content-Type", "")
    _body_b64 = _b64.b64encode(body_bytes).decode() if body_bytes else ""
    _req_path = "/" + path if path else "/"

    def _http_py(timeout_s):
        return (
            "import http.client as _c,sys,base64 as _b;"
            "_h={\'Connection\':\'close\'};"
            + ("_h[\'Cookie\']=" + repr(_cookie) + ";" if _cookie else "")
            + ("_h[\'Content-Type\']=" + repr(_ct_hdr) + ";" if _ct_hdr else "")
            + "_bd=_b.b64decode(" + repr(_body_b64) + ") if " + repr(_body_b64) + " else b\'\';"
            + "conn=_c.HTTPConnection(\'127.0.0.1\'," + str(port) + ",timeout=" + str(timeout_s) + ");"
            + "conn.request(" + repr(method) + "," + repr(_req_path) + ",_bd,_h);"
            + "r=conn.getresponse();"
            + "sys.stdout.buffer.write(b\'HTTP/1.1 \'+str(r.status).encode()+b\' OK\\r\\n\');"
            + "[(sys.stdout.buffer.write((k+\': \'+v+\'\\r\\n\').encode())) for k,v in r.getheaders()];"
            + "sys.stdout.buffer.write(b\'\\r\\n\');"
            + "sys.stdout.buffer.write(r.read())"
        )

    # First attempt: short timeout detects SIGSTOP\'d apps.
    # SIGSTOP\'d: kernel accepts TCP but process never calls recv() -> getresponse() times out (~3s).
    # Not-running: connect() refuses immediately -> exec completes in <0.5s.
    _t0 = _time.time()
    stdout = _exec_cmd(["python3", "-c", _http_py(3)])
    _elapsed = _time.time() - _t0
    if not stdout and _elapsed > 2.0:
        # Took ~3s -> process exists but SIGSTOP\'d. SIGCONT all stopped processes.
        # Note: /proc/pid/fd readlinks restricted by ptrace scope even for root,
        # but /proc/pid/status is world-readable and os.kill() works for root.
        _sc = (
            "import os,signal\\n"
            "try:\\n"
            "  for pid in os.listdir('/proc'):\\n"
            "    if not pid.isdigit(): continue\\n"
            "    try:\\n"
            "      st=open(f'/proc/{pid}/status').read()\\n"
            "      if 'T (stopped)' in st:\\n"
            "        os.kill(int(pid),signal.SIGCONT)\\n"
            "    except: pass\\n"
            "except: pass\\n"
        )
        _enc = _b64.b64encode(_sc.encode()).decode()
        _exec_cmd(["python3", "-c", "import base64; exec(base64.b64decode(\'" + _enc + "\').decode())"])
        _time.sleep(1.0)
        stdout = _exec_cmd(["python3", "-c", _http_py(12)])
    if b"\\r\\n\\r\\n" not in stdout:
        raise Exception(f"no HTTP separator ({len(stdout)} bytes stdout)")
    headers_raw, body = stdout.split(b"\\r\\n\\r\\n", 1)
    lines = headers_raw.split(b"\\r\\n")
    status_code = int(lines[0].decode().split()[1]) if lines else 502
    hdrs = {}
    ct = ""
    for line in lines[1:]:
        if b": " in line:
            k, v = line.decode().split(": ", 1)
            hdrs[k.lower()] = v
            if k.lower() == "content-type":
                ct = v
    return status_code, hdrs, body, ct

'''
    idx = proxy_src.find('def _docker_exec_http(')
    end_idx = proxy_src.find('\ndef ', idx + 1)
    if idx >= 0 and end_idx > idx:
        proxy_src = proxy_src[:idx] + NEW_EXEC_PY3 + proxy_src[end_idx+1:]
        with open(proxy_path, 'w') as f:
            f.write(proxy_src)
        print('agent_server_proxy.py: _docker_exec_http upgraded to V2 (SIGCONT) ✓')
    else:
        print('WARNING: could not find _docker_exec_http boundary in proxy file')
else:
    print('agent_server_proxy.py: _docker_exec_http not found, skipping ✓')

# --- Fix 9b: Better _cip2 extraction (handle custom Docker networks) ---
# Some Docker setups use custom networks; NetworkSettings.IPAddress is empty in that case.
# Fall back to Networks dict to get any available IP.
with open(app_path) as f:
    src = f.read()

OLD_CIP2 = (
    '            _cip2 = _cdata2.get("NetworkSettings", {}).get("IPAddress", "")\n'
    '            if _cip2:\n'
)
NEW_CIP2 = (
    '            # [OH-TAB-FIX9B] get bridge IP: try primary IP, then any network IP\n'
    '            _ns2 = _cdata2.get("NetworkSettings", {})\n'
    '            _cip2 = (_ns2.get("IPAddress", "")\n'
    '                or next((v.get("IPAddress","") for v in _ns2.get("Networks",{}).values()\n'
    '                         if v.get("IPAddress","")), ""))\n'
    '            if _cip2:\n'
)
if '[OH-TAB-FIX9B]' in src:
    print('app.py: Fix 9b (_cip2 network fallback) already applied ✓')
elif OLD_CIP2 in src:
    src = src.replace(OLD_CIP2, NEW_CIP2, 1)
    with open(app_path, 'w') as f:
        f.write(src)
    print('app.py: Fix 9b applied (_cip2 custom network fallback) ✓')
else:
    print('app.py: Fix 9b: _cip2 pattern not found (may already be patched differently) ✓')

# ══════════════════════════════════════════════════════
# Section 4: patch_dir_listing_scan
# Prerequisite: [oh-tab-agent-check] marker + _PORT_SCAN_HTML (Sections 1+2)
# ══════════════════════════════════════════════════════
with open(_APP_PATH) as f:
    _src = f.read()

if '[oh-tab-dir-check]' in _src:
    print('app.py: dir-listing scan check already present ✓')
else:
    # Locate [oh-tab-agent-check] block, find its _PORT_SCAN_HTML return, insert dir-check after
    _idx = _src.find('[oh-tab-agent-check]')
    if _idx < 0:
        print('WARNING: [oh-tab-agent-check] marker not found in app.py')
        raise RuntimeError('[oh-tab-agent-check] marker not found in app.py')

    _ret_marker = 'return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    _ret_idx = _src.find(_ret_marker, _idx)
    if _ret_idx < 0:
        print('WARNING: _PORT_SCAN_HTML return not found after agent-check')
        raise RuntimeError('_PORT_SCAN_HTML return not found after agent-check')

    _insert_at = _ret_idx + len(_ret_marker)
    _next_snip = _src[_insert_at:_insert_at+60]
    if 'text/html' not in _next_snip:
        print('WARNING: unexpected content after agent-check return:', repr(_next_snip))
        raise RuntimeError('unexpected content after agent-check return')

    _DIR_CHECK = (
        '            # [oh-tab-dir-check] Python directory listing at root GET -> show scan page\n'
        '            if (resp.status_code == 200 and request.method == "GET" and not path\n'
        '                    and "text/html" in ct\n'
        '                    and request.headers.get("x-oh-tab-scan") != "1"\n'
        '                    and b"Directory listing for" in content[:500]):\n'
        '                from starlette.responses import HTMLResponse as _HtmlResp\n'
        '                return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
    )
    _src = _src[:_insert_at] + _DIR_CHECK + _src[_insert_at:]
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print('app.py: dir-listing scan check applied ✓')

# ══════════════════════════════════════════════════════
# Section 5: patch_dir_listing_probe
# Prerequisite: Fix8 code structure (Section 3)
# ══════════════════════════════════════════════════════
with open(_APP_PATH) as f:
    _src = f.read()

_changes = 0

# Fix A: docker-exec fallback path -- insert after run_in_executor, before "Rewrite Location"
if '[oh-tab-dir-reject]' not in _src:
    _OLD_EXEC = (
        '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
        '                                None, _deh, _cid2, _sp_port, _sp_path, request.method, _exec_body, _exec_hdrs)\n'
        '                            # Rewrite Location for app-internal redirects\n'
    )
    _NEW_EXEC = (
        '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
        '                                None, _deh, _cid2, _sp_port, _sp_path, request.method, _exec_body, _exec_hdrs)\n'
        '                            # [oh-tab-dir-reject] Directory listing on scan probe -> 502 (skip port)\n'
        '                            if (request.headers.get("x-oh-tab-scan") == "1"\n'
        '                                    and b"Directory listing for" in _body2[:500]):\n'
        '                                from starlette.responses import Response as _Resp2\n'
        '                                return _Resp2(content=b"directory listing", status_code=502)\n'
        '                            # Rewrite Location for app-internal redirects\n'
    )
    if _OLD_EXEC in _src:
        _src = _src.replace(_OLD_EXEC, _NEW_EXEC, 1)
        _changes += 1
        print('app.py: dir-reject added to docker-exec path ✓')
    else:
        print('WARNING: docker-exec pattern not found for Fix 12d')
else:
    print('app.py: dir-reject docker-exec already present ✓')

# Fix B: httpx bridge-IP path -- insert after _r2_ct, before html rewrite
if '[oh-tab-dir-reject-http]' not in _src:
    _OLD_HTTPX = (
        '                    _r2_content = _r2.content\n'
        '                    _r2_ct = _r2.headers.get("content-type", "")\n'
        '                    if "text/html" in _r2_ct and _r2_content:\n'
    )
    _NEW_HTTPX = (
        '                    _r2_content = _r2.content\n'
        '                    _r2_ct = _r2.headers.get("content-type", "")\n'
        '                    # [oh-tab-dir-reject-http] Directory listing on scan probe -> 502 (skip port)\n'
        '                    if (request.headers.get("x-oh-tab-scan") == "1"\n'
        '                            and "text/html" in _r2_ct\n'
        '                            and b"Directory listing for" in _r2_content[:500]):\n'
        '                        from starlette.responses import Response as _Resp2\n'
        '                        return _Resp2(content=b"directory listing", status_code=502)\n'
        '                    if "text/html" in _r2_ct and _r2_content:\n'
    )
    if _OLD_HTTPX in _src:
        _src = _src.replace(_OLD_HTTPX, _NEW_HTTPX, 1)
        _changes += 1
        print('app.py: dir-reject added to httpx path ✓')
    else:
        print('WARNING: httpx pattern not found for Fix 12d')
else:
    print('app.py: dir-reject httpx already present ✓')

if _changes > 0:
    with open(_APP_PATH, 'w') as f:
        f.write(_src)
    print(f'app.py: {_changes} change(s) written ✓')
else:
    print('app.py: no changes needed')

# ══════════════════════════════════════════════════════
# Section 6: patch_vscode_tab -- VSCode URL fix + z-suffix chain
# Prerequisite: z-suffix files from patch_frontend_js.py
# ══════════════════════════════════════════════════════

# 1. Fix vscode-tab JS files (both - and x suffix)
_OLD_URL = 'if(r?.url)try{const f=new URL(r.url).protocol'
_NEW_URL = 'if(r?.url)try{const f=new URL(r.url,window.location.origin).protocol'

for _fname in ['vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-x.js']:
    _p = _os.path.join(_ASSETS, _fname)
    if not _os.path.exists(_p):
        print(f'{_fname}: not found, skipping')
        continue
    with open(_p) as f:
        _vsrc = f.read()
    if _NEW_URL in _vsrc:
        print(f'{_fname}: already patched ✓')
    elif _OLD_URL in _vsrc:
        _vsrc = _vsrc.replace(_OLD_URL, _NEW_URL, 1)
        with open(_p, 'w') as f:
            f.write(_vsrc)
        print(f'{_fname}: URL parse fix applied ✓')
    else:
        print(f'{_fname}: WARNING pattern not found')

# 2. Create vscode-tab-CFaq3Fn-z.js from patched original (prefer x if exists)
_src_x = _os.path.join(_ASSETS, 'vscode-tab-CFaq3Fn-x.js')
_src_orig = _os.path.join(_ASSETS, 'vscode-tab-CFaq3Fn-.js')
_dst_z = _os.path.join(_ASSETS, 'vscode-tab-CFaq3Fn-z.js')
_vt_src = _src_x if _os.path.exists(_src_x) else _src_orig
if _os.path.exists(_vt_src):
    _shutil.copy2(_vt_src, _dst_z)
    print(f'Created vscode-tab-CFaq3Fn-z.js (from {_os.path.basename(_vt_src)}) ✓')
else:
    print('WARNING: no vscode-tab source found')

# 3. Determine uXvJtyCL source (prefer x if exists, fall back to plain)
_conv_x    = _os.path.join(_ASSETS, 'conversation-uXvJtyCLx.js')
_conv_orig = _os.path.join(_ASSETS, 'conversation-uXvJtyCL.js')
_conv_src  = _conv_x if _os.path.exists(_conv_x) else _conv_orig

# 4. Create conversation-uXvJtyCLz.js (copy of best available source)
_conv_z = _os.path.join(_ASSETS, 'conversation-uXvJtyCLz.js')
if _os.path.exists(_conv_src):
    _shutil.copy2(_conv_src, _conv_z)
    print(f'Created conversation-uXvJtyCLz.js (from {_os.path.basename(_conv_src)}) ✓')
else:
    print('WARNING: no conversation-uXvJtyCL source found')

# 5. Update uXvJtyCLz.js to reference vscode-tab-z (replace all vscode-tab- variants)
if _os.path.exists(_conv_z):
    with open(_conv_z) as f:
        _csrc = f.read()
    if 'vscode-tab-CFaq3Fn-z.js' not in _csrc:
        _csrc2 = _csrc.replace('vscode-tab-CFaq3Fn-x.js', 'vscode-tab-CFaq3Fn-z.js')
        _csrc2 = _csrc2.replace('vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-z.js')
        with open(_conv_z, 'w') as f:
            f.write(_csrc2)
        print('Updated uXvJtyCLz.js: vscode-tab -> vscode-tab-z ✓')
    else:
        print('uXvJtyCLz.js already refs vscode-tab-z ✓')

# 6. Update conversation-fHdubO7Rz.js to import uXvJtyCLz
_conv_rz = _os.path.join(_ASSETS, 'conversation-fHdubO7Rz.js')
if _os.path.exists(_conv_rz):
    with open(_conv_rz) as f:
        _rzc = f.read()
    if 'uXvJtyCLz' not in _rzc:
        _rzc2 = _rzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        _rzc2 = _rzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if _rzc2 != _rzc:
            with open(_conv_rz, 'w') as f:
                f.write(_rzc2)
            print('Updated conversation-fHdubO7Rz.js -> uXvJtyCLz ✓')
    else:
        print('fHdubO7Rz already refs uXvJtyCLz ✓')

# 7. Update manifest-z to reference uXvJtyCLz (for modulepreload hints)
_mz = _os.path.join(_ASSETS, 'manifest-8c9a7105z.js')
if _os.path.exists(_mz):
    with open(_mz) as f:
        _mzc = f.read()
    if 'uXvJtyCLz' not in _mzc:
        _mzc2 = _mzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        _mzc2 = _mzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if _mzc2 != _mzc:
            with open(_mz, 'w') as f:
                f.write(_mzc2)
            print('Updated manifest-z -> uXvJtyCLz ✓')
    else:
        print('manifest-z already refs uXvJtyCLz ✓')

print('Chain: manifest-z -> fHdubO7Rz -> uXvJtyCLz -> BMHPx + vscode-tab-z ✓')
