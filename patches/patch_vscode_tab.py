import os, shutil, re

ASSETS = '/app/frontend/build/assets'

# 1. Fix vscode-tab JS files (both - and x suffix)
OLD_URL = 'if(r?.url)try{const f=new URL(r.url).protocol'
NEW_URL = 'if(r?.url)try{const f=new URL(r.url,window.location.origin).protocol'

for fname in ['vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-x.js']:
    p = os.path.join(ASSETS, fname)
    if not os.path.exists(p):
        print(f'{fname}: not found, skipping')
        continue
    with open(p) as f:
        src = f.read()
    if NEW_URL in src:
        print(f'{fname}: already patched ✓')
    elif OLD_URL in src:
        src = src.replace(OLD_URL, NEW_URL, 1)
        with open(p, 'w') as f:
            f.write(src)
        print(f'{fname}: URL parse fix applied ✓')
    else:
        print(f'{fname}: WARNING pattern not found')

# 2. Create vscode-tab-CFaq3Fn-z.js from patched original (prefer x if exists)
src_x = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-x.js')
src_orig = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-.js')
dst_z = os.path.join(ASSETS, 'vscode-tab-CFaq3Fn-z.js')
vt_src = src_x if os.path.exists(src_x) else src_orig
if os.path.exists(vt_src):
    shutil.copy2(vt_src, dst_z)
    print(f'Created vscode-tab-CFaq3Fn-z.js (from {os.path.basename(vt_src)}) ✓')
else:
    print('WARNING: no vscode-tab source found')

# 3. Determine uXvJtyCL source (prefer x if exists, fall back to plain)
conv_x    = os.path.join(ASSETS, 'conversation-uXvJtyCLx.js')
conv_orig = os.path.join(ASSETS, 'conversation-uXvJtyCL.js')
conv_src  = conv_x if os.path.exists(conv_x) else conv_orig

# 4. Create conversation-uXvJtyCLz.js (copy of best available source)
conv_z = os.path.join(ASSETS, 'conversation-uXvJtyCLz.js')
if os.path.exists(conv_src):
    shutil.copy2(conv_src, conv_z)
    print(f'Created conversation-uXvJtyCLz.js (from {os.path.basename(conv_src)}) ✓')
else:
    print('WARNING: no conversation-uXvJtyCL source found')

# 5. Update uXvJtyCLz.js to reference vscode-tab-z (replace all vscode-tab- variants)
if os.path.exists(conv_z):
    with open(conv_z) as f:
        csrc = f.read()
    if 'vscode-tab-CFaq3Fn-z.js' not in csrc:
        csrc2 = csrc.replace('vscode-tab-CFaq3Fn-x.js', 'vscode-tab-CFaq3Fn-z.js')
        csrc2 = csrc2.replace('vscode-tab-CFaq3Fn-.js', 'vscode-tab-CFaq3Fn-z.js')
        with open(conv_z, 'w') as f:
            f.write(csrc2)
        print('Updated uXvJtyCLz.js: vscode-tab → vscode-tab-z ✓')
    else:
        print('uXvJtyCLz.js already refs vscode-tab-z ✓')

# 6. Update conversation-fHdubO7Rz.js to import uXvJtyCLz
conv_rz = os.path.join(ASSETS, 'conversation-fHdubO7Rz.js')
if os.path.exists(conv_rz):
    with open(conv_rz) as f:
        rzc = f.read()
    if 'uXvJtyCLz' not in rzc:
        rzc2 = rzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        rzc2 = rzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if rzc2 != rzc:
            with open(conv_rz, 'w') as f:
                f.write(rzc2)
            print('Updated conversation-fHdubO7Rz.js → uXvJtyCLz ✓')
    else:
        print('fHdubO7Rz already refs uXvJtyCLz ✓')

# 7. Update manifest-z to reference uXvJtyCLz (for modulepreload hints)
mz = os.path.join(ASSETS, 'manifest-8c9a7105z.js')
if os.path.exists(mz):
    with open(mz) as f:
        mzc = f.read()
    if 'uXvJtyCLz' not in mzc:
        mzc2 = mzc.replace('conversation-uXvJtyCLx.js', 'conversation-uXvJtyCLz.js')
        mzc2 = mzc2.replace('conversation-uXvJtyCL.js', 'conversation-uXvJtyCLz.js')
        if mzc2 != mzc:
            with open(mz, 'w') as f:
                f.write(mzc2)
            print('Updated manifest-z → uXvJtyCLz ✓')
    else:
        print('manifest-z already refs uXvJtyCLz ✓')

print('Chain: manifest-z → fHdubO7Rz → uXvJtyCLz → BMHPx + vscode-tab-z ✓')
