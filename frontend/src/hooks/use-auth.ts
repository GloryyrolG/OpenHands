import { useState, useEffect, useCallback } from "react";
import { useQueryClient } from "@tanstack/react-query";
import {
  getStoredToken,
  setStoredToken,
  removeStoredToken,
  getStoredUser,
  setStoredUser,
  login as apiLogin,
  register as apiRegister,
  verifyToken,
  type LoginRequest,
  type RegisterRequest,
  type User,
} from "#/api/auth";

interface AuthState {
  isAuthenticated: boolean;
  isLoading: boolean;
  user: User | null;
  token: string | null;
}

export function useAuth() {
  const queryClient = useQueryClient();
  const [authState, setAuthState] = useState<AuthState>({
    isAuthenticated: false,
    isLoading: true,
    user: null,
    token: null,
  });

  // Check auth status on mount
  useEffect(() => {
    const checkAuth = async () => {
      const token = getStoredToken();
      const storedUser = getStoredUser();

      if (token && storedUser) {
        // Verify token is still valid
        const isValid = await verifyToken(token);
        if (isValid) {
          setAuthState({
            isAuthenticated: true,
            isLoading: false,
            user: storedUser,
            token,
          });
          return;
        }
      }

      // Invalid token, clear storage
      removeStoredToken();
      setAuthState({
        isAuthenticated: false,
        isLoading: false,
        user: null,
        token: null,
      });
    };

    checkAuth();
  }, []);

  const login = useCallback(
    async (data: LoginRequest) => {
      const response = await apiLogin(data);
      const { token, user } = response;

      setStoredToken(token);
      setStoredUser(user);
      // Invalidate stale isAuthed cache so root-layout sees true immediately
      queryClient.invalidateQueries({ queryKey: ["user", "authenticated"] });

      setAuthState({
        isAuthenticated: true,
        isLoading: false,
        user,
        token,
      });

      return response;
    },
    [queryClient],
  );

  const register = useCallback(
    async (data: RegisterRequest) => {
      const response = await apiRegister(data);
      const { token, user } = response;

      setStoredToken(token);
      setStoredUser(user);
      // Invalidate stale isAuthed cache so root-layout sees true immediately
      queryClient.invalidateQueries({ queryKey: ["user", "authenticated"] });

      setAuthState({
        isAuthenticated: true,
        isLoading: false,
        user,
        token,
      });

      return response;
    },
    [queryClient],
  );

  const logout = useCallback(() => {
    removeStoredToken();
    setAuthState({
      isAuthenticated: false,
      isLoading: false,
      user: null,
      token: null,
    });
  }, []);

  return {
    ...authState,
    login,
    register,
    logout,
  };
}

// Hook to get auth token for API calls
export function useAuthToken() {
  const [token, setToken] = useState<string | null>(getStoredToken());

  useEffect(() => {
    const handleStorageChange = () => {
      setToken(getStoredToken());
    };

    window.addEventListener("storage", handleStorageChange);
    return () => window.removeEventListener("storage", handleStorageChange);
  }, []);

  return token;
}
