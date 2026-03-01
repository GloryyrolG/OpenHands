# OpenHands UI Redesign - OpenAI ChatGPT Style

## 设计目标
- 参考 OpenAI ChatGPT 交互界面
- 移除所有 OpenHands 标识和品牌元素
- 简洁、现代的聊天界面

## 已创建的组件

### 1. ChatSidebar (`src/components/features/sidebar/chat-sidebar.tsx`)
- 左侧边栏，宽度 288px
- 包含 New Chat 按钮
- 历史对话列表（可折叠）
- Settings 入口
- 用户头像和信息

### 2. ChatMessageBubble (`src/components/features/chat/chat-message-bubble.tsx`)
- UserMessage - 用户消息气泡（灰色背景）
- AssistantMessage - AI 消息气泡（绿色头像）
- TypingIndicator - 打字指示器（三个点）
- ActionButtons - 操作/Continue）

###按钮（Stop 3. ChatInput (`src/components/features/chat/chat-input.tsx`)
- OpenAI 风格的输入框
- 圆角设计
- 附件按钮 + 发送按钮
- 自动调整高度

### 4. ChatInterface (`src/components/features/chat/chat-interface-openai.tsx`)
- 主聊天界面布局
- 消息列表区域
- 输入区域
- 空状态欢迎页面

## 布局设计

```
+------------------+----------------------------------------+
|                  |                                        |
|    侧边栏        |           聊天消息区域                  |
|    (288px)       |           (滚动区域)                   |
|                  |                                        |
|  - New Chat      |                                        |
|  - History       |                                        |
|  - Settings      |                                        |
|                  |----------------------------------------|
|                  |  输入框区域                            |
+------------------+----------------------------------------+
```

## 颜色方案

### 浅色模式
- 背景: #ffffff
- 侧边栏: #f9f9f9
- 用户消息: #f7f7f7
- AI消息: 透明
- 主色调: #10a37f (绿色)

### 深色模式
- 背景: #171717
- 侧边栏: #212121
- 用户消息: #2f2f2f
- AI消息: 透明
- 主色调: #10a37f (绿色)

## 需要修改的文件

### 1. `frontend/src/routes/root-layout.tsx`
- 移除顶部栏
- 使用新的 ChatSidebar 替换原 Sidebar

### 2. `frontend/src/routes/conversation.tsx`
- 简化布局，移除多余的标签页

### 3. `frontend/src/components/features/chat/chat-interface.tsx`
- 使用新的 ChatInterfaceOpenAI

### 4. `frontend/src/index.css`
- 添加 OpenAI 风格的全局样式
- 优化滚动条样式

### 5. `frontend/public/index.html` (如果存在)
- 修改页面标题，移除 OpenHands

## 后续步骤

1. 修改 `root-layout.tsx` 使用新布局
2. 集成新组件到主应用
3. 测试响应式设计
4. 添加暗色模式支持

## 注意事项

- 所有 SVG 图标已内联到组件中
- 保留原有功能（对话历史、设置等）
- 保持响应式设计（移动端适配）
