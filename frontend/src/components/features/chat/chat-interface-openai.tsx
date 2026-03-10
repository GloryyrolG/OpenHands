/* eslint-disable i18next/no-literal-string, react/button-has-type, @typescript-eslint/no-unused-vars */
import React from "react";
import { useConversationStore } from "#/stores/conversation-store";
import { ChatInput } from "./chat-input";
import {
  UserMessage,
  AssistantMessage,
  TypingIndicator,
} from "./chat-message-bubble";

interface Message {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
}

interface ChatInterfaceProps {
  messages: Message[];
  isLoading?: boolean;
  isAgentRunning?: boolean;
  onSendMessage: (content: string) => void;
  onStop?: () => void;
}

export function ChatInterface({
  messages,
  isLoading = false,
  isAgentRunning = false,
  onSendMessage,
  onStop,
}: ChatInterfaceProps) {
  const { messageToSend, setMessageToSend } = useConversationStore();
  const scrollRef = React.useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom when messages change
  React.useEffect(() => {
    if (scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [messages, isLoading]);

  const handleSend = () => {
    if (messageToSend?.text?.trim()) {
      onSendMessage(messageToSend.text);
      setMessageToSend("");
    }
  };

  return (
    <div className="flex flex-col h-full bg-white dark:bg-gray-900">
      {/* Messages Area */}
      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        {messages.length === 0 && !isLoading && (
          <div className="flex flex-col items-center justify-center h-full text-center px-4">
            <div className="w-16 h-16 mb-6 rounded-full bg-gray-100 dark:bg-gray-800 flex items-center justify-center">
              <svg
                viewBox="0 0 24 24"
                fill="currentColor"
                className="w-8 h-8 text-gray-600 dark:text-gray-400"
              >
                <path d="M7.5 11C9.43 11 11 9.43 11 7.5S9.43 4 7.5 4 4 5.57 4 7.5 5.57 11 7.5 11zm9 0C18.43 11 20 9.43 20 7.5S18.43 4 16.5 4 14 5.57 14 7.5 15.57 11 16.5 11zM7.5 13C5.57 13 4 14.57 4 16.5S5.57 20 7.5 20 11 18.43 11 16.5 9.57 13 7.5 13zm9 0c-1.93 0-3.5 1.57-3.5 3.5S14.57 20 16.5 20 20 18.43 20 16.5 18.43 13 16.5 13z" />
              </svg>
            </div>
            <h2 className="text-2xl font-semibold text-gray-800 dark:text-gray-200 mb-2">
              How can I help you today?
            </h2>
            <p className="text-gray-500 dark:text-gray-400 max-w-md">
              I can help you write code, debug issues, answer questions, and
              more.
            </p>
          </div>
        )}

        {messages.map((message) => (
          <React.Fragment key={message.id}>
            {message.role === "user" && (
              <UserMessage content={message.content} />
            )}
            {message.role === "assistant" && (
              <AssistantMessage>
                <div className="text-gray-900 dark:text-gray-100 whitespace-pre-wrap leading-relaxed">
                  {message.content}
                </div>
              </AssistantMessage>
            )}
            {message.role === "system" && (
              <div className="flex justify-center py-2">
                <div className="bg-gray-100 dark:bg-gray-800 rounded-lg px-4 py-2 text-sm text-gray-600 dark:text-gray-400">
                  {message.content}
                </div>
              </div>
            )}
          </React.Fragment>
        ))}

        {isLoading && <TypingIndicator />}
      </div>

      {/* Input Area */}
      <div className="border-t border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <ChatInput
          value={messageToSend?.text ?? ""}
          onChange={setMessageToSend}
          onSubmit={handleSend}
          disabled={isAgentRunning}
          placeholder={
            isAgentRunning ? "Agent is running..." : "Send a message..."
          }
        />

        {/* Stop Button when agent is running */}
        {isAgentRunning && onStop && (
          <div className="flex justify-center pb-4">
            <button
              onClick={onStop}
              className="flex items-center gap-2 px-4 py-2 rounded-lg bg-red-500 hover:bg-red-600 text-white font-medium transition-colors"
            >
              <svg viewBox="0 0 24 24" fill="currentColor" className="w-4 h-4">
                <rect x="6" y="6" width="12" height="12" rx="1" />
              </svg>
              Stop Generating
            </button>
          </div>
        )}

        <div className="text-center pb-2">
          <p className="text-xs text-gray-400">
            AI can make mistakes. Please verify important information.
          </p>
        </div>
      </div>
    </div>
  );
}
