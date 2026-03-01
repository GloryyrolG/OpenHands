"""patch_frontend_js.py: Frontend JS and HTTP cache patches.
Merges: patch_cache_control + [socket.io polling] + patch_v1svc + patch_sre
        + patch_cache_bust + patch_browser_store_expose
"""
import os as _os, shutil as _shutil, glob as _glob, re as _re

_ASSETS = '/app/frontend/build/assets'
_MW_PATH = '/app/openhands/server/middleware.py'

# ══════════════════════════════════════════════════════
# Section 1: patch_cache_control
# ══════════════════════════════════════════════════════
with open(_MW_PATH) as _f1:
    _src1 = _f1.read()

if 'no-cache, must-revalidate' in _src1 and 'immutable' not in _src1:
    print('CacheControlMiddleware 已设置 no-cache ✓')
else:
    _src1 = _src1.replace(
        "'public, max-age=2592000, immutable'",
        "'no-cache, must-revalidate'"
    ).replace(
        '"public, max-age=2592000, immutable"',
        '"no-cache, must-revalidate"'
    )
    with open(_MW_PATH, 'w') as _f1:
        _f1.write(_src1)
    print('CacheControlMiddleware: immutable → no-cache, must-revalidate ✓')

# ══════════════════════════════════════════════════════
# Section 2: socket.io polling (migrated from setup.sh inline sed)
# ══════════════════════════════════════════════════════
import os as _os2
_JS_ASSETS = '/app/frontend/build/assets'
for _fname in ['markdown-renderer-Ci-ahARR.js', 'parse-pr-url-BOXiVwNz.js']:
    _fpath = _os2.path.join(_JS_ASSETS, _fname)
    if not _os2.path.exists(_fpath):
        print(f'socket.io: {_fname} not found, skipping')
        continue
    with open(_fpath) as _f:
        _js = _f.read()
    if '"polling","websocket"' in _js or '"polling","websocket"' in _js:
        print(f'socket.io polling 补丁已存在: {_fname} ✓')
    else:
        _js = _js.replace('transports:["websocket"]', 'transports:["polling","websocket"]')
        with open(_fpath, 'w') as _f:
            _f.write(_js)
        print(f'socket.io polling 补丁已应用: {_fname} ✓')

# ══════════════════════════════════════════════════════
# Section 3: patch_v1svc
# ══════════════════════════════════════════════════════
_v1svc_path = '/app/frontend/build/assets/v1-conversation-service.api-BE_2IImp.js'
with open(_v1svc_path) as _f3:
    _src3 = _f3.read()

if 'agent-server-proxy' in _src3:
    print('v1-svc.js 路由补丁已存在 ✓')
else:
    _old_C = 'function C(i){const t=v(i),a=h(i);return`${window.location.protocol==="https:"?"https:":"http:"}//${t}${a}`}'
    _new_C = 'function C(i){return`${window.location.protocol==="https:"?"https:":"http:"}//${window.location.host}/agent-server-proxy`}'
    _old_D = 'function $(i,t){if(!i)return null;const a=v(t),s=h(t);return`${window.location.protocol==="https:"?"wss:":"ws:"}//${a}${s}/sockets/events/${i}`}'
    _new_D = 'function $(i,t){if(!i)return null;return`${window.location.protocol==="https:"?"wss:":"ws:"}//${window.location.host}/agent-server-proxy/sockets/events/${i}`}'

    _ok3 = True
    if _old_C in _src3:
        _src3 = _src3.replace(_old_C, _new_C, 1)
    else:
        print('WARNING: C() pattern not found'); _ok3 = False
    if _old_D in _src3:
        _src3 = _src3.replace(_old_D, _new_D, 1)
    else:
        print('WARNING: $() pattern not found'); _ok3 = False

    if _ok3:
        with open(_v1svc_path, 'w') as _f3:
            _f3.write(_src3)
        print('v1-svc.js 路由补丁已应用 ✓')

# ══════════════════════════════════════════════════════
# Section 4: patch_sre
# ══════════════════════════════════════════════════════
_bmhp = _os.path.join(_ASSETS, 'should-render-event-D7h-BMHP.js')
_bmhpx = _os.path.join(_ASSETS, 'should-render-event-D7h-BMHPx.js')

with open(_bmhp) as _f4:
    _src4 = _f4.read()

if 'EventSource' in _src4:
    # 旧版有 EventSource 注入（可能有 broken regex），还原为原版不可行
    # 这里只打印警告，patch 5b 会处理 BMHPx 的 cache-bust
    print('WARNING: BMHP.js has EventSource injection - should be restored to original')
else:
    print('should-render-event.js 已是原版（无 FakeWS 注入）✓')
    # 确保 BMHPx.js 也是原版
    if not _os.path.exists(_bmhpx) or open(_bmhpx).read() != _src4:
        _shutil.copy2(_bmhp, _bmhpx)
        print('BMHPx.js 已同步为原版 ✓')
    else:
        print('BMHPx.js 已是原版 ✓')

# ══════════════════════════════════════════════════════
# Section 5: patch_cache_bust
# ══════════════════════════════════════════════════════
_INDEX = '/app/frontend/build/index.html'

def _copy_if_missing(src, dst, label):
    if _os.path.exists(dst):
        print(f'{label} already exists ✓')
        return False
    _shutil.copy2(src, dst)
    print(f'Copied {label}')
    return True

# Step 1: should-render-event-D7h-BMHP.js → BMHPx.js
_sre_old = _os.path.join(_ASSETS, 'should-render-event-D7h-BMHP.js')
_sre_new = _os.path.join(_ASSETS, 'should-render-event-D7h-BMHPx.js')
_copy_if_missing(_sre_old, _sre_new, 'should-render-event-D7h-BMHPx.js')

# Step 2: update all files that reference old SRE name
_sre_refs = [
    'conversation-uXvJtyCL.js', 'planner-tab-BB0IaNpo.js',
    'served-tab-Ath35J_c.js', 'shared-conversation-ly3fwRqE.js',
    'conversation-fHdubO7R.js', 'changes-tab-CXgkYeVu.js',
    'vscode-tab-CFaq3Fn-.js', 'manifest-8c9a7105.js',
]
for _fname5 in _sre_refs:
    _p5 = _os.path.join(_ASSETS, _fname5)
    if not _os.path.exists(_p5):
        continue
    with open(_p5) as _f5:
        _src5 = _f5.read()
    if 'should-render-event-D7h-BMHP.js' in _src5 and 'BMHPx' not in _src5:
        _src5 = _src5.replace('should-render-event-D7h-BMHP.js', 'should-render-event-D7h-BMHPx.js')
        with open(_p5, 'w') as _f5:
            _f5.write(_src5)
        print(f'Updated SRE ref in {_fname5}')

# Step 3: conversation-fHdubO7R.js → Rx
_conv_old = _os.path.join(_ASSETS, 'conversation-fHdubO7R.js')
_conv_new = _os.path.join(_ASSETS, 'conversation-fHdubO7Rx.js')
_copy_if_missing(_conv_old, _conv_new, 'conversation-fHdubO7Rx.js')

# Step 4: update manifest to reference new conversation file
_mf = _os.path.join(_ASSETS, 'manifest-8c9a7105.js')
if _os.path.exists(_mf):
    with open(_mf) as _f5:
        _src5 = _f5.read()
    if 'conversation-fHdubO7R.js' in _src5:
        _src5 = _src5.replace('conversation-fHdubO7R.js', 'conversation-fHdubO7Rx.js')
        with open(_mf, 'w') as _f5:
            _f5.write(_src5)
        print('Updated conversation ref in manifest-8c9a7105.js')

# Step 5: manifest-8c9a7105.js → x
_mf_new = _os.path.join(_ASSETS, 'manifest-8c9a7105x.js')
_copy_if_missing(_mf, _mf_new, 'manifest-8c9a7105x.js')

# Step 6: update index.html to reference new manifest
with open(_INDEX) as _f5:
    _idx5 = _f5.read()
if 'manifest-8c9a7105.js' in _idx5:
    _idx5 = _idx5.replace('manifest-8c9a7105.js', 'manifest-8c9a7105x.js')
    with open(_INDEX, 'w') as _f5:
        _f5.write(_idx5)
    print('Updated manifest ref in index.html')
elif 'manifest-8c9a7105x.js' in _idx5:
    print('index.html already references manifest-8c9a7105x.js ✓')
else:
    print('WARNING: manifest not found in index.html')

# Step 7: z-suffix round — 为可能已被浏览器缓存为 immutable 的 x-suffix 文件创建全新 URL
# conversation-fHdubO7Rx.js → Rz.js（新 URL，浏览器从未见过，必然从服务器获取）
# manifest-8c9a7105x.js → z.js（引用 Rz，更新 index.html 指向 z）
# 根因：第一次部署时 immutable 头已生效，x 文件被浏览器缓存了旧内容；z 文件绕过此缓存。
_conv_rx = _os.path.join(_ASSETS, 'conversation-fHdubO7Rx.js')
_conv_rz = _os.path.join(_ASSETS, 'conversation-fHdubO7Rz.js')
_mf_x = _os.path.join(_ASSETS, 'manifest-8c9a7105x.js')
_mf_z = _os.path.join(_ASSETS, 'manifest-8c9a7105z.js')

if _os.path.exists(_conv_rx):
    _shutil.copy2(_conv_rx, _conv_rz)
    print(f'Created conversation-fHdubO7Rz.js ✓')
else:
    print('WARNING: conversation-fHdubO7Rx.js not found, skipping z-rename')

if _os.path.exists(_mf_x):
    with open(_mf_x) as _f5:
        _mf_src5 = _f5.read()
    _mf_src5 = _mf_src5.replace('conversation-fHdubO7Rx.js', 'conversation-fHdubO7Rz.js')
    with open(_mf_z, 'w') as _f5:
        _f5.write(_mf_src5)
    print(f'Created manifest-8c9a7105z.js (refs Rz) ✓')

# Update index.html to reference manifest-z (supersedes manifest-x step above)
with open(_INDEX) as _f5:
    _idx5 = _f5.read()
if 'manifest-8c9a7105z.js' in _idx5:
    print('index.html already references manifest-z ✓')
elif 'manifest-8c9a7105x.js' in _idx5 or 'manifest-8c9a7105.js' in _idx5:
    _idx5 = _idx5.replace('manifest-8c9a7105x.js', 'manifest-8c9a7105z.js')
    _idx5 = _idx5.replace('manifest-8c9a7105.js', 'manifest-8c9a7105z.js')
    with open(_INDEX, 'w') as _f5:
        _f5.write(_idx5)
    print('Updated index.html: manifest → manifest-z ✓')

print('cache busting 完成 ✓')

# ══════════════════════════════════════════════════════
# Section 6: patch_browser_store_expose
# ══════════════════════════════════════════════════════
_patched_files6 = []

for _js_file6 in sorted(_glob.glob(f'{_ASSETS}/*.js')):
    try:
        with open(_js_file6) as _f6:
            _src6 = _f6.read()
    except Exception:
        continue
    if 'screenshotSrc' not in _src6:
        continue
    if '__oh_browser_store' in _src6:
        print(f'Already exposed in {_os.path.basename(_js_file6)} ✓')
        _patched_files6.append(_js_file6)
        continue

    # Find the store variable: search for setScreenshotSrc: (the setter, unique to browser store)
    # Pattern: VAR=FUNC(e=>({...setScreenshotSrc:...}))
    _idx6 = _src6.find('setScreenshotSrc:')
    if _idx6 < 0:
        continue

    # Scan backwards up to 500 chars for: VARNAME = FUNC(
    _prefix6 = _src6[max(0, _idx6 - 500):_idx6]
    _matches6 = list(_re.finditer(
        r'(?:^|[;{,\(\s])([A-Za-z_$][A-Za-z0-9_$]{1,20})\s*=\s*[A-Za-z_$][A-Za-z0-9_$]{1,20}\s*\(',
        _prefix6
    ))
    if not _matches6:
        print(f'Found setScreenshotSrc in {_os.path.basename(_js_file6)} but could not identify store var')
        continue

    _store_var6 = _matches6[-1].group(1)
    print(f'Identified browser store var: {_store_var6} in {_os.path.basename(_js_file6)}')

    _expose_code6 = (
        f'\ntry{{if(typeof {_store_var6}!=="undefined"&&{_store_var6}.getState)'
        f'{{window.__oh_browser_store={_store_var6};'
        f'if(window.__oh_browse&&window._ohApplyBrowse)window._ohApplyBrowse();'
        f'console.log("[OH] browser store exposed");}}}}catch(e){{}}\n'
    )
    with open(_js_file6, 'w') as _f6:
        _f6.write(_src6 + _expose_code6)
    print(f'Browser store exposed in {_os.path.basename(_js_file6)} ✓')
    _patched_files6.append(_js_file6)

if not _patched_files6:
    print('WARNING: Could not expose browser store - browser tab screenshots may not update')
