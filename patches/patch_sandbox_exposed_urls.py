"""Patch 10: Rewrite VSCODE/WORKER exposed_urls to use /api/sandbox-port/{host_port}.
Per-session isolation: each container has unique host ports so each conversation
routes to its OWN container via Docker NAT. AGENT_SERVER stays absolute."""
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB-PERSESSION] Rewrite VSCODE/WORKER' in src:
    print('exposed_urls 补丁已存在（per-session host-port 模式）✓')
    exit(0)

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
    exit(0)

if '/api/sandbox-port/' in src:
    print('exposed_urls 代理路径补丁已存在（旧格式，手动检查）✓')
    exit(0)

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
    exit(1)

src = src.replace(old_return, new_return, 1)
with open(path, 'w') as f:
    f.write(src)
print('exposed_urls 代理路径补丁已应用（保留 AGENT_SERVER 不变）✓')
