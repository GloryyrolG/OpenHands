import os, shutil

ASSETS = '/app/frontend/build/assets'
INDEX  = '/app/frontend/build/index.html'

def copy_if_missing(src, dst, label):
    if os.path.exists(dst):
        print(f'{label} already exists ✓')
        return False
    shutil.copy2(src, dst)
    print(f'Copied {label}')
    return True

# Step 1: should-render-event-D7h-BMHP.js → BMHPx.js
sre_old = os.path.join(ASSETS, 'should-render-event-D7h-BMHP.js')
sre_new = os.path.join(ASSETS, 'should-render-event-D7h-BMHPx.js')
copy_if_missing(sre_old, sre_new, 'should-render-event-D7h-BMHPx.js')

# Step 2: update all files that reference old SRE name
sre_refs = [
    'conversation-uXvJtyCL.js', 'planner-tab-BB0IaNpo.js',
    'served-tab-Ath35J_c.js', 'shared-conversation-ly3fwRqE.js',
    'conversation-fHdubO7R.js', 'changes-tab-CXgkYeVu.js',
    'vscode-tab-CFaq3Fn-.js', 'manifest-8c9a7105.js',
]
for fname in sre_refs:
    p = os.path.join(ASSETS, fname)
    if not os.path.exists(p):
        continue
    with open(p) as f:
        src = f.read()
    if 'should-render-event-D7h-BMHP.js' in src and 'BMHPx' not in src:
        src = src.replace('should-render-event-D7h-BMHP.js', 'should-render-event-D7h-BMHPx.js')
        with open(p, 'w') as f:
            f.write(src)
        print(f'Updated SRE ref in {fname}')

# Step 3: conversation-fHdubO7R.js → Rx
conv_old = os.path.join(ASSETS, 'conversation-fHdubO7R.js')
conv_new = os.path.join(ASSETS, 'conversation-fHdubO7Rx.js')
copy_if_missing(conv_old, conv_new, 'conversation-fHdubO7Rx.js')

# Step 4: update manifest to reference new conversation file
mf = os.path.join(ASSETS, 'manifest-8c9a7105.js')
if os.path.exists(mf):
    with open(mf) as f:
        src = f.read()
    if 'conversation-fHdubO7R.js' in src:
        src = src.replace('conversation-fHdubO7R.js', 'conversation-fHdubO7Rx.js')
        with open(mf, 'w') as f:
            f.write(src)
        print('Updated conversation ref in manifest-8c9a7105.js')

# Step 5: manifest-8c9a7105.js → x
mf_new = os.path.join(ASSETS, 'manifest-8c9a7105x.js')
copy_if_missing(mf, mf_new, 'manifest-8c9a7105x.js')

# Step 6: update index.html to reference new manifest
with open(INDEX) as f:
    idx = f.read()
if 'manifest-8c9a7105.js' in idx:
    idx = idx.replace('manifest-8c9a7105.js', 'manifest-8c9a7105x.js')
    with open(INDEX, 'w') as f:
        f.write(idx)
    print('Updated manifest ref in index.html')
elif 'manifest-8c9a7105x.js' in idx:
    print('index.html already references manifest-8c9a7105x.js ✓')
else:
    print('WARNING: manifest not found in index.html')

# Step 7: z-suffix round — 为可能已被浏览器缓存为 immutable 的 x-suffix 文件创建全新 URL
# conversation-fHdubO7Rx.js → Rz.js（新 URL，浏览器从未见过，必然从服务器获取）
# manifest-8c9a7105x.js → z.js（引用 Rz，更新 index.html 指向 z）
# 根因：第一次部署时 immutable 头已生效，x 文件被浏览器缓存了旧内容；z 文件绕过此缓存。
conv_rx = os.path.join(ASSETS, 'conversation-fHdubO7Rx.js')
conv_rz = os.path.join(ASSETS, 'conversation-fHdubO7Rz.js')
mf_x = os.path.join(ASSETS, 'manifest-8c9a7105x.js')
mf_z = os.path.join(ASSETS, 'manifest-8c9a7105z.js')

if os.path.exists(conv_rx):
    shutil.copy2(conv_rx, conv_rz)
    print(f'Created conversation-fHdubO7Rz.js ✓')
else:
    print('WARNING: conversation-fHdubO7Rx.js not found, skipping z-rename')

if os.path.exists(mf_x):
    with open(mf_x) as f:
        mf_src = f.read()
    mf_src = mf_src.replace('conversation-fHdubO7Rx.js', 'conversation-fHdubO7Rz.js')
    with open(mf_z, 'w') as f:
        f.write(mf_src)
    print(f'Created manifest-8c9a7105z.js (refs Rz) ✓')

# Update index.html to reference manifest-z (supersedes manifest-x step above)
with open(INDEX) as f:
    idx = f.read()
if 'manifest-8c9a7105z.js' in idx:
    print('index.html already references manifest-z ✓')
elif 'manifest-8c9a7105x.js' in idx or 'manifest-8c9a7105.js' in idx:
    idx = idx.replace('manifest-8c9a7105x.js', 'manifest-8c9a7105z.js')
    idx = idx.replace('manifest-8c9a7105.js', 'manifest-8c9a7105z.js')
    with open(INDEX, 'w') as f:
        f.write(idx)
    print('Updated index.html: manifest → manifest-z ✓')

print('cache busting 完成 ✓')
