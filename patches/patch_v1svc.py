path = '/app/frontend/build/assets/v1-conversation-service.api-BE_2IImp.js'
with open(path) as f:
    src = f.read()

if 'agent-server-proxy' in src:
    print('v1-svc.js 路由补丁已存在 ✓')
    exit(0)

old_C = 'function C(i){const t=v(i),a=h(i);return`${window.location.protocol==="https:"?"https:":"http:"}//${t}${a}`}'
new_C = 'function C(i){return`${window.location.protocol==="https:"?"https:":"http:"}//${window.location.host}/agent-server-proxy`}'
old_D = 'function $(i,t){if(!i)return null;const a=v(t),s=h(t);return`${window.location.protocol==="https:"?"wss:":"ws:"}//${a}${s}/sockets/events/${i}`}'
new_D = 'function $(i,t){if(!i)return null;return`${window.location.protocol==="https:"?"wss:":"ws:"}//${window.location.host}/agent-server-proxy/sockets/events/${i}`}'

ok = True
if old_C in src:
    src = src.replace(old_C, new_C, 1)
else:
    print('WARNING: C() pattern not found'); ok = False
if old_D in src:
    src = src.replace(old_D, new_D, 1)
else:
    print('WARNING: $() pattern not found'); ok = False

if ok:
    with open(path, 'w') as f:
        f.write(src)
    print('v1-svc.js 路由补丁已应用 ✓')
