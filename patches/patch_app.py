with open('/app/openhands/server/app.py') as f:
    src = f.read()

if 'agent_server_proxy' in src and '_gasp' in src and '_gtau' in src:
    print('app.py 代理路由（含 _gasp/_gtau per-session）已存在 ✓')
elif 'agent_server_proxy' in src and '_gasp' in src:
    # Upgrade: add _gtau to existing import (old install has _gasp but not _gtau)
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py import 升级：添加 _gtau ✓')
elif 'agent_server_proxy' in src:
    # Upgrade: add _gasp and _gtau to existing import
    src = src.replace(
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router\n',
        'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\n',
        1
    )
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py import 升级：添加 _gasp + _gtau ✓')
else:
    old = 'from openhands.server.routes.public import app as public_api_router'
    new = 'from openhands.server.routes.agent_server_proxy import agent_proxy_router, _get_agent_server_port as _gasp, _get_tab_agent_url as _gtau\nfrom openhands.server.routes.public import app as public_api_router'
    src = src.replace(old, new, 1)
    old2 = 'app.include_router(public_api_router)'
    new2 = 'app.include_router(agent_proxy_router)\napp.include_router(public_api_router)'
    src = src.replace(old2, new2, 1)
    with open('/app/openhands/server/app.py', 'w') as f:
        f.write(src)
    print('app.py 代理路由已注入 ✓')
