"""patch_sandbox_infra.py: Sandbox container infrastructure patches.
Merges: patch_sandbox + patch_bridge_fixes + patch_sandbox_exposed_urls
"""
import re as _re

# ══════════════════════════════════════════════════════
# Section 1: patch_sandbox — bridge mode + oh-tab- prefix
# ══════════════════════════════════════════════════════
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB] per-session' in src and '[OH-TAB] bridge mode' in src:
    print('sandbox 补丁已存在（per-session 模式）✓')
else:
    # ── 升级：移除旧 sandbox 复用逻辑（per-session 模式每会话独立容器）──
    if '[OH-TAB] Reusing existing sandbox' in src:
        src = _re.sub(
            r'        # OH-TAB: reuse existing RUNNING sandbox.*?# Warn about port collision risk',
            '        # [OH-TAB] per-session: each conversation gets its own sandbox container\n        # Warn about port collision risk',
            src, count=1, flags=_re.DOTALL
        )
        print('已移除旧 sandbox 复用逻辑（升级为 per-session 模式）✓')
    elif '[OH-TAB] bridge mode' not in src:
        # 全新安装：只加 per-session 标记，不加复用逻辑
        old_fresh = '        """Start a new sandbox."""\n        # Warn about port collision risk'
        if old_fresh in src:
            src = src.replace(old_fresh,
                '        """Start a new sandbox."""\n'
                '        # [OH-TAB] per-session: each conversation gets its own sandbox container\n'
                '        # Warn about port collision risk',
                1)
            print('per-session 标记已添加（全新安装）✓')
        else:
            print('警告: start_sandbox pattern 未匹配，跳过 per-session 标记')

    # Part 2: force bridge mode for oh-tab- to avoid port 8000 conflict with other deployments
    old_net = '        # Determine network mode\n        network_mode = \'host\' if self.use_host_network else None\n\n        if self.use_host_network:'
    new_net = '''        # Determine network mode
        network_mode = 'host' if self.use_host_network else None

        # [OH-TAB] bridge mode: avoid port 8000 conflict with other openhands deployments
        if self.container_name_prefix == 'oh-tab-':
            network_mode = None  # bridge mode
            port_mappings = {}
            for exposed_port in self.exposed_ports:
                host_port = self._find_unused_port()
                port_mappings[exposed_port.container_port] = host_port
                env_vars[exposed_port.name] = str(host_port)
                _logger.info(f'[OH-TAB] bridge mode: container port {exposed_port.container_port} -> host port {host_port}')

        if self.use_host_network and self.container_name_prefix != 'oh-tab-':'''
    if old_net in src:
        src = src.replace(old_net, new_net, 1)
        print('sandbox bridge-mode 补丁已应用（oh-tab- 使用 bridge 避免 port 8000 冲突）✓')
    else:
        print('警告: sandbox bridge-mode 补丁 pattern 未匹配，跳过')

    with open(path, 'w') as f:
        f.write(src)

    # 修改 agent-server 容器前缀，避免与其他 openhands 实例冲突
    prefix_old = "container_name_prefix: str = 'oh-agent-server-'"
    prefix_new = "container_name_prefix: str = 'oh-tab-'"
    with open(path) as f:
        src2 = f.read()
    if prefix_new in src2:
        print("container_name_prefix 'oh-tab-' 已存在 ✓")
    elif prefix_old in src2:
        src2 = src2.replace(prefix_old, prefix_new, 1)
        with open(path, 'w') as f:
            f.write(src2)
        print("container_name_prefix 改为 'oh-tab-' ✓")
    else:
        print('警告: container_name_prefix pattern 未匹配，跳过')

# ══════════════════════════════════════════════════════
# Section 2: patch_bridge_fixes — extra_hosts / webhook port / MCP URL
# ══════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════
# Section 3: patch_sandbox_exposed_urls — exposed_urls rewrite
# ══════════════════════════════════════════════════════
"""Patch 10: Rewrite VSCODE/WORKER exposed_urls to use /api/sandbox-port/{host_port}.
Per-session isolation: each container has unique host ports so each conversation
routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute."""
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB-PERSESSION] Rewrite VSCODE/WORKER' in src:
    print('exposed_urls 补丁已存在（per-session host-port 模式）✓')
else:
    # Upgrade from old container-port mode to host-port mode
    if '/api/sandbox-port/' in src and '_eu.port' in src and '[OH-TAB-PERSESSION]' not in src:
        print('升级 exposed_urls 补丁至 per-session host-port 模式...')
        old_old_return = (
            '        # Rewrite VSCODE/WORKER URLs to use proxy (AGENT_SERVER stays absolute for health checks)\n'
            '        if exposed_urls:\n'
            '            for _eu in exposed_urls:\n'
            '                if _eu.name != \'AGENT_SERVER\':\n'
            '                    import re as _re\n'
            "                    _eu.url = _re.sub(r'https?://[^/]+', f'/api/sandbox-port/{_eu.port}', _eu.url, count=1)\n"
        )
        new_new_return = (
            '        # [OH-TAB-PERSESSION] Rewrite VSCODE/WORKER URLs to use proxy with HOST PORT.\n'
            '        # Per-session: each container gets unique published host ports.\n'
            '        # Use the host port from _eu.url (e.g. http://127.0.0.1:39377) so each conversation\n'
            '        # routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute.\n'
            '        if exposed_urls:\n'
            '            import re as _re\n'
            '            import urllib.parse as _up\n'
            '            for _eu in exposed_urls:\n'
            '                if _eu.name != \'AGENT_SERVER\':\n'
            '                    _parsed = _up.urlparse(_eu.url)\n'
            '                    _host_port = _parsed.port or _eu.port\n'
            "                    _eu.url = f'/api/sandbox-port/{_host_port}'\n"
        )
        if old_old_return in src:
            src = src.replace(old_old_return, new_new_return, 1)
            with open(path, 'w') as f:
                f.write(src)
            print('升级完成：exposed_urls per-session host-port 模式 ✓')
        else:
            print('WARNING: old exposed_urls pattern not found, skipping upgrade')
    else:
        if '/api/sandbox-port/' in src:
            print('exposed_urls 代理路径补丁已存在（旧格式，手动检查）✓')
        else:
            old_return = '''        return SandboxInfo(
            id=container.name,
            created_by_user_id=None,
            sandbox_spec_id=container.image.tags[0],
            status=status,
            session_api_key=session_api_key,
            exposed_urls=exposed_urls,'''

            new_return = '''        # [OH-TAB-PERSESSION] Rewrite VSCODE/WORKER URLs to use proxy with HOST PORT.
        # Per-session: each container gets unique published host ports.
        # Use the host port from _eu.url (e.g. http://127.0.0.1:39377) so each conversation
        # routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute.
        if exposed_urls:
            import re as _re
            import urllib.parse as _up
            for _eu in exposed_urls:
                if _eu.name != 'AGENT_SERVER':
                    _parsed = _up.urlparse(_eu.url)
                    _host_port = _parsed.port or _eu.port
                    # For VSCODE: preserve ?folder= param (tkn injected on 403 redirect)
                    if _eu.name == 'VSCODE':
                        _qs = _up.parse_qs(_parsed.query)
                        _folder = _qs.get('folder', [''])[0]
                        _eu.url = f'/api/sandbox-port/{_host_port}/' + (f'?folder={_folder}' if _folder else '')
                    else:
                        _eu.url = f'/api/sandbox-port/{_host_port}'

        return SandboxInfo(
            id=container.name,
            created_by_user_id=None,
            sandbox_spec_id=container.image.tags[0],
            status=status,
            session_api_key=session_api_key,
            exposed_urls=exposed_urls,'''

            if old_return not in src:
                print('WARNING: return SandboxInfo pattern 未匹配')
                raise RuntimeError('return SandboxInfo pattern 未匹配')

            src = src.replace(old_return, new_return, 1)
            with open(path, 'w') as f:
                f.write(src)
            print('exposed_urls 代理路径补丁已应用（保留 AGENT_SERVER 不变）✓')
