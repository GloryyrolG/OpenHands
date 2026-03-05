#!/bin/bash
set -e

echo "=== OpenHands on klogin 一键部署 [multiuser] ==="
echo ""

# 1. 获取实例列表
echo ">>> 获取 klogin 实例列表..."
klogin instances list

echo ""
read -p "请输入你的 instance-id（如 your-name-test1）: " INSTANCE_ID

# 可选：GitHub repo URL（用于 git clone；若留空则 scp 上传本地构建产物）
REPO_URL="${OH_MULTI_REPO_URL:-https://github.com/GloryyrolG/OpenHands.git}"
REPO_BRANCH="${OH_MULTI_REPO_BRANCH:-multiuser}"

# JWT 密钥（生产建议通过 env 变量传入）
JWT_SECRET="${OH_MULTI_JWT_SECRET:-$(openssl rand -hex 32 2>/dev/null || echo "change-me-in-production")}"

# 2. 检查实例状态
STATUS=$(klogin instances list -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
    if item['metadata']['name'] == '$INSTANCE_ID':
        print(item.get('status', {}).get('status', 'UNKNOWN'))
        break
" 2>/dev/null || echo "UNKNOWN")

echo "实例状态: $STATUS"

if [ "$STATUS" = "TERMINATED" ]; then
    echo ">>> 启动实例..."
    klogin instances start "$INSTANCE_ID"
    echo "等待实例就绪（约60秒）..."
    sleep 60
fi

# 3. 在 klogin 实例上构建镜像 + 运行容器
echo ""
echo ">>> 在 klogin 实例上 git clone + docker build..."
ssh -o StrictHostKeyChecking=no "$INSTANCE_ID" bash << REMOTE
set -e

# 检查 Docker
if ! sudo docker info &>/dev/null 2>&1; then
    echo "错误: Docker 未安装，请先在本地运行："
    echo "  klogin instances apps sub <instance-id> -a docker"
    exit 1
fi
echo "Docker 已安装 ✓"

# 开放防火墙端口（bridge 容器访问宿主机服务需要显式放行）
sudo ufw allow 3005
echo "ufw allow 3005 ✓"
sudo ufw allow 8881
echo "ufw allow 8881 ✓"
sudo ufw allow 8882
echo "ufw allow 8882 ✓"

# 配置 host.docker.internal
EXTERNAL_IP=\$(hostname -I | awk '{print \$1}')
echo "实例 IP: \$EXTERNAL_IP"
sudo sed -i '/host.docker.internal/d' /etc/hosts
echo "\$EXTERNAL_IP host.docker.internal" | sudo tee -a /etc/hosts
echo "hosts 配置完成 ✓"

# 创建独立 settings 目录
mkdir -p ~/.openhands-multi

# 从主实例 settings 复制 LLM 配置（复用 base_url 改为 host.docker.internal）
CURRENT_MODEL=\$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.openhands/settings.json')) as f:
        d = json.load(f)
    print(d.get('llm_model', ''))
except: print('')
" 2>/dev/null)
CURRENT_APIKEY=\$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.openhands/settings.json')) as f:
        d = json.load(f)
    print(d.get('llm_api_key', ''))
except: print('')
" 2>/dev/null)
CURRENT_BASE_URL=\$(python3 -c "
import json, os
try:
    with open(os.path.expanduser('~/.openhands/settings.json')) as f:
        d = json.load(f)
    print(d.get('llm_base_url', ''))
except: print('')
" 2>/dev/null)
MODEL_SLUG=\$(echo "\$CURRENT_MODEL" | sed 's|.*/||')

if [ -n "\$CURRENT_MODEL" ]; then
    cat > ~/.openhands-multi/settings.json << EOF
{
  "llm_model": "\$CURRENT_MODEL",
  "llm_api_key": "\$CURRENT_APIKEY",
  "llm_base_url": "http://host.docker.internal:8881/llm/\$MODEL_SLUG/v1",
  "agent": "CodeActAgent",
  "language": "en",
  "enable_default_condenser": true
}
EOF
    echo "settings.json 已创建（LLM: \$CURRENT_MODEL via host.docker.internal）✓"
else
    echo "警告: 未找到现有 LLM 配置，用户需在 Settings 页面手动配置"
fi

# 清理旧容器
sudo docker ps -a --filter name=oh-multi- -q | xargs -r sudo docker rm -f 2>/dev/null || true
sudo docker rm -f openhands-app-multi 2>/dev/null || true

# Git clone（或更新）multiuser 分支源码
if [ -d /tmp/openhands-multiuser/.git ]; then
    echo ">>> 更新已有源码..."
    cd /tmp/openhands-multiuser
    git fetch origin
    git reset --hard origin/${REPO_BRANCH}
else
    echo ">>> 克隆源码..."
    rm -rf /tmp/openhands-multiuser
    git clone --depth=1 --branch ${REPO_BRANCH} ${REPO_URL} /tmp/openhands-multiuser
fi
echo "源码就绪 ✓"

# 构建 Docker 镜像（第一次较慢，约 10-20 分钟）
echo ">>> 构建 Docker 镜像..."
cd /tmp/openhands-multiuser
sudo docker build \
    -f containers/app/Dockerfile.multiuser \
    -t openhands-multi:latest \
    --build-arg OPENHANDS_BUILD_VERSION=multiuser-\$(git rev-parse --short HEAD 2>/dev/null || echo "dev") \
    .
echo "镜像构建完成 ✓"

# 启动容器
echo ">>> 启动 OpenHands multiuser..."
sudo docker run -d \
    --name openhands-app-multi \
    --network host \
    -e SANDBOX_USER_ID=0 \
    -e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
    -e AGENT_SERVER_IMAGE_TAG=1.10.0-python \
    -e LOG_ALL_EVENTS=true \
    -e SANDBOX_STARTUP_GRACE_SECONDS=120 \
    -e SANDBOX_CONTAINER_PREFIX=oh-multi- \
    -e SANDBOX_CONTAINER_URL_PATTERN=http://127.0.0.1:{port} \
    -e OH_WEB_URL=http://127.0.0.1:3005 \
    -e JWT_SECRET=${JWT_SECRET} \
    -e OPENHANDS_DEFAULT_LLM_MODEL="\${CURRENT_MODEL:-}" \
    -e OPENHANDS_DEFAULT_LLM_API_KEY="\${CURRENT_APIKEY:-}" \
    -e OPENHANDS_DEFAULT_LLM_BASE_URL="\${CURRENT_BASE_URL:-}" \
    -e ENABLE_MCP=false \
    -e OH_PERSISTENCE_DIR=/.openhands \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v ~/.openhands-multi:/.openhands \
    openhands-multi:latest

# 等待启动
echo "等待 OpenHands 启动..."
for i in \$(seq 1 30); do
    if sudo docker logs openhands-app-multi 2>&1 | grep -q "Uvicorn running"; then
        echo "OpenHands 启动成功 ✓"
        break
    fi
    [ "\$i" -eq 30 ] && echo "警告: 等待超时，请手动确认: sudo docker logs openhands-app-multi"
    sleep 2
done

# 恢复历史会话（重启后所有会话变 STOPPED）
echo ""
echo ">>> 恢复历史会话..."
python3 << 'PYEOF'
import urllib.request, urllib.error, json, time, sys, subprocess as _sp

BASE = 'http://127.0.0.1:3005'

def api(path, data=None):
    url = BASE + path
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body,
          headers={'Content-Type': 'application/json'} if body else {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {'error': e.code, 'body': e.read().decode()[:200]}
    except Exception as e:
        return {'error': str(e)}

convs = api('/api/conversations?limit=100')
if not isinstance(convs, list):
    convs = convs.get('results', convs.get('conversations', []))

v1 = [c for c in convs if c.get('conversation_version') == 'V1']
stopped = [c for c in v1 if c.get('status') == 'STOPPED']

# 清理 PAUSED 容器
for c in v1:
    cid = c.get('conversation_id', c.get('id', ''))
    cid_nodash = cid.replace('-', '')
    name = f'oh-multi-{cid_nodash}'
    out = _sp.run(['sudo', 'docker', 'inspect', '--format', '{{.State.Status}}', name],
                  capture_output=True, text=True).stdout.strip()
    if out == 'paused':
        ret = _sp.run(['sudo', 'docker', 'rm', '-f', name], capture_output=True)
        if ret.returncode == 0:
            print(f'  已清理 paused 容器: {name}')
            if c not in stopped:
                stopped.append(c)

print(f'共 {len(convs)} 个会话，{len(stopped)} 个需恢复')

ok = fail = 0
for c in stopped:
    cid = c.get('conversation_id', c.get('id', ''))
    r = api('/api/v1/app-conversations/stream-start', {'conversation_id': cid})
    if isinstance(r, dict) and 'error' in r:
        print(f'  ✗ {cid[:16]}... 失败(HTTP): {r.get("error")}')
        fail += 1
    elif isinstance(r, list):
        last = r[-1] if r else {}
        if isinstance(last, dict) and last.get('status') == 'ERROR':
            print(f'  ✗ {cid[:16]}... 失败: {last.get("detail","?")[:80]}')
            fail += 1
        else:
            first = r[0] if r else {}
            print(f'  ✓ {cid[:16]}... 恢复中（{first.get("status","?") if isinstance(first,dict) else "?"}）')
            ok += 1
    else:
        print(f'  ? {cid[:16]}... 未知响应: {str(r)[:60]}')
        fail += 1
    time.sleep(0.5)

print(f'恢复完成：{ok} 成功，{fail} 失败')
PYEOF

REMOTE

# 4. 配置 klogin ingress
echo ""
echo ">>> 配置 klogin ingress..."
klogin instances update "$INSTANCE_ID" --static-ip 2>/dev/null && echo "静态 IP 已设置 ✓" || echo "静态 IP 已存在或设置失败（可忽略）"
klogin ingresses create openhands-multi --instance "$INSTANCE_ID" --port 3005 --access-control=false 2>/dev/null \
  && echo "ingress 创建成功 ✓" \
  || echo "ingress 已存在（可忽略，域名: https://openhands-multi.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com）"

# 5. 建立本地 SSH 隧道并验证
echo ""
echo ">>> 建立本地隧道并验证..."
pkill -f "ssh.*-L 3006.*$INSTANCE_ID" 2>/dev/null || true
sleep 1
ssh -f -N -L 3006:127.0.0.1:3005 "$INSTANCE_ID"
sleep 2

echo "测试 API 连通性..."
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3006/api/options/models)
[ "$HTTP_CODE" = "200" ] && echo "API 连通 ✓" || echo "警告: API 返回 $HTTP_CODE"

echo "测试 agent-server 代理路由..."
PROXY_CODE=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3006/agent-server-proxy/health)
[ "$PROXY_CODE" = "200" ] && echo "agent-server 代理路由 ✓" || echo "警告: 代理路由返回 $PROXY_CODE"

echo "测试 sandbox port proxy..."
SPORT_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:3006/api/sandbox-port/8001/")
{ [ "$SPORT_CODE" = "200" ] || [ "$SPORT_CODE" = "302" ] || [ "$SPORT_CODE" = "403" ]; } && \
  echo "sandbox port proxy 路由 ✓（HTTP $SPORT_CODE）" || \
  echo "警告: sandbox port proxy 返回 $SPORT_CODE（正常，sandbox 启动后才可访问）"

echo "测试新建 V1 会话..."
CONV_V1_RESP=$(curl -s -X POST http://localhost:3006/api/v1/app-conversations \
  -H 'Content-Type: application/json' \
  -d '{"initial_user_msg": "hello"}')
CONV_V1_ID=$(echo "$CONV_V1_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)
CONV_V1_STATUS=$(echo "$CONV_V1_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || true)
if [ -z "$CONV_V1_ID" ]; then
    echo "警告: V1 API 无法创建会话，响应: $CONV_V1_RESP"
else
    echo "V1 会话创建成功 (ID: ${CONV_V1_ID:0:8}... status:$CONV_V1_STATUS) ✓"
fi

echo "等待 V1 会话就绪..."
if [ -n "$CONV_V1_ID" ]; then
    for i in $(seq 1 40); do
        STATUS_INFO=$(curl -s "http://localhost:3006/api/conversations/$CONV_V1_ID" | \
          python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''), d.get('runtime_status',''))" 2>/dev/null || true)
        if echo "$STATUS_INFO" | grep -q "RUNNING.*READY"; then
            echo "会话就绪 ✓"
            break
        fi
        [ "$i" -eq 40 ] && echo "警告: 会话 120s 内未就绪，当前状态: $STATUS_INFO"
        sleep 3
    done

    echo "测试 /api/proxy/events SSE 事件流..."
    API_KEY=$(curl -s "http://localhost:3006/api/conversations/$CONV_V1_ID" | \
      python3 -c "import sys,json; print(json.load(sys.stdin).get('session_api_key',''))" 2>/dev/null || true)
    if [ -n "$API_KEY" ]; then
        SSE_FIRST=$(curl -s -N --max-time 5 \
          -H 'Accept: text/event-stream' \
          "http://localhost:3006/api/proxy/events/$CONV_V1_ID/stream?resend_all=true&session_api_key=$API_KEY" \
          2>/dev/null | head -2)
        if echo "$SSE_FIRST" | grep -q '__connected__\|full_state'; then
            echo "SSE 事件流正常 ✓（浏览器 V1 会话将显示 Connected）"
        else
            echo "警告: /api/proxy/events SSE 未返回事件: $SSE_FIRST"
        fi
    fi
fi

# 6. 输出结果
echo ""
echo "========================================"
echo "✓ 部署完成！自建镜像包含以下功能："
echo "  - JWT 多用户认证（注册/登录）"
echo "  - 用户隔离目录结构"
echo "  - agent-server 反向代理（HTTP + SSE）"
echo "  - /api/proxy/events SSE 路由（klogin 可转发）"
echo "  - FakeWS（WebSocket→EventSource→/api/proxy/events）"
echo "  - per-conversation 工作目录隔离"
echo "  - sandbox port proxy（Code/App tab）"
echo "  - rate limiter 修复（SSE 排除 + X-Forwarded-For）"
echo "  - bridge 模式隔离（防 port 8000 冲突）"
echo "  - no-cache 替代 immutable（防浏览器永久缓存）"
echo ""
echo "访问方式："
echo "  域名（推荐）: https://openhands-multi.svc.${INSTANCE_ID}.klogin-user.mlplatform.apple.com"
echo "  本地隧道:     http://localhost:3006  (隧道已在后台运行)"
echo ""
echo "JWT_SECRET: ${JWT_SECRET}"
echo "  → 保存此密钥！重新部署时通过 OH_MULTI_JWT_SECRET 环境变量传入，确保登录状态不失效"
echo "========================================"
