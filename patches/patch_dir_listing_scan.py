"""Patch 12c: Return scan HTML when proxy serves a Python directory listing at root GET."""
APP_PATH = '/app/openhands/server/app.py'
with open(APP_PATH) as f:
    src = f.read()

if '[oh-tab-dir-check]' in src:
    print('app.py: dir-listing scan check already present ✓')
    exit(0)

# Locate [oh-tab-agent-check] block, find its _PORT_SCAN_HTML return, insert dir-check after
idx = src.find('[oh-tab-agent-check]')
if idx < 0:
    print('WARNING: [oh-tab-agent-check] marker not found in app.py')
    exit(1)

ret_marker = 'return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
ret_idx = src.find(ret_marker, idx)
if ret_idx < 0:
    print('WARNING: _PORT_SCAN_HTML return not found after agent-check')
    exit(1)

insert_at = ret_idx + len(ret_marker)
next_snip = src[insert_at:insert_at+60]
if 'text/html' not in next_snip:
    print('WARNING: unexpected content after agent-check return:', repr(next_snip))
    exit(1)

DIR_CHECK = (
    '            # [oh-tab-dir-check] Python directory listing at root GET -> show scan page\n'
    '            if (resp.status_code == 200 and request.method == "GET" and not path\n'
    '                    and "text/html" in ct\n'
    '                    and request.headers.get("x-oh-tab-scan") != "1"\n'
    '                    and b"Directory listing for" in content[:500]):\n'
    '                from starlette.responses import HTMLResponse as _HtmlResp\n'
    '                return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)\n'
)
src = src[:insert_at] + DIR_CHECK + src[insert_at:]
with open(APP_PATH, 'w') as f:
    f.write(src)
print('app.py: dir-listing scan check applied ✓')
