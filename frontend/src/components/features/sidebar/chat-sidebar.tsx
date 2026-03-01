import React from "react";
import { useNavigate, useLocation } from "react-router";
import { cn } from "#/utils/utils";

// Simple SVG Icons
const PlusIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M12 5v14M5 12h14" />
  </svg>
);

const MessageSquareIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
  </svg>
);

const SettingsIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
  </svg>
);

const LogOutIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <polyline points="16 17 21 12 16 7" />
    <line x1="21" y1="12" x2="9" y2="12" />
  </svg>
);

const ChevronDownIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <polyline points="6 9 12 15 18 9" />
  </svg>
);

const UserIcon: React.FC<{ className?: string }> = ({ className }) => (
  <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
    <circle cx="12" cy="7" r="4" />
  </svg>
);

interface Conversation {
  conversation_id: string;
  title?: string;
}

export function ChatSidebar() {
  const navigate = useNavigate();
  const location = useLocation();

  const [historyExpanded] = React.useState(true);

  // Mock conversations - will be replaced with real data
  const mockConversations: Conversation[] = [];

  return (
    <aside
      className={cn(
        "flex flex-col w-72 h-full bg-gray-50 border-r border-gray-200",
        "dark:bg-gray-900 dark:border-gray-700"
      )}
    >
      {/* Header */}
      <div className="p-4 border-b border-gray-200 dark:border-gray-700">
        <button
          onClick={() => navigate("/")}
          className={cn(
            "flex items-center gap-3 w-full px-4 py-3 rounded-lg",
            "bg-gray-100 hover:bg-gray-200 dark:bg-gray-800 dark:hover:bg-gray-700",
            "text-gray-800 dark:text-gray-200 font-medium",
            "transition-colors duration-200"
          )}
        >
          <PlusIcon className="w-5 h-5" />
          <span>New Chat</span>
        </button>
      </div>

      {/* History Section */}
      <div className="flex-1 overflow-y-auto p-2">
        <div className="flex items-center justify-between w-full px-3 py-2 text-sm text-gray-500 dark:text-gray-400">
          <span className="font-medium">History</span>
          <ChevronDownIcon className="w-4 h-4" />
        </div>

        <div className="mt-1 space-y-1">
          {mockConversations.length > 0 ? (
            mockConversations.map((conv) => (
              <button
                key={conv.conversation_id}
                onClick={() => navigate(`/conversation/${conv.conversation_id}`)}
                className={cn(
                  "flex items-center gap-2 w-full px-3 py-2 rounded-lg text-left",
                  "text-gray-700 dark:text-gray-300",
                  "hover:bg-gray-200 dark:hover:bg-gray-800",
                  "truncate",
                  location.pathname === `/conversation/${conv.conversation_id}`
                    ? "bg-gray-200 dark:bg-gray-800"
                    : ""
                )}
              >
                <MessageSquareIcon className="w-4 h-4 flex-shrink-0" />
                <span className="truncate text-sm">
                  {conv.title || "Untitled"}
                </span>
              </button>
            ))
          ) : (
            <p className="px-3 py-2 text-sm text-gray-400">No conversations yet</p>
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="p-2 border-t border-gray-200 dark:border-gray-700 space-y-1">
        <button
          onClick={() => navigate("/settings")}
          className={cn(
            "flex items-center gap-3 w-full px-3 py-2 rounded-lg",
            "text-gray-700 dark:text-gray-300",
            "hover:bg-gray-200 dark:hover:bg-gray-800",
            "transition-colors duration-200"
          )}
        >
          <SettingsIcon className="w-5 h-5" />
          <span>Settings</span>
        </button>

        {/* User Area */}
        <div className="flex items-center gap-3 px-3 py-2">
          <div className="w-8 h-8 rounded-full bg-gray-300 dark:bg-gray-600 flex items-center justify-center">
            <UserIcon className="w-5 h-5 text-gray-600 dark:text-gray-300" />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-sm font-medium text-gray-800 dark:text-gray-200 truncate">
              User
            </p>
          </div>
        </div>
      </div>
    </aside>
  );
}
