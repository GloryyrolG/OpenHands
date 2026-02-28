"""Patch 12d: Reject directory listings in scan probes (X-OH-Tab-Scan: 1)."""
APP_PATH = '/app/openhands/server/app.py'
with open(APP_PATH) as f:
    src = f.read()

changes = 0

# Fix A: docker-exec fallback path — insert after run_in_executor, before "Rewrite Location"
if '[oh-tab-dir-reject]' not in src:
    OLD_EXEC = (
        '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
        '                                None, _deh, _cid2, _sp_port, _sp_path, request.method, _exec_body, _exec_hdrs)\n'
        '                            # Rewrite Location for app-internal redirects\n'
    )
    NEW_EXEC = (
        '                            _status2, _hdrs2, _body2, _ct2 = await _asyncio.get_running_loop().run_in_executor(\n'
        '                                None, _deh, _cid2, _sp_port, _sp_path, request.method, _exec_body, _exec_hdrs)\n'
        '                            # [oh-tab-dir-reject] Directory listing on scan probe -> 502 (skip port)\n'
        '                            if (request.headers.get("x-oh-tab-scan") == "1"\n'
        '                                    and b"Directory listing for" in _body2[:500]):\n'
        '                                from starlette.responses import Response as _Resp2\n'
        '                                return _Resp2(content=b"directory listing", status_code=502)\n'
        '                            # Rewrite Location for app-internal redirects\n'
    )
    if OLD_EXEC in src:
        src = src.replace(OLD_EXEC, NEW_EXEC, 1)
        changes += 1
        print('app.py: dir-reject added to docker-exec path ✓')
    else:
        print('WARNING: docker-exec pattern not found for Fix 12d')
else:
    print('app.py: dir-reject docker-exec already present ✓')

# Fix B: httpx bridge-IP path — insert after _r2_ct, before html rewrite
if '[oh-tab-dir-reject-http]' not in src:
    OLD_HTTPX = (
        '                    _r2_content = _r2.content\n'
        '                    _r2_ct = _r2.headers.get("content-type", "")\n'
        '                    if "text/html" in _r2_ct and _r2_content:\n'
    )
    NEW_HTTPX = (
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
    if OLD_HTTPX in src:
        src = src.replace(OLD_HTTPX, NEW_HTTPX, 1)
        changes += 1
        print('app.py: dir-reject added to httpx path ✓')
    else:
        print('WARNING: httpx pattern not found for Fix 12d')
else:
    print('app.py: dir-reject httpx already present ✓')

if changes > 0:
    with open(APP_PATH, 'w') as f:
        f.write(src)
    print(f'app.py: {changes} change(s) written ✓')
else:
    print('app.py: no changes needed')
