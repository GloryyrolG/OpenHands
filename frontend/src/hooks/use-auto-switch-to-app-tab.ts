import React from "react";
import { useUnifiedActiveHost } from "#/hooks/query/use-unified-active-host";
import { useSelectConversationTab } from "#/hooks/use-select-conversation-tab";

/**
 * Auto-switches to the "served" (App) tab when an app becomes available on
 * the sandbox worker port (e.g., port 8011). Fires once per host URL change
 * from empty to a real URL.
 */
export function useAutoSwitchToAppTab() {
  const { activeHost } = useUnifiedActiveHost();
  const { navigateToTab } = useSelectConversationTab();
  const prevHostRef = React.useRef<string | null>(null);

  React.useEffect(() => {
    const prev = prevHostRef.current;
    prevHostRef.current = activeHost;

    // Switch only when host transitions from falsy to a real URL
    if (activeHost && !prev) {
      navigateToTab("served");
    }
  }, [activeHost, navigateToTab]);
}
