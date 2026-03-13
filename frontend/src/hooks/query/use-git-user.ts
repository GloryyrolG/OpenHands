import { useQuery } from "@tanstack/react-query";
import React from "react";
import { usePostHog } from "posthog-js/react";
import { useConfig } from "./use-config";
import UserService from "#/api/user-service/user-service.api";
import { useShouldShowUserFeatures } from "#/hooks/use-should-show-user-features";
import { useLogout } from "../mutation/use-logout";
import { LOCAL_STORAGE_KEYS } from "#/utils/local-storage";

export const useGitUser = () => {
  const posthog = usePostHog();
  const { data: config } = useConfig();
  const logout = useLogout();

  // Use the shared hook to determine if we should fetch user data
  const shouldFetchUser = useShouldShowUserFeatures();

  const user = useQuery({
    queryKey: ["user"],
    queryFn: UserService.getUser,
    enabled: shouldFetchUser,
    retry: false,
    staleTime: 1000 * 60 * 5, // 5 minutes
    gcTime: 1000 * 60 * 15, // 15 minutes
  });

  React.useEffect(() => {
    if (user.data) {
      posthog.identify(user.data.login, {
        company: user.data.company,
        name: user.data.name,
        email: user.data.email,
        user: user.data.login,
        mode: config?.app_mode || "oss",
      });
    }
  }, [user.data]);

  // If we get a 401 here, it means that the integration tokens need to be
  // refreshed. Since this happens at login, we log out.
  // Skip for email auth: 401 just means no git provider, not expired token.
  React.useEffect(() => {
    const loginMethod = localStorage.getItem(LOCAL_STORAGE_KEYS.LOGIN_METHOD);
    if (user?.error?.response?.status === 401 && loginMethod !== "email") {
      logout.mutate();
    }
  }, [user.status]);

  return user;
};
