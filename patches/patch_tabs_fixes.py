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
proxy_path = '/app/openhands/server/routes/agent_server_proxy.py'
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
    # Build python3 one-liner: http.client request → raw HTTP response on stdout
    _py = (
        "import http.client as _c,sys,base64 as _b;"
        "_h={'Connection':'close'};"
        + (f"_h['Cookie']={repr(_cookie)};" if _cookie else "")
        + (f"_h['Content-Type']={repr(_ct_hdr)};" if _ct_hdr else "")
        + f"_bd=_b.b64decode({repr(_body_b64)}) if {repr(_body_b64)} else b'';"
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

# ─── Fix 9: Upgrade _docker_exec_http to python3 (no curl dependency) ───
# The agent-server:1.10.0-python image may not have curl at the container top level.
# Python3 is always available. Detect old curl version and upgrade.
proxy_path = '/app/openhands/server/routes/agent_server_proxy.py'
with open(proxy_path) as f:
    proxy_src = f.read()

if '[OH-TAB-PY3-V2]' in proxy_src:
    print('agent_server_proxy.py: _docker_exec_http already V2 (SIGCONT) ✓')
elif 'def _docker_exec_http(' in proxy_src:
    import base64 as _b64_fix9
    # Build V2: python3-based + SIGCONT recovery for SIGSTOP\'d apps
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
    # SIGSTOP\'d: kernel accepts TCP but process never calls recv() → getresponse() times out (~3s).
    # Not-running: connect() refuses immediately → exec completes in <0.5s.
    _t0 = _time.time()
    stdout = _exec_cmd(["python3", "-c", _http_py(3)])
    _elapsed = _time.time() - _t0
    if not stdout and _elapsed > 2.0:
        # Took ~3s → process exists but SIGSTOP\'d. SIGCONT all stopped processes.
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

# ─── Fix 9b: Better _cip2 extraction (handle custom Docker networks) ───
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

