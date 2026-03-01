# OpenHands UI 定制部署文档

## 概述

本项目对 OpenHands 前端进行了 UI 重设计，采用 OpenAI ChatGPT 风格界面。

## 代码改动

### 新增文件

| 文件路径 | 说明 |
|---------|------|
| `frontend/UI_REDESIGN.md` | UI 重设计文档 |
| `frontend/src/components/features/chat/chat-input.tsx` | OpenAI 风格输入框 |
| `frontend/src/components/features/chat/chat-interface-openai.tsx` | 主聊天界面布局 |
| `frontend/src/components/features/chat/chat-message-bubble.tsx` | 消息气泡组件 |
| `frontend/src/components/features/sidebar/chat-sidebar.tsx` | 侧边栏组件 |

### 修改文件

| 文件路径 | 改动 |
|---------|------|
| `frontend/src/routes/root-layout.tsx` | 引入 ChatSidebar，简化布局 |
| `frontend/src/routes/conversation.tsx` | 适配新布局 |
| `frontend/src/components/features/conversation/conversation-main/conversation-main.tsx` | 适配新 UI |

## 启动方式

### 1. 启动后端 (端口 3000)

```bash
cd /Users/nocode/.openclaw/workspace/OpenHands
.venv/bin/python -m uvicorn openhands.server.listen:app --host 0.0.0.0 --port 3000 --reload
```

### 2. 启动前端 (端口 3001)

```bash
cd /Users/nocode/.openclaw/workspace/OpenHands/frontend
npm run dev -- --port 3001 --host 127.0.0.1
```

### 3. Agent Server (已在本地运行)

```bash
# 本地直接运行
python -m openhands.agent_server --host 0.0.0.0 --port 8000
```

或使用 Docker:
```bash
docker run -d \
  --name openhands-agent \
  -p 8000:8000 -p 8001:8001 -p 8011:8011 -p 8012:8012 \
  ghcr.io/openhands/agent-server:010e847-python
```

## 环境配置

### LLM 配置 (settings.json)

路径: `~/.openhands/settings.json`

```json
{
  "llm_model": "openai/MiniMax-M2.5",
  "llm_api_key": "your-api-key",
  "llm_base_url": "https://api.minimaxi.com/v1",
  "agent": "CodeActAgent"
}
```

### 必需环境变量

| 变量 | 说明 | 示例值 |
|-----|------|-------|
| `VITE_BACKEND_HOST` | 后端地址 | `127.0.0.1:3000` |
| `VITE_FRONTEND_PORT` | 前端端口 | `3001` |

## 访问地址

- 前端: http://localhost:3001
- 后端 API: http://localhost:3000
- Agent Server: http://localhost:8000

## 注意事项

1. 后端需要先启动，前端依赖后端 API
2. LLM 配置通过 Web UI 设置或直接修改 `~/.openhands/settings.json`
3. 前端修改代码会自动热重载
