# IMPORTANT: LEGACY V0 CODE - Deprecated since version 1.0.0, scheduled for removal April 1, 2026
# This file is part of the legacy (V0) implementation of OpenHands and will be removed soon as we complete the migration to V1.
# OpenHands V1 uses the Software Agent SDK for the agentic core and runs a new application server. Please refer to:
#   - V1 agentic core (SDK): https://github.com/OpenHands/software-agent-sdk
#   - V1 application server (in this repo): openhands/app_server/
# Unless you are working on deprecation, please avoid extending this legacy file and consult the V1 codepaths above.
# Tag: Legacy-V0
# This module belongs to the old V0 web server. The V1 application server lives under openhands/app_server/.
import contextlib
import warnings
from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi.routing import Mount

with warnings.catch_warnings():
    warnings.simplefilter('ignore')

from fastapi import (
    FastAPI,
    Request,
)
from fastapi.responses import JSONResponse

import openhands.agenthub  # noqa F401 (we import this to get the agents registered)
from openhands.app_server import v1_router
from openhands.app_server.config import get_app_lifespan_service
from openhands.integrations.service_types import AuthenticationError
from openhands.server.routes.agent_server_proxy import _get_tab_agent_url as _gtau
from openhands.server.routes.agent_server_proxy import agent_proxy_router

# 新增多用户认证路由
from openhands.server.routes.auth import app as auth_router
from openhands.server.routes.conversation import app as conversation_api_router
from openhands.server.routes.feedback import app as feedback_api_router
from openhands.server.routes.files import app as files_api_router
from openhands.server.routes.git import app as git_api_router
from openhands.server.routes.health import add_health_endpoints
from openhands.server.routes.manage_conversations import (
    app as manage_conversation_api_router,
)
from openhands.server.routes.mcp import mcp_server
from openhands.server.routes.public import app as public_api_router
from openhands.server.routes.secrets import app as secrets_router
from openhands.server.routes.security import app as security_api_router
from openhands.server.routes.settings import app as settings_router
from openhands.server.routes.trajectory import app as trajectory_router
from openhands.server.shared import conversation_manager, server_config
from openhands.server.types import AppMode
from openhands.version import get_version

mcp_app = mcp_server.http_app(path='/mcp', stateless_http=True)


def combine_lifespans(*lifespans):
    # Create a combined lifespan to manage multiple session managers
    @contextlib.asynccontextmanager
    async def combined_lifespan(app):
        async with contextlib.AsyncExitStack() as stack:
            for lifespan in lifespans:
                await stack.enter_async_context(lifespan(app))
            yield

    return combined_lifespan


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    async with conversation_manager:
        yield


lifespans = [_lifespan, mcp_app.lifespan]
app_lifespan_ = get_app_lifespan_service()
if app_lifespan_:
    lifespans.append(app_lifespan_.lifespan)


app = FastAPI(
    title='OpenHands',
    description='OpenHands: Code Less, Make More',
    version=get_version(),
    lifespan=combine_lifespans(*lifespans),
    routes=[Mount(path='/mcp', app=mcp_app)],
)


@app.exception_handler(AuthenticationError)
async def authentication_error_handler(request: Request, exc: AuthenticationError):
    return JSONResponse(
        status_code=401,
        content=str(exc),
    )


app.include_router(agent_proxy_router)
app.include_router(public_api_router)
app.include_router(auth_router)  # 新增认证路由
app.include_router(files_api_router)
app.include_router(security_api_router)
app.include_router(feedback_api_router)
app.include_router(conversation_api_router)
app.include_router(manage_conversation_api_router)
app.include_router(settings_router)
app.include_router(secrets_router)
if server_config.app_mode == AppMode.OPENHANDS:
    app.include_router(git_api_router)
if server_config.enable_v1:
    app.include_router(v1_router.router)
app.include_router(trajectory_router)
add_health_endpoints(app)


# =======================================================================
# [OH-MULTI] SSE + POST event proxy routes (patch_agent_comms)
# klogin forwards /api/* but not WebSocket upgrades, so we use SSE here
# =======================================================================


@app.get('/api/proxy/events/{conversation_id}/stream', include_in_schema=False)
async def api_proxy_events_stream(request: Request, conversation_id: str):
    """SSE via /api/* - klogin只转发/api/*，此端点让浏览器收到V1实时事件。
    [OH-MULTI-PERSESSION] Per-conversation routing via _gtau(conversation_id)."""
    import websockets as _ws
    from starlette.responses import StreamingResponse as _SR

    from openhands.server.routes.agent_server_proxy import (
        _get_agent_server_key as _gask,
    )
    from openhands.server.routes.agent_server_proxy import _get_tab_agent_key as _gtak

    params = dict(request.query_params)
    # [OH-MULTI] inject session_api_key if missing — use per-conversation key
    if 'session_api_key' not in params:
        _srv_key = _gtak(conversation_id) or _gask()
        if _srv_key:
            params['session_api_key'] = _srv_key
    qs = '&'.join(f'{k}={v}' for k, v in params.items())
    ws_url = f'{_gtau(conversation_id).replace("http://", "ws://")}/sockets/events/{conversation_id}'
    if qs:
        ws_url += f'?{qs}'

    async def _gen():
        import asyncio as _asyncio

        yield ':heartbeat\n\n'  # flush headers immediately
        connected = False
        _base_qs = '&'.join(f'{k}={v}' for k, v in params.items() if k != 'resend_all')
        # Keep SSE alive indefinitely: reconnect WS on disconnect, send heartbeats.
        # Client disconnect cancels the generator via CancelledError.
        fail_count = 0
        while fail_count < 600:  # ~30 min max idle (600 * 3s)
            try:
                _url = (
                    ws_url
                    if not connected
                    else (
                        f'{_gtau(conversation_id).replace("http://", "ws://")}/sockets/events/{conversation_id}'
                        + (f'?{_base_qs}' if _base_qs else '')
                    )
                )
                async with _ws.connect(_url) as ws:
                    if not connected:
                        yield 'data: __connected__\n\n'
                        connected = True
                    fail_count = 0  # reset on successful connect
                    while True:  # heartbeat prevents klogin 60s idle timeout
                        try:
                            msg = await _asyncio.wait_for(ws.recv(), timeout=15)
                            data = msg if isinstance(msg, str) else msg.decode()
                            data = data.replace('\n', '\\n')
                            yield f'data: {data}\n\n'
                        except _asyncio.TimeoutError:
                            yield ':heartbeat\n\n'
                        except Exception as _inner_exc:
                            import logging as _lg

                            _lg.getLogger('openhands').warning(
                                f'SSE proxy WS recv error for {conversation_id}: {type(_inner_exc).__name__}: {_inner_exc}'
                            )
                            break
                    # WS closed — don't end SSE, reconnect after brief wait
            except Exception as _exc:
                import logging as _lg

                _lg.getLogger('openhands').warning(
                    f'SSE proxy WS connect failed for {conversation_id} url={_url}: {type(_exc).__name__}: {_exc}'
                )
            fail_count += 1
            yield ':heartbeat\n\n'
            await _asyncio.sleep(3)
        yield 'data: __closed__\n\n'

    return _SR(
        _gen(),
        media_type='text/event-stream',
        headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'},
    )


@app.post('/api/proxy/conversations/{conversation_id}/events', include_in_schema=False)
async def api_proxy_send_event(conversation_id: str, request: Request):
    """[OH-MULTI-PERSESSION] Per-conversation routing: use _gtau for agent URL."""
    import json as _json
    import uuid as _uuid

    import httpx as _httpx

    from openhands.server.routes.agent_server_proxy import (
        _get_agent_server_key as _gask,
    )
    from openhands.server.routes.agent_server_proxy import _get_tab_agent_key as _gtak

    body = await request.body()
    key = request.headers.get('X-Session-API-Key', '') or dict(
        request.query_params
    ).get('session_api_key', '')
    if not key:
        key = _gtak(conversation_id) or _gask()
    try:
        conv_uuid = str(_uuid.UUID(conversation_id))
    except Exception:
        conv_uuid = conversation_id
    try:
        body_dict = _json.loads(body.decode())
        if 'action' in body_dict and body_dict.get('action') == 'message':
            text = body_dict.get('args', {}).get('content', '')
            payload = {
                'role': 'user',
                'content': [{'type': 'text', 'text': text}],
                'run': True,
            }
        elif 'role' in body_dict:
            content = body_dict.get('content', '')
            if isinstance(content, str):
                content = [{'type': 'text', 'text': content}]
            payload = {
                'role': body_dict.get('role', 'user'),
                'content': content,
                'run': True,
            }
        else:
            payload = body_dict
    except Exception:
        payload = {}
    try:
        async with _httpx.AsyncClient() as _client:
            await _client.post(
                f'{_gtau(conversation_id)}/api/conversations/{conv_uuid}/events',
                json=payload,
                headers={'X-Session-API-Key': key},
                timeout=10.0,
            )
    except Exception as _exc:
        import logging as _lg

        _lg.getLogger('openhands').warning(
            f'api_proxy_send_event failed for {conversation_id}: {type(_exc).__name__}: {_exc}'
        )
        return JSONResponse({'success': False, 'error': str(_exc)}, status_code=502)
    return JSONResponse({'success': True})


# =======================================================================
# [OH-MULTI] Sandbox port proxy: VSCode (8001), App (8011/8012)
# Routes browser requests through openhands-app to sandbox containers
# =======================================================================

_PORT_SCAN_HTML = (
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
    'const ports=[3000,4173,5000,5173,7860,8000,8008,8011,8080,8501,8502,8503,8504,8888,9000];'
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
    'window.parent.postMessage({type:"oh-multi-port-redirect",url:_tu},"*");}'
    'window.location.replace(_tu);return;}}'
    'document.getElementById("m").textContent="No app found yet. Retrying in 3s...";'
    'setTimeout(scan,3000);}scan();'
    '</script></body></html>'
)

# --- Sandbox port proxy ---
from fastapi import WebSocket as _FastAPIWebSocket  # noqa: E402

from openhands.server.routes.agent_server_proxy import (  # noqa: E402
    _get_oh_multi_ip as _get_oh_multi_ip,
)


@app.api_route(
    '/api/sandbox-port/{port}/{path:path}',
    methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD'],
    include_in_schema=False,
)
async def sandbox_port_proxy(port: int, path: str, request: Request):
    """Reverse proxy any sandbox port through openhands-app-multi (port 3005)."""
    # [OH-MULTI] per-session scan: /api/sandbox-port/{ctx_port}/scan/{scan_port}/{path}
    if path.startswith('scan/'):
        _sp = path[5:]
        _parts = _sp.split('/', 1)
        _sp_port = int(_parts[0]) if _parts[0].isdigit() else 0
        _sp_path = _parts[1] if len(_parts) > 1 else ''
        if _sp_port > 0:
            from openhands.server.routes.agent_server_proxy import (
                _get_oh_tab_container_for_port as _gcfp2,
            )

            _cdata2 = _gcfp2(port)
            _cip2 = _cdata2.get('NetworkSettings', {}).get('IPAddress', '')
            if _cip2:
                # For full page loads (not scan probes), redirect to Docker NAT host port
                # so the main proxy handler does proper URL rewriting for assets
                if request.headers.get('x-oh-tab-scan') != '1' and not _sp_path:
                    _port_bindings = _cdata2.get('NetworkSettings', {}).get('Ports', {})
                    _nat_info = _port_bindings.get(f'{_sp_port}/tcp', [])
                    if _nat_info:
                        _host_port = _nat_info[0].get('HostPort', '')
                        if _host_port:
                            from starlette.responses import RedirectResponse as _RR3

                            return _RR3(
                                url=f'/api/sandbox-port/{_host_port}/', status_code=302
                            )
                _scan_target = f'http://{_cip2}:{_sp_port}/{_sp_path}'
                _qs2 = str(request.query_params)
                if _qs2:
                    _scan_target += f'?{_qs2}'
                try:
                    import httpx as _hx2

                    async with _hx2.AsyncClient(
                        timeout=10.0, follow_redirects=False
                    ) as _c2:
                        _r2 = await _c2.request(
                            method=request.method,
                            url=_scan_target,
                            headers={
                                k: v
                                for k, v in request.headers.items()
                                if k.lower()
                                not in (
                                    'host',
                                    'content-length',
                                    'transfer-encoding',
                                    'connection',
                                )
                            },
                            content=await request.body(),
                        )
                    from starlette.responses import Response as _Resp2

                    _scan_hdrs = {
                        k: v
                        for k, v in _r2.headers.multi_items()
                        if k.lower()
                        not in (
                            'content-encoding',
                            'transfer-encoding',
                            'connection',
                            'content-security-policy',
                            'content-length',
                        )
                    }
                    return _Resp2(
                        content=_r2.content,
                        status_code=_r2.status_code,
                        headers=_scan_hdrs,
                        media_type=_r2.headers.get('content-type', ''),
                    )
                except Exception as _se:
                    from starlette.responses import Response as _Resp2

                    if request.headers.get('x-oh-tab-scan') == '1':
                        # Scan sub-request: return 502 so tryPort() returns false
                        return _Resp2(content=str(_se), status_code=502)
                    # Direct browser access: show scan page
                    from starlette.responses import HTMLResponse as _HtmlResp

                    return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)

    import re as _re

    import httpx as _hx

    # Low ports (<20000) are container-internal; high ports are Docker NAT-mapped
    _cip = _get_oh_multi_ip()
    _proxy_host = _cip if (_cip and port < 20000) else '127.0.0.1'
    target = f'http://{_proxy_host}:{port}/{path}'
    qs = str(request.query_params)
    if qs:
        target += f'?{qs}'
    headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower()
        not in ('host', 'content-length', 'transfer-encoding', 'connection')
    }
    body = await request.body()
    proxy_base = f'/api/sandbox-port/{port}'
    try:
        async with _hx.AsyncClient(timeout=60.0, follow_redirects=False) as client:
            resp = await client.request(
                method=request.method, url=target, headers=headers, content=body
            )
            # [OH-MULTI] VSCode 403 at root: inject connection token
            if (
                resp.status_code == 403
                and request.method == 'GET'
                and not path
                and port >= 20000
                and 'tkn' not in str(request.query_params)
            ):
                try:
                    from openhands.server.routes.agent_server_proxy import (
                        _get_oh_tab_container_for_port as _gcfp,
                    )

                    _cdata = _gcfp(port)
                    _env = _cdata.get('Config', {}).get('Env', [])
                    _tok = next(
                        (
                            e.split('=', 1)[1]
                            for e in _env
                            if e.startswith('OH_SESSION_API_KEYS_0=')
                        ),
                        None,
                    )
                    if _tok:
                        _workdir = _cdata.get('Config', {}).get(
                            'WorkingDir', '/workspace'
                        )
                        _folder = _workdir.lstrip('/') or 'workspace'
                        from starlette.responses import RedirectResponse as _RR2

                        return _RR2(
                            url=f'/api/sandbox-port/{port}/?tkn={_tok}&folder={_folder}',
                            status_code=302,
                        )
                except Exception:
                    pass
            resp_headers = {}
            for k, v in resp.headers.multi_items():
                if k.lower() in (
                    'content-encoding',
                    'transfer-encoding',
                    'connection',
                    'content-security-policy',
                    'content-length',
                ):
                    continue
                if k.lower() == 'location':
                    if v.startswith('http://127.0.0.1') or v.startswith(
                        'http://localhost'
                    ):
                        v = _re.sub(r'https?://[^/]+', proxy_base, v, count=1)
                    elif v.startswith('/') and not v.startswith(proxy_base):
                        v = proxy_base + v
                resp_headers[k] = v
            content = resp.content
            ct = resp.headers.get('content-type', '')
            # If agent server JSON at root GET, show scan page
            if (
                resp.status_code == 200
                and request.method == 'GET'
                and not path
                and 'application/json' in ct
                and request.headers.get('x-oh-tab-scan') != '1'
                and b'"OpenHands Agent Server"' in content[:200]
            ):
                from starlette.responses import HTMLResponse as _HtmlResp

                return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)
            _is_js = any(t in ct for t in ('javascript', 'ecmascript'))
            if (_is_js or 'text/html' in ct) and content:
                try:
                    html = content.decode('utf-8')
                    if 'text/html' in ct:

                        def _rewrite_abs(m):
                            attr, url = m.group(1), m.group(2)
                            if url.startswith(proxy_base):
                                return m.group(0)
                            return attr + proxy_base + url

                        html = _re.sub(
                            r"""((?:src|href|action)=["'])(/[^/"'#][^"']*)""",
                            _rewrite_abs,
                            html,
                        )
                        html = html.replace(
                            '&quot;serverBasePath&quot;:&quot;/&quot;',
                            '&quot;serverBasePath&quot;:&quot;'
                            + proxy_base
                            + '/&quot;',
                        )
                    if not _is_js:
                        html = _re.sub(
                            r"(new URL\(')(/stable-[^']+)(')",
                            lambda m: m.group(1) + proxy_base + m.group(2) + m.group(3),
                            html,
                        )
                        html = _re.sub(
                            r'&quot;remoteAuthority&quot;:&quot;[^&]*&quot;',
                            '&quot;remoteAuthority&quot;:&quot;&quot;',
                            html,
                        )

                    # Rewrite JS/HTML import/from absolute paths: import "/xxx" → import "/api/sandbox-port/{port}/xxx"
                    def _rewrite_import(m):
                        prefix, url, suffix = m.group(1), m.group(2), m.group(3)
                        if url.startswith(proxy_base):
                            return m.group(0)
                        return prefix + proxy_base + url + suffix

                    html = _re.sub(
                        r"""((?:import|from)\s*["'])(/[^"']+)(["'])""",
                        _rewrite_import,
                        html,
                    )
                    content = html.encode('utf-8')
                except Exception:
                    pass
            from starlette.responses import Response as _Resp

            return _Resp(
                content=content,
                status_code=resp.status_code,
                headers=resp_headers,
                media_type=ct or resp.headers.get('content-type'),
            )
    except Exception as e:
        # Return auto-scan page for ANY error at root GET (not for probe requests)
        if (
            request.method == 'GET'
            and not path
            and request.headers.get('x-oh-tab-scan') != '1'
        ):
            from starlette.responses import HTMLResponse as _HtmlResp

            return _HtmlResp(content=_PORT_SCAN_HTML, status_code=200)
        from starlette.responses import Response as _Resp

        return _Resp(content=str(e), status_code=502)


@app.api_route(
    '/api/sandbox-port/{port}/',
    methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD'],
    include_in_schema=False,
)
async def sandbox_port_proxy_root(port: int, request: Request):
    """Root path variant for sandbox port proxy."""
    return await sandbox_port_proxy(port, '', request)


@app.api_route(
    '/api/sandbox-port/{port}',
    methods=['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD'],
    include_in_schema=False,
)
async def sandbox_port_proxy_bare(port: int, request: Request):
    """Redirect /api/sandbox-port/{port} -> /api/sandbox-port/{port}/ (trailing slash)."""
    from starlette.responses import RedirectResponse as _RR

    qs = str(request.query_params)
    loc = f'/api/sandbox-port/{port}/' + (f'?{qs}' if qs else '')
    return _RR(url=loc, status_code=307)


@app.websocket('/api/sandbox-port/{port}/{path:path}')
async def sandbox_port_ws_proxy(port: int, path: str, websocket: _FastAPIWebSocket):
    """WebSocket proxy for sandbox ports (VSCode needs WS for language server)."""
    import websockets as _ws

    _sw_subproto_hdr = websocket.headers.get('sec-websocket-protocol', '')
    _sw_subprotos = [s.strip() for s in _sw_subproto_hdr.split(',') if s.strip()]
    await websocket.accept(subprotocol=_sw_subprotos[0] if _sw_subprotos else None)
    qs = str(websocket.query_params)
    if path.startswith('scan/'):
        _sw_rest = path[5:]
        _sw_parts = _sw_rest.split('/', 1)
        _sw_sp_port = int(_sw_parts[0]) if _sw_parts[0].isdigit() else 0
        _sw_sp_path = _sw_parts[1] if len(_sw_parts) > 1 else ''
        if not _sw_sp_port:
            await websocket.close(1003)
            return
        from openhands.server.routes.agent_server_proxy import (
            _get_oh_tab_container_for_port as _gcfp_ws,
        )

        _cdata_ws = _gcfp_ws(port)
        _ns_ws = _cdata_ws.get('NetworkSettings', {})
        _cip_ws = _ns_ws.get('IPAddress', '') or next(
            (
                v.get('IPAddress', '')
                for v in _ns_ws.get('Networks', {}).values()
                if v.get('IPAddress', '')
            ),
            '',
        )
        if not _cip_ws:
            await websocket.close(1011)
            return
        ws_url = f'ws://{_cip_ws}:{_sw_sp_port}/{_sw_sp_path}'
        if qs:
            ws_url += f'?{qs}'
    else:
        _cip = _get_oh_multi_ip()
        _proxy_host = _cip if (_cip and port < 20000) else '127.0.0.1'
        ws_url = f'ws://{_proxy_host}:{port}/{path}'
        if qs:
            ws_url += f'?{qs}'
    try:
        _sw_connect_kwargs = {}
        if _sw_subprotos:
            _sw_connect_kwargs['subprotocols'] = _sw_subprotos
        async with _ws.connect(ws_url, **_sw_connect_kwargs) as target_ws:
            import asyncio

            async def client_to_target():
                try:
                    while True:
                        data = await websocket.receive()
                        if 'text' in data:
                            await target_ws.send(data['text'])
                        elif 'bytes' in data and data['bytes']:
                            await target_ws.send(data['bytes'])
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
                [
                    asyncio.create_task(client_to_target()),
                    asyncio.create_task(target_to_client()),
                ],
                return_when=asyncio.FIRST_COMPLETED,
            )
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
