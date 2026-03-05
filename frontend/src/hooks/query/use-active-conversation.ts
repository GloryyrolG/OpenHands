import { useEffect, useMemo } from "react";
import { useSearchParams } from "react-router";
import { useConversationId } from "#/hooks/use-conversation-id";
import { useUserConversation } from "./use-user-conversation";
import ConversationService from "#/api/conversation-service/conversation-service.api";

export const useShareToken = () => {
  const [searchParams] = useSearchParams();
  return useMemo(() => searchParams.get("share"), [searchParams]);
};

export const useActiveConversation = () => {
  const { conversationId } = useConversationId();
  const shareToken = useShareToken();

  // Don't poll if this is a task ID (format: "task-{uuid}")
  // Task polling is handled by useTaskPolling hook
  const isTaskId = conversationId.startsWith("task-");
  const actualConversationId = isTaskId ? null : conversationId;

  const userConversation = useUserConversation(
    actualConversationId,
    (query) => {
      // Don't poll shared views
      if (shareToken) return 0;
      if (query.state.data?.status === "STARTING") {
        return 3000; // 3 seconds
      }
      // TODO: Return conversation title as a WS event to avoid polling
      // This was changed from 5 minutes to 30 seconds to poll for updated conversation title after an auto update
      return 30000; // 30 seconds
    },
    shareToken,
  );

  useEffect(() => {
    const conversation = userConversation.data;
    ConversationService.setCurrentConversation(conversation || null);
  }, [
    conversationId,
    userConversation.isFetched,
    userConversation?.data?.status,
  ]);
  return userConversation;
};
