import React from "react";
import { cn } from "#/utils/utils";

// OpenAI-style user message bubble
export function UserMessage({ content }: { content: string }) {
  return (
    <div className="flex gap-4 py-4 px-4 md:px-8 bg-gray-50 dark:bg-gray-900/50">
      <div className="w-8 h-8 rounded-full bg-gray-200 dark:bg-gray-700 flex items-center justify-center flex-shrink-0">
        <svg viewBox="0 0 24 24" fill="none" className="w-5 h-5 text-gray-600 dark:text-gray-300">
          <path
            fill="currentColor"
            d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-2 15l-5-5 1.41-1.41L10 14.17l7.59-7.59L19 8l-9 9z"
          />
        </svg>
      </div>
      <div className="flex-1 max-w-3xl pt-1">
        <p className="text-gray-900 dark:text-gray-100 whitespace-pre-wrap leading-relaxed">
          {content}
        </p>
      </div>
    </div>
  );
}

// OpenAI-style assistant message bubble
export function AssistantMessage({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex gap-4 py-4 px-4 md:px-8">
      <div className="w-8 h-8 rounded-full bg-green-500 flex items-center justify-center flex-shrink-0">
        <svg viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5 text-white">
          <path d="M7.5 11C9.43 11 11 9.43 11 7.5S9.43 4 7.5 4 4 5.57 4 7.5 5.57 11 7.5 11zm9 0C18.43 11 20 9.43 20 7.5S18.43 4 16.5 4 14 5.57 14 7.5 15.57 11 16.5 11zM7.5 13C5.57 13 4 14.57 4 16.5S5.57 20 7.5 20 11 18.43 11 16.5 9.57 13 7.5 13zm9 0c-1.93 0-3.5 1.57-3.5 3.5S14.57 20 16.5 20 20 18.43 20 16.5 18.43 13 16.5 13z"/>
        </svg>
      </div>
      <div className="flex-1 max-w-3xl">
        {children}
      </div>
    </div>
  );
}

// System message
export function SystemMessage({ content }: { content: string }) {
  return (
    <div className="flex justify-center py-2">
      <div className="bg-gray-100 dark:bg-gray-800 rounded-lg px-4 py-2 text-sm text-gray-600 dark:text-gray-400">
        {content}
      </div>
    </div>
  );
}

// Typing indicator (three dots)
export function TypingIndicator() {
  return (
    <div className="flex gap-1 py-4 px-4 md:px-8">
      <div className="w-8 h-8 rounded-full bg-gray-200 dark:bg-gray-700 flex items-center justify-center flex-shrink-0">
        <svg viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5 text-gray-600 dark:text-gray-300">
          <path d="M7.5 11C9.43 11 11 9.43 11 7.5S9.43 4 7.5 4 4 5.57 4 7.5 5.57 11 7.5 11zm9 0C18.43 11 20 9.43 20 7.5S18.43 4 16.5 4 14 5.57 14 7.5 15.57 11 16.5 11zM7.5 13C5.57 13 4 14.57 4 16.5S5.57 20 7.5 20 11 18.43 11 16.5 9.57 13 7.5 13zm9 0c-1.93 0-3.5 1.57-3.5 3.5S14.57 20 16.5 20 20 18.43 20 16.5 18.43 13 16.5 13z"/>
        </svg>
      </div>
      <div className="flex items-center gap-1 ml-4">
        <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" style={{ animationDelay: '0ms' }} />
        <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" style={{ animationDelay: '150ms' }} />
        <div className="w-2 h-2 bg-gray-400 rounded-full animate-bounce" style={{ animationDelay: '300ms' }} />
      </div>
    </div>
  );
}

// Action buttons (stop, continue, etc.)
export function ActionButtons({
  isRunning,
  onStop,
  onContinue,
}: {
  isRunning: boolean;
  onStop?: () => void;
  onContinue?: () => void;
}) {
  return (
    <div className="flex gap-2 ml-4">
      {isRunning && onStop && (
        <button
          onClick={onStop}
          className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-red-500 hover:bg-red-600 text-white text-sm font-medium transition-colors"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" className="w-4 h-4">
            <rect x="6" y="6" width="12" height="12" rx="1" />
          </svg>
          Stop
        </button>
      )}
      {!isRunning && onContinue && (
        <button
          onClick={onContinue}
          className="flex items-center gap-2 px-3 py-1.5 rounded-lg bg-green-500 hover:bg-green-600 text-white text-sm font-medium transition-colors"
        >
          <svg viewBox="0 0 24 24" fill="currentColor" className="w-4 h-4">
            <path d="M8 5v14l11-7z" />
          </svg>
          Continue
        </button>
      )}
    </div>
  );
}
