import glob, re, os

ASSETS = '/app/frontend/build/assets/'
patched_files = []

for js_file in sorted(glob.glob(f'{ASSETS}*.js')):
    try:
        with open(js_file) as f:
            src = f.read()
    except Exception:
        continue
    if 'screenshotSrc' not in src:
        continue
    if '__oh_browser_store' in src:
        print(f'Already exposed in {os.path.basename(js_file)} ✓')
        patched_files.append(js_file)
        continue

    # Find the store variable: search for setScreenshotSrc: (the setter, unique to browser store)
    # Pattern: VAR=FUNC(e=>({...setScreenshotSrc:...}))
    idx = src.find('setScreenshotSrc:')
    if idx < 0:
        continue

    # Scan backwards up to 500 chars for: VARNAME = FUNC(
    prefix = src[max(0, idx - 500):idx]
    matches = list(re.finditer(
        r'(?:^|[;{,\(\s])([A-Za-z_$][A-Za-z0-9_$]{1,20})\s*=\s*[A-Za-z_$][A-Za-z0-9_$]{1,20}\s*\(',
        prefix
    ))
    if not matches:
        print(f'Found setScreenshotSrc in {os.path.basename(js_file)} but could not identify store var')
        continue

    store_var = matches[-1].group(1)
    print(f'Identified browser store var: {store_var} in {os.path.basename(js_file)}')

    expose_code = (
        f'\ntry{{if(typeof {store_var}!=="undefined"&&{store_var}.getState)'
        f'{{window.__oh_browser_store={store_var};'
        f'if(window.__oh_browse&&window._ohApplyBrowse)window._ohApplyBrowse();'
        f'console.log("[OH] browser store exposed");}}}}catch(e){{}}\n'
    )
    with open(js_file, 'w') as f:
        f.write(src + expose_code)
    print(f'Browser store exposed in {os.path.basename(js_file)} ✓')
    patched_files.append(js_file)

if not patched_files:
    print('WARNING: Could not expose browser store - browser tab screenshots may not update')
