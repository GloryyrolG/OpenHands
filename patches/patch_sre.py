import os, shutil

ASSETS = '/app/frontend/build/assets'
bmhp = os.path.join(ASSETS, 'should-render-event-D7h-BMHP.js')
bmhpx = os.path.join(ASSETS, 'should-render-event-D7h-BMHPx.js')

with open(bmhp) as f:
    src = f.read()

if 'EventSource' in src:
    # 旧版有 EventSource 注入（可能有 broken regex），还原为原版不可行
    # 这里只打印警告，patch 5b 会处理 BMHPx 的 cache-bust
    print('WARNING: BMHP.js has EventSource injection - should be restored to original')
else:
    print('should-render-event.js 已是原版（无 FakeWS 注入）✓')
    # 确保 BMHPx.js 也是原版
    if not os.path.exists(bmhpx) or open(bmhpx).read() != src:
        shutil.copy2(bmhp, bmhpx)
        print('BMHPx.js 已同步为原版 ✓')
    else:
        print('BMHPx.js 已是原版 ✓')
