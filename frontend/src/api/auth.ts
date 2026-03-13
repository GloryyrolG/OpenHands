// Auth API client for multi-user mode
import axios from "axios";

const API_BASE = "";

export interface LoginRequest {
  email: string;
  password: string;
}

export interface RegisterRequest {
  email: string;
  username: string;
  password: string;
}

export interface AuthResponse {
  token: string;
  user: {
    user_id: string;
    email: string;
    username: string;
    created_at: string;
  };
}

export interface User {
  user_id: string;
  email: string;
  username: string;
  created_at: string;
}

// Auth API functions
export async function login(data: LoginRequest): Promise<AuthResponse> {
  const response = await axios.post(`${API_BASE}/api/auth/login`, data);
  return response.data;
}

export async function register(data: RegisterRequest): Promise<AuthResponse> {
  const response = await axios.post(`${API_BASE}/api/auth/register`, data);
  return response.data;
}

export async function getCurrentUser(token: string): Promise<User> {
  const response = await axios.get(`${API_BASE}/api/auth/me`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  return response.data;
}

export async function verifyToken(token: string): Promise<boolean> {
  try {
    await axios.get(`${API_BASE}/api/auth/verify`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    return true;
  } catch {
    return false;
  }
}

// Token management
const TOKEN_KEY = "auth_token";
const USER_KEY = "auth_user";
const LOGIN_METHOD_KEY = "openhands_login_method";

export function getStoredToken(): string | null {
  return localStorage.getItem(TOKEN_KEY);
}

export function setStoredToken(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  // Mark login method so root-layout doesn't redirect to /login
  localStorage.setItem(LOGIN_METHOD_KEY, "email");
}

export function removeStoredToken(): void {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
  localStorage.removeItem(LOGIN_METHOD_KEY);
}

export function getStoredUser(): User | null {
  const userStr = localStorage.getItem(USER_KEY);
  if (userStr) {
    try {
      return JSON.parse(userStr);
    } catch {
      return null;
    }
  }
  return null;
}

export function setStoredUser(user: User): void {
  localStorage.setItem(USER_KEY, JSON.stringify(user));
}
