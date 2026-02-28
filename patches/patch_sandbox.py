import re as _re
path = '/app/openhands/app_server/sandbox/docker_sandbox_service.py'
with open(path) as f:
    src = f.read()

if '[OH-TAB] per-session' in src and '[OH-TAB] bridge mode' in src:
    print('sandbox 补丁已存在（per-session 模式）✓')
    exit(0)

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
