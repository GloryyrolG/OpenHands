import re

# Fix 1: extra_hosts condition (docker_sandbox_service.py)
SANDBOX_PATH = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(SANDBOX_PATH) as f:
    src = f.read()

if 'network_mode != \'host\'' in src and 'OH-TAB' in src and '[OH-TAB] use network_mode check' in src:
    print('extra_hosts fix already present ✓')
else:
    old_eh = (
        "                # Allow agent-server containers to resolve host.docker.internal\n"
        "                # and other custom hostnames for LAN deployments\n"
        "                # Note: extra_hosts is not needed with host network mode\n"
        "                extra_hosts=self.extra_hosts\n"
        "                if self.extra_hosts and not self.use_host_network\n"
        "                else None,"
    )
    new_eh = (
        "                # Allow agent-server containers to resolve host.docker.internal\n"
        "                # and other custom hostnames for LAN deployments\n"
        "                # [OH-TAB] use network_mode check: oh-tab- forces bridge mode\n"
        "                # even when SANDBOX_USE_HOST_NETWORK=true, so we must apply\n"
        "                # extra_hosts for bridge-mode containers regardless of the flag\n"
        "                extra_hosts=self.extra_hosts\n"
        "                if self.extra_hosts and network_mode != 'host'\n"
        "                else None,"
    )
    if old_eh in src:
        src = src.replace(old_eh, new_eh, 1)
        with open(SANDBOX_PATH, 'w') as f:
            f.write(src)
        print('extra_hosts fix applied ✓')
    else:
        print('WARNING: extra_hosts pattern not found! Check docker_sandbox_service.py')
        idx = src.find('extra_hosts=self.extra_hosts')
        if idx >= 0:
            print('Context:', repr(src[max(0,idx-100):idx+200]))

# Fix 2: webhook port from OH_WEB_URL (docker_sandbox_service.py)
with open(SANDBOX_PATH) as f:
    src = f.read()

if '[OH-TAB] bridge mode: use OH_WEB_URL port for webhook' in src:
    print('webhook port fix already present ✓')
else:
    old_wh = (
        "        env_vars[WEBHOOK_CALLBACK_VARIABLE] = (\n"
        "            f'http://host.docker.internal:{self.host_port}/api/v1/webhooks'\n"
        "        )"
    )
    new_wh = (
        "        # [OH-TAB] bridge mode: use OH_WEB_URL port for webhook so agent-server\n"
        "        # can call back to correct openhands app port\n"
        "        import os as _os, re as _re\n"
        "        _wh_port = self.host_port\n"
        "        if self.container_name_prefix == 'oh-tab-':\n"
        "            _web_url = _os.environ.get('OH_WEB_URL', '')\n"
        "            _m = _re.search(r':(\\d+)$', _web_url)\n"
        "            if _m:\n"
        "                _wh_port = int(_m.group(1))\n"
        "        env_vars[WEBHOOK_CALLBACK_VARIABLE] = (\n"
        "            f'http://host.docker.internal:{_wh_port}/api/v1/webhooks'\n"
        "        )"
    )
    if old_wh in src:
        src = src.replace(old_wh, new_wh, 1)
        with open(SANDBOX_PATH, 'w') as f:
            f.write(src)
        print('webhook port fix applied ✓')
    else:
        print('WARNING: webhook pattern not found!')
        idx = src.find('WEBHOOK_CALLBACK_VARIABLE')
        if idx >= 0:
            print('Context:', repr(src[max(0,idx-20):idx+200]))

# Fix 3: MCP URL replace 127.0.0.1 → host.docker.internal (live_status_app_conversation_service.py)
LIVE_PATH = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(LIVE_PATH) as f:
    src3 = f.read()

if '[OH-TAB] bridge mode: replace 127.0.0.1' in src3:
    print('MCP URL fix already present ✓')
else:
    old_mcp = "        mcp_url = f'{self.web_url}/mcp/mcp'"
    new_mcp = (
        "        # [OH-TAB] bridge mode: replace 127.0.0.1 with host.docker.internal so\n"
        "        # oh-tab- containers (bridge network) can reach the openhands app MCP server\n"
        "        mcp_url = f'{self.web_url}/mcp/mcp'.replace('http://127.0.0.1', 'http://host.docker.internal')"
    )
    if old_mcp in src3:
        src3 = src3.replace(old_mcp, new_mcp, 1)
        with open(LIVE_PATH, 'w') as f:
            f.write(src3)
        print('MCP URL fix applied ✓')
    else:
        print('WARNING: mcp_url pattern not found!')
        idx = src3.find('mcp_url')
        if idx >= 0:
            print('Context:', repr(src3[max(0,idx-50):idx+150]))

print('Done.')
