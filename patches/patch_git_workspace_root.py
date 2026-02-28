"""Fix: move git init from per-conv subdir to workspace root for Changes tab."""
path = '/app/openhands/app_server/app_conversation/live_status_app_conversation_service.py'
with open(path) as f:
    src = f.read()

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

if '_ws_root = sandbox_spec.working_dir.rsplit' in src:
    print('git workspace root 补丁已存在 ✓')
elif old_exec in src:
    src = src.replace(old_exec, new_exec, 1)
    with open(path, 'w') as f:
        f.write(src)
    print('git workspace root 补丁已应用 ✓')
else:
    print('WARNING: execute_command pattern not found in service file!')
    idx = src.find('execute_command')
    print('Context:', repr(src[max(0, idx-20):idx+200]))
