with open('/app/openhands/server/middleware.py') as f:
    src = f.read()

if 'no-cache, must-revalidate' in src and 'immutable' not in src:
    print('CacheControlMiddleware 已设置 no-cache ✓')
else:
    src = src.replace(
        "'public, max-age=2592000, immutable'",
        "'no-cache, must-revalidate'"
    ).replace(
        '"public, max-age=2592000, immutable"',
        '"no-cache, must-revalidate"'
    )
    with open('/app/openhands/server/middleware.py', 'w') as f:
        f.write(src)
    print('CacheControlMiddleware: immutable → no-cache, must-revalidate ✓')
