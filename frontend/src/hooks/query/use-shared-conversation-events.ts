import { useQuery } from "@tanstack/react-query";
import { sharedConversationService } from "#/api/shared-conversation-service.api";

export const useSharedConversationEvents = (conversationId?: string, shareToken?: string) =>
  useQuery({
    queryKey: ["shared-conversation-events", conversationId, shareToken],
    queryFn: () => {
      if (!conversationId) {
        throw new Error("Conversation ID is required");
      }
      return sharedConversationService.getSharedConversationEvents(
        conversationId,
        100,
        undefined,
        shareToken,
      );
    },
    enabled: !!conversationId,
    retry: false, // Don't retry for shared conversations
  });
