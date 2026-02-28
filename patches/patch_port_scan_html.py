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
