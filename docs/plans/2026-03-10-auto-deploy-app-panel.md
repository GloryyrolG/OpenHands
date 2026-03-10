# Auto-Deploy App Panel Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 用户让 agent 写 app，写完自动部署在 port 8011，App panel 自动弹出展示。

**Architecture:**
- Agent 侧：自定义 agent-server 镜像，patch system prompt 加入 APP_AUTO_DEPLOY 指令
- 前端侧：监听 `activeHost` 从空变为有值，自动切换到 "served" tab

**Tech Stack:** bash (Dockerfile patch), TypeScript/React (frontend hook)

---

### Task 1: Dockerfile.agent-server-pp（自定义 agent-server 镜像）

**Files:**
- Create: `containers/app/Dockerfile.agent-server-pp`

**Step 1: 创建 Dockerfile**

内容：在 CDA 品牌替换基础上，再 append APP_AUTO_DEPLOY 段落到 system_prompt.j2：

```dockerfile
FROM ghcr.io/openhands/agent-server:1.10.0-python

USER root

RUN mv /usr/local/bin/openhands-agent-server /usr/local/bin/openhands-agent-server-orig

COPY <<'EOF' /usr/local/bin/openhands-agent-server
#!/bin/bash
/usr/local/bin/openhands-agent-server-orig "$@" &
PID=$!

for i in $(seq 1 50); do
    DIR=$(find /tmp/_MEI* -maxdepth 0 -type d 2>/dev/null | head -1)
    if [ -n "$DIR" ]; then
        # CDA branding
        find "$DIR" -name "system_prompt*.j2" -exec sed -i 's/OpenHands/CDA/g' {} + 2>/dev/null
        # APP_AUTO_DEPLOY instruction
        find "$DIR" -name "system_prompt*.j2" | while read f; do
            grep -q 'APP_AUTO_DEPLOY' "$f" 2>/dev/null || cat >> "$f" << 'PROMPT_EOF'

<APP_AUTO_DEPLOY>
When you finish writing a web application (Streamlit, Gradio, FastAPI, Flask, or any web framework), automatically start it in the background on port 8011 so users can preview it immediately.

Rules:
- Always bind to host 0.0.0.0 and port 8011
- Start in background (nohup ... & or similar) so it does not block
- After starting, wait 3 seconds then verify with: curl -s -o /dev/null -w '%{http_code}' http://localhost:8011

Common start commands:
- Streamlit: nohup streamlit run app.py --server.port 8011 --server.address 0.0.0.0 > /tmp/app.log 2>&1 &
- Gradio: ensure launch(server_port=8011, server_name="0.0.0.0") in code
- FastAPI: nohup uvicorn main:app --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &
- Flask: nohup flask run --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &
- Next.js/Node: nohup npm run dev -- --port 8011 > /tmp/app.log 2>&1 &
</APP_AUTO_DEPLOY>
PROMPT_EOF
        done
        break
    fi
    sleep 0.1
done

wait $PID
EOF

RUN chmod +x /usr/local/bin/openhands-agent-server

USER openhands
```

**Step 2: 验证文件存在**

```bash
ls -la containers/app/Dockerfile.agent-server-pp
```

---

### Task 2: 前端 auto-switch hook

**Files:**
- Create: `frontend/src/hooks/use-auto-switch-to-app-tab.ts`
- Modify: `frontend/src/components/features/conversation/conversation-main/conversation-main.tsx`

**Step 1: 创建 hook**

```typescript
// frontend/src/hooks/use-auto-switch-to-app-tab.ts
import React from "react";
import { useUnifiedActiveHost } from "#/hooks/query/use-unified-active-host";
import { useSelectConversationTab } from "#/hooks/use-select-conversation-tab";

/**
 * Auto-switches to the "served" (App) tab when an app becomes available on
 * the sandbox worker port (e.g., port 8011). Fires once per host URL change.
 */
export function useAutoSwitchToAppTab() {
  const { activeHost } = useUnifiedActiveHost();
  const { navigateToTab } = useSelectConversationTab();
  const prevHostRef = React.useRef<string | null>(null);

  React.useEffect(() => {
    const prev = prevHostRef.current;
    prevHostRef.current = activeHost;

    // Switch only when host goes from empty/null to a real URL
    if (activeHost && !prev) {
      navigateToTab("served");
    }
  }, [activeHost, navigateToTab]);
}
```

**Step 2: 在 conversation-main.tsx 中调用 hook**

在 `ConversationMain` 函数体顶部加一行：

```typescript
import { useAutoSwitchToAppTab } from "#/hooks/use-auto-switch-to-app-tab";

export function ConversationMain() {
  useAutoSwitchToAppTab();   // ← 新增这一行
  // ... 其余不变
```

**Step 3: 验证编译**

```bash
cd frontend && npm run typecheck 2>&1 | tail -10
```

---

### Task 3: 更新 setup-openhands-klogin-pp.sh

**Files:**
- Modify: `setup-openhands-klogin-pp.sh`

**Step 1: 在 git clone 之后、主容器 build 之前，插入 agent-server-pp 构建步骤**

在 `# 构建 Docker 镜像` 之前插入：

```bash
# 构建自定义 agent-server 镜像（含 APP_AUTO_DEPLOY system prompt patch）
echo ">>> 构建 agent-server-pp 镜像..."
cd /tmp/openhands-pp
sudo docker build \
    -f containers/app/Dockerfile.agent-server-pp \
    -t agent-server-pp:latest \
    .
echo "agent-server-pp 镜像构建完成 ✓"
```

**Step 2: 更新 docker run 参数**

将：
```
-e AGENT_SERVER_IMAGE_REPOSITORY=ghcr.io/openhands/agent-server \
-e AGENT_SERVER_IMAGE_TAG=1.10.0-python \
```

改为：
```
-e AGENT_SERVER_IMAGE_REPOSITORY=agent-server-pp \
-e AGENT_SERVER_IMAGE_TAG=latest \
```

**Step 3: 验证无残留旧 image 引用**

```bash
grep "AGENT_SERVER_IMAGE" setup-openhands-klogin-pp.sh
```
Expected: 两行都指向 `agent-server-pp` / `latest`

---

### Task 4: 提交并重新部署

**Step 1: 提交**

```bash
git add containers/app/Dockerfile.agent-server-pp \
        frontend/src/hooks/use-auto-switch-to-app-tab.ts \
        frontend/src/components/features/conversation/conversation-main/conversation-main.tsx \
        setup-openhands-klogin-pp.sh \
        docs/plans/
git commit -m "feat(prompt-plugin): auto-deploy app + App panel auto-switch"
git push origin prompt-plugin
```

**Step 2: 在服务器上重新部署**

```bash
ssh rongyu-chen-test1 "
cd /tmp/openhands-pp && git fetch origin && git reset --hard origin/prompt-plugin

# 构建 agent-server-pp
sudo docker build -f containers/app/Dockerfile.agent-server-pp -t agent-server-pp:latest .

# 重建主镜像
sudo docker build -f containers/app/Dockerfile.multiuser -t openhands-pp:latest \
  --build-arg OPENHANDS_BUILD_VERSION=pp-\$(git rev-parse --short HEAD) .

# 重启主容器
sudo docker rm -f openhands-app-pp
sudo docker run -d --name openhands-app-pp --network host \
  -e SANDBOX_USER_ID=0 \
  -e AGENT_SERVER_IMAGE_REPOSITORY=agent-server-pp \
  -e AGENT_SERVER_IMAGE_TAG=latest \
  [... 其余参数同前 ...]
  openhands-pp:latest uvicorn openhands.server.listen:app --host 0.0.0.0 --port 3007
"
```

**Step 3: 验证**

新建一个会话，发消息：`帮我写一个 Streamlit hello world app`

预期结果：
- Agent 写完代码后自动执行启动命令
- App panel 自动切换并展示 app
