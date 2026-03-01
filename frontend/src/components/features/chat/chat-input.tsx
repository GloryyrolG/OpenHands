import React from "react";
import { cn } from "#/utils/utils";

interface ChatInputProps {
  value: string;
  onChange: (value: string) => void;
  onSubmit: () => void;
  disabled?: boolean;
  placeholder?: string;
}

export function ChatInput({
  value,
  onChange,
  onSubmit,
  disabled,
  placeholder = "Send a message...",
}: ChatInputProps) {
  const textareaRef = React.useRef<HTMLTextAreaElement>(null);

  // Auto-resize textarea
  React.useEffect(() => {
    if (textareaRef.current) {
      textareaRef.current.style.height = "auto";
      textareaRef.current.style.height = Math.min(textareaRef.current.scrollHeight, 200) + "px";
    }
  }, [value]);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (value.trim() && !disabled) {
        onSubmit();
      }
    }
  };

  return (
    <div
      className={cn(
        "relative flex items-end gap-2 mx-4 mb-4 p-2 rounded-xl",
        "bg-white dark:bg-gray-800",
        "border border-gray-200 dark:border-gray-700",
        "shadow-sm focus-within:shadow-md focus-within:border-gray-300 dark:focus-within:border-gray-600",
        "transition-all duration-200"
      )}
    >
      {/* Attachment Button */}
      <button
        className={cn(
          "p-2 rounded-lg text-gray-500 hover:text-gray-700 dark:hover:text-gray-300",
          "hover:bg-gray-100 dark:hover:bg-gray-700",
          "transition-colors",
          disabled && "opacity-50 cursor-not-allowed"
        )}
        disabled={disabled}
        title="Attach files"
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="w-5 h-5">
          <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
        </svg>
      </button>

      {/* Text Input */}
      <textarea
        ref={textareaRef}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={handleKeyDown}
        disabled={disabled}
        placeholder={placeholder}
        rows={1}
        className={cn(
          "flex-1 py-3 px-2 bg-transparent",
          "text-gray-900 dark:text-gray-100",
          "placeholder-gray-400 dark:placeholder-gray-500",
          "resize-none outline-none",
          "max-h-[200px] overflow-y-auto",
          disabled && "opacity-50 cursor-not-allowed"
        )}
      />

      {/* Send Button */}
      <button
        onClick={onSubmit}
        disabled={disabled || !value.trim()}
        className={cn(
          "p-2 rounded-lg transition-all duration-200",
          value.trim()
            ? "bg-green-500 hover:bg-green-600 text-white"
            : "bg-gray-200 dark:bg-gray-700 text-gray-400 dark:text-gray-500",
          disabled && "opacity-50 cursor-not-allowed",
          "flex items-center justify-center"
        )}
      >
        <svg viewBox="0 0 24 24" fill="currentColor" className="w-5 h-5">
          <path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z" />
        </svg>
      </button>
    </div>
  );
}
