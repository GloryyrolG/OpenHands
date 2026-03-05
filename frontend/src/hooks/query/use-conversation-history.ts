import { useQuery } from "@tanstack/react-query";
import { useSearchParams } from "react-router";
import EventService from "#/api/event-service/event-service.api";
import { useUserConversation } from "#/hooks/query/use-user-conversation";

export const useConversationHistory = (conversationId?: string) => {
  const [searchParams] = useSearchParams();
  const shareToken = searchParams.get("share");
  const { data: conversation } = useUserConversation(
    conversationId ?? null,
    undefined,
    shareToken,
  );
  const conversationVersion = conversation?.conversation_version;

  return useQuery({
    queryKey: ["conversation-history", conversationId, conversationVersion],
    enabled: !!conversationId && !!conversation,
    queryFn: async () => {
      if (!conversationId || !conversationVersion) return [];

      if (conversationVersion === "V1") {
        return EventService.searchEventsV1(conversationId);
      }

      return EventService.searchEventsV0(conversationId);
    },
    staleTime: Infinity,
    gcTime: 30 * 60 * 1000, // 30 minutes — survive navigation away and back (AC5)
  });
};
