import { useQueries, useQuery } from "@tanstack/react-query";
import axios from "axios";
import React from "react";
import ConversationService from "#/api/conversation-service/conversation-service.api";
import { useConversationId } from "#/hooks/use-conversation-id";
import { useRuntimeIsReady } from "#/hooks/use-runtime-is-ready";
import {
  useActiveConversation,
  useShareToken,
} from "#/hooks/query/use-active-conversation";
import { useBatchSandboxes } from "./use-batch-sandboxes";
import { useConversationConfig } from "./use-conversation-config";

/**
 * Unified hook to get active web host for both legacy (V0) and V1 conversations
 * - V0: Uses the legacy getWebHosts API endpoint and polls them
 * - V1: Gets worker URLs from sandbox exposed_urls (WORKER_1, WORKER_2, etc.)
 * - Share mode: Uses app_url from conversation metadata directly
 */
export const useUnifiedActiveHost = () => {
  const [activeHost, setActiveHost] = React.useState<string | null>(null);
  const { conversationId } = useConversationId();
  const runtimeIsReady = useRuntimeIsReady();
  const { data: conversation } = useActiveConversation();
  const shareToken = useShareToken();

  // [OH-MULTI] Share mode: backend returns app URL in conversation.url directly
  const isShareMode = !!shareToken;
  const shareAppUrl = isShareMode ? (conversation?.url || null) : null;

  const { data: conversationConfig, isLoading: isLoadingConfig } =
    useConversationConfig();

  const isV1Conversation = conversation?.conversation_version === "V1";
  const sandboxId = conversationConfig?.runtime_id;

  // Fetch sandbox data for V1 conversations (disabled in share mode)
  const sandboxesQuery = useBatchSandboxes(
    !isShareMode && sandboxId ? [sandboxId] : [],
  );

  // Get worker URLs from V1 sandbox or legacy web hosts from V0 (disabled in share mode)
  const { data, isLoading: hostsQueryLoading } = useQuery({
    queryKey: [conversationId, "unified", "hosts", isV1Conversation, sandboxId],
    queryFn: async () => {
      if (isV1Conversation) {
        if (
          !sandboxesQuery.data ||
          sandboxesQuery.data.length === 0 ||
          !sandboxesQuery.data[0]
        ) {
          return { hosts: [] };
        }

        const sandbox = sandboxesQuery.data[0];
        const workerUrls =
          sandbox.exposed_urls
            ?.filter((url) => url.name.startsWith("WORKER_"))
            .map((url) => url.url) || [];

        return { hosts: workerUrls };
      }

      const hosts = await ConversationService.getWebHosts(conversationId);
      return { hosts };
    },
    enabled:
      !isShareMode &&
      runtimeIsReady &&
      !!conversationId &&
      (!isV1Conversation || !!sandboxesQuery.data),
    initialData: { hosts: [] },
    meta: {
      disableToast: true,
    },
  });

  // Poll all hosts to find which one is active (disabled in share mode)
  const apps = useQueries({
    queries: isShareMode
      ? []
      : data.hosts.map((host) => ({
          queryKey: [conversationId, "unified", "hosts", host],
          queryFn: async () => {
            try {
              await axios.get(host);
              return host;
            } catch (e) {
              return "";
            }
          },
          refetchInterval: 3000,
          meta: {
            disableToast: true,
          },
        })),
  });

  const appsData = apps.map((app) => app.data);

  React.useEffect(() => {
    if (isShareMode) return; // Share mode sets activeHost via shareAppUrl
    const successfulApp = appsData.find((app) => app);
    setActiveHost(successfulApp || "");
  }, [appsData, isShareMode]);

  // Calculate overall loading state including dependent queries for V1
  const isLoading = isShareMode
    ? false
    : isV1Conversation
      ? isLoadingConfig || sandboxesQuery.isLoading || hostsQueryLoading
      : hostsQueryLoading;

  return {
    activeHost: isShareMode ? shareAppUrl : activeHost,
    isLoading,
  };
};
