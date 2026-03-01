"""patch_workspace.py: Per-conversation workspace isolation patches.
Merges: patch_per_conv_workspace + patch_git_workspace_root
"""

_LIVE_PATH = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'

# ══════════════════════════════════════════════════════
# Section 1: patch_per_conv_workspace
# ══════════════════════════════════════════════════════
with open(_LIVE_PATH) as f:
    _src = f.read()

if 'per-conversation workspace isolation' in _src:
    print('per-conversation workspace 补丁已存在 ✓')
else:
    # 1. 在 assert sandbox_spec is not None 之后插入目录创建逻辑
    old_block = '''            assert sandbox_spec is not None

            # Run setup scripts
            remote_workspace = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=sandbox_spec.working_dir,
            )'''

    new_block = '''            assert sandbox_spec is not None

            # --- per-conversation workspace isolation ---
            conv_working_dir = f"{sandbox_spec.working_dir}/{task.id.hex}"
            _tmp_ws = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=sandbox_spec.working_dir,
            )
            # Compute workspace root (parent dir, where Changes tab queries git)
            _ws_root = sandbox_spec.working_dir.rsplit("/", 1)[0]
            await _tmp_ws.execute_command(
                f"mkdir -p {conv_working_dir} && "
                f"([ -d {_ws_root}/.git ] || ("
                f"git init {_ws_root} && "
                f"mkdir -p {_ws_root}/.git/info && "
                f"printf 'bash_events/\\nconversations/\\n' > {_ws_root}/.git/info/exclude))",
                timeout=15.0,
            )
            # --- end per-conversation workspace isolation ---

            # Run setup scripts
            remote_workspace = AsyncRemoteWorkspace(
                host=agent_server_url,
                api_key=sandbox.session_api_key,
                working_dir=conv_working_dir,
            )'''

    if old_block not in _src:
        print('WARNING: 第一段 pattern 未匹配，跳过')
        raise RuntimeError("第一段 pattern 未匹配")
    _src = _src.replace(old_block, new_block, 1)

    # 2. 把 _build_start_conversation_request_for_user 调用中的 sandbox_spec.working_dir 改为 conv_working_dir
    old_build = '                    sandbox_spec.working_dir,'
    new_build = '                    conv_working_dir,  # per-conversation isolated dir'

    # 这个字符串在文件中可能出现多次，只替换第一次（在 _start_app_conversation 中的那次）
    if old_build in _src:
        _src = _src.replace(old_build, new_build, 1)
    else:
        print('WARNING: sandbox_spec.working_dir in _build 未匹配')

    with open(_LIVE_PATH, 'w') as f:
        f.write(_src)
    print('per-conversation workspace 补丁已应用 ✓')

# ══════════════════════════════════════════════════════
# Section 2: patch_git_workspace_root (upgrade for old installs)
# ══════════════════════════════════════════════════════
with open(_LIVE_PATH) as f:
    _src = f.read()

if '_ws_root = sandbox_spec.working_dir.rsplit' in _src:
    print('git workspace root 补丁已存在 ✓')
else:
    old_exec = (
        '            await _tmp_ws.execute_command(\n'
        '                f"mkdir -p {conv_working_dir} && cd {conv_working_dir} && "\n'
        '                f"[ -d .git ] || git init",\n'
        '                timeout=10.0,\n'
        '            )'
    )
    new_exec = (
        '            # Compute workspace root (parent dir, where Changes tab queries git)\n'
        '            _ws_root = sandbox_spec.working_dir.rsplit("/", 1)[0]\n'
        '            await _tmp_ws.execute_command(\n'
        '                f"mkdir -p {conv_working_dir} && "\n'
        '                f"([ -d {_ws_root}/.git ] || ("\n'
        '                f"git init {_ws_root} && "\n'
        '                f"mkdir -p {_ws_root}/.git/info && "\n'
        '                f"printf \'bash_events/\\\\nconversations/\\\\n\' > {_ws_root}/.git/info/exclude))",\n'
        '                timeout=15.0,\n'
        '            )'
    )

    if old_exec in _src:
        _src = _src.replace(old_exec, new_exec, 1)
        with open(_LIVE_PATH, 'w') as f:
            f.write(_src)
        print('git workspace root 补丁已应用 ✓')
    else:
        print('WARNING: execute_command pattern not found in service file!')
        idx = _src.find('execute_command')
        print('Context:', repr(_src[max(0, idx-20):idx+200]))
