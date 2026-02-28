with open('/app/openhands/server/middleware.py') as f:
    src = f.read()

old_check = (
    "    def is_rate_limited_request(self, request: StarletteRequest) -> bool:\n"
    "        if request.url.path.startswith('/assets'):\n"
    "            return False\n"
    "        # Put Other non rate limited checks here\n"
    "        return True\n"
)
new_check = (
    "    def is_rate_limited_request(self, request: StarletteRequest) -> bool:\n"
    "        path = request.url.path\n"
    "        if path.startswith('/assets'):\n"
    "            return False\n"
    "        # SSE/streaming: long-lived connections, not rapid requests, skip rate limit\n"
    "        if '/sockets/events/' in path and path.endswith('/sse'):\n"
    "            return False\n"
    "        if '/api/proxy/events/' in path and path.endswith('/stream'):\n"
    "            return False\n"
    "        return True\n"
)
old_key = "        key = request.client.host\n"
new_key = (
    "        # klogin proxies all traffic through a single IP; use X-Forwarded-For for real client\n"
    "        key = request.headers.get('x-forwarded-for', '').split(',')[0].strip() or (request.client.host if request.client else '127.0.0.1')\n"
)

if 'sockets/events' in src and '/sse' in src and 'return False' in src[src.find('sockets/events'):]:
    print('rate limiter SSE 排除已存在 ✓')
elif old_check in src:
    src = src.replace(old_check, new_check, 1)
    print('SSE 路径排除限流 ✓')
else:
    print('WARNING: is_rate_limited_request pattern 未匹配，跳过')

if 'x-forwarded-for' in src:
    print('X-Forwarded-For key 已存在 ✓')
elif old_key in src:
    src = src.replace(old_key, new_key, 1)
    print('X-Forwarded-For key 修复 ✓')
else:
    print('WARNING: key pattern 未匹配，跳过')

with open('/app/openhands/server/middleware.py', 'w') as f:
    f.write(src)
