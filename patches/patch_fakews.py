import re
with open('/tmp/oh-index.html') as f:
    html = f.read()
# Remove any old FakeWS injection before re-injecting (ensures clean update)
if 'FakeWS' in html:
    html = re.sub(r'<script>\(function\(\)\{[^<]*FakeWS[^<]*\}\)\(\);</script>', '', html, flags=re.DOTALL)
    print('旧 FakeWS 已移除')
inject = (
    '<script>(function(){'
    # Fetch interceptor: rewrite 127.0.0.1:8000 → /agent-server-proxy
    'var _f=window.fetch;window.fetch=function(u,o){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _f.call(this,u,o);};'
    # XHR interceptor: same rewrite
    'var _X=window.XMLHttpRequest.prototype.open;'
    'window.XMLHttpRequest.prototype.open=function(m,u){'
    'if(typeof u==="string"&&u.indexOf("127.0.0.1:8000")>=0)'
    '{u=u.replace(/https?:\\/\\/127\\.0\\.0\\.1:8000/,"/agent-server-proxy");}'
    'return _X.apply(this,arguments);};'
    # Browser tab fix helpers: store pending browse data; apply via _ohApplyBrowse()
    # window.__oh_browser_store is exposed by patch 12 (browser-store JS chunk).
    'window.__oh_browse=null;'
    'window._ohApplyBrowse=function(){'
    'var d=window.__oh_browse;'
    'if(!d)return;'
    'var bs=window.__oh_browser_store;'
    'if(bs&&bs.getState){'
    'window.__oh_browse=null;'
    'var ss=d.ss;'
    'if(ss){bs.getState().setScreenshotSrc(ss.startsWith("data:")?ss:"data:image/png;base64,"+ss);}'
    'if(d.url){bs.getState().setUrl(d.url);}'
    '}else{setTimeout(window._ohApplyBrowse,300);}'  # retry until store is loaded
    '};'
    'var _WS=window.WebSocket;'
    'function FakeWS(url,proto){'
    'var self=this;self.readyState=0;self.onopen=null;self.onmessage=null;self.onclose=null;self.onerror=null;self._es=null;'
    'var m=url.match(/\\/sockets\\/events\\/([^?]+)/);'
    'var id=m?m[1]:"";'
    'var queryStr=url.indexOf("?")>=0?url.split("?")[1]:"";'
    'var params=new URLSearchParams(queryStr);'
    'var key=params.get("session_api_key")||"";'
    # sseUrl uses /api/proxy/events/ - klogin forwards /api/*
    'var sseUrl="/api/proxy/events/"+id+"/stream?resend_all=true";'
    'if(key)sseUrl+="&session_api_key="+encodeURIComponent(key);'
    'self.send=function(d){'
    'fetch("/api/proxy/conversations/"+id+"/events",'
    '{method:"POST",headers:{"Content-Type":"application/json","X-Session-API-Key":key},body:d})'
    '.catch(function(){});};'
    'self.close=function(){'
    'if(self._es){self._es.close();self._es=null;}'
    'self.readyState=3;if(self.onclose)self.onclose({code:1000,reason:"",wasClean:true});};'
    'var es=new EventSource(sseUrl);self._es=es;'
    'es.onopen=function(){self.readyState=1;if(self.onopen)self.onopen({});};'
    'es.onmessage=function(ev){'
    'if(ev.data==="__connected__")return;'
    'if(ev.data==="__closed__"){self.readyState=3;if(self.onclose)self.onclose({code:1000,wasClean:true});return;}'
    # Browser tab fix: detect browse observations (V1 and V0 formats), update store
    'try{'
    'var _d=JSON.parse(ev.data);'
    'var _ss="",_url="";'
    # V1 format: observation is {kind:"BrowserObservation", screenshot_data:..., url:...}
    'if(_d&&_d.observation&&typeof _d.observation==="object"&&_d.observation.kind==="BrowserObservation"){'
    '_ss=_d.observation.screenshot_data||"";_url=_d.observation.url||"";}'
    # V0 format: observation is string "browse"/"browse_interactive", extras.screenshot
    'else if(_d&&(_d.observation==="browse"||_d.observation==="browse_interactive")){'
    '_ss=(_d.extras&&_d.extras.screenshot)||"";_url=(_d.extras&&_d.extras.url)||"";}'
    'if(_ss||_url){window.__oh_browse={ss:_ss,url:_url};window._ohApplyBrowse();}'
    '}'
    'catch(e){}'
    'if(self.onmessage)self.onmessage({data:ev.data});};'
    'es.onerror=function(){'
    'if(self._es){self._es.close();self._es=null;}'
    'self.readyState=3;if(self.onerror)self.onerror({});'
    'if(self.onclose)self.onclose({code:1006,reason:"",wasClean:false});};}'
    'FakeWS.CONNECTING=0;FakeWS.OPEN=1;FakeWS.CLOSING=2;FakeWS.CLOSED=3;'
    'window.WebSocket=function(url,proto){'
    'if(url&&url.indexOf("/sockets/events/")>=0){return new FakeWS(url,proto);}'
    'return new _WS(url,proto);};'
    'window.WebSocket.prototype=_WS.prototype;'
    'window.WebSocket.CONNECTING=0;window.WebSocket.OPEN=1;window.WebSocket.CLOSING=2;window.WebSocket.CLOSED=3;'
    # [oh-tab-enter-fix] Enter key triggers blur in served-tab URL address bar
    # Only fires for inputs whose value looks like a URL (avoids affecting chat input)
    'document.addEventListener("keydown",function(e){'
    'if(e.key!=="Enter")return;'
    'var el=document.activeElement;'
    'if(!el||el.tagName!=="INPUT")return;'
    'var v=el.value||"";'
    'if(!v.match(/^(https?:\\/\\/|\\/api\\/sandbox-port\\/)/))return;'
    'if(!el.closest("form"))return;'
    'e.preventDefault();el.blur();'
    '},true);'
    '})();</script>'
)
html = html.replace('<head>', '<head>' + inject, 1)
with open('/tmp/oh-index.html', 'w') as f:
    f.write(html)
print('index.html FakeWS 已注入（使用 /api/proxy/events/ 路径）✓')
