"use client";

/**
 * Session state. The access token lives in memory only (module variable) and
 * is re-established after a page reload via the HttpOnly refresh cookie
 * (docs/security.md §2). Never persisted to localStorage.
 */

import { create } from "zustand";
import { api, setAuthHooks, refreshAccessToken } from "@/lib/api/http";
import type { SessionDto, UserDto } from "@/generated/entities";

export type SessionStatus = "booting" | "signedOut" | "signedIn";

interface SessionState {
  status: SessionStatus;
  user: UserDto | null;
  accessToken: string | null;
  expiresAt: number | null; // epoch ms (informational)
  setSession: (dto: SessionDto) => void;
  setUser: (user: UserDto) => void;
  clearSession: () => void;
}

export const useSession = create<SessionState>((set) => ({
  status: "booting",
  user: null,
  accessToken: null,
  expiresAt: null,
  setSession: (dto) =>
    set({
      status: "signedIn",
      user: {
        id: dto.id,
        username: dto.username,
        email: dto.email,
        timezone: dto.timezone,
        createdAt: dto.createdAt,
        updatedAt: dto.updatedAt,
      },
      accessToken: dto.accessToken,
      expiresAt: Date.now() + dto.expiresIn * 1000,
    }),
  setUser: (user) => set({ user }),
  clearSession: () =>
    set({
      status: "signedOut",
      user: null,
      accessToken: null,
      expiresAt: null,
    }),
}));

let memoryToken: string | null = null;

export function getMemoryToken(): string | null {
  return memoryToken;
}

function setMemoryToken(t: string | null) {
  memoryToken = t;
  useSession.setState(
    t === null ? { accessToken: null, expiresAt: null } : { accessToken: t }
  );
}

export async function refreshTokenOrNull(): Promise<string | null> {
  const fresh = await refreshAccessToken();
  if (fresh) setMemoryToken(fresh);
  return fresh;
}

export function clearAuthToken() {
  setMemoryToken(null);
}

/** Wire the transport layer to this store (call once at module import). */
export function installAuthHooks() {
  setAuthHooks({
    getAccessToken: () => getMemoryToken(),
    refresh: refreshTokenOrNull,
    onSessionExpired: () => {
      useSession.getState().clearSession();
    },
  });
}

/**
 * Bootstrap the session: silent-refresh via cookie if needed, then load /me.
 * Idempotent; run once from the root providers.
 */
export async function bootSession(): Promise<void> {
  installAuthHooks();
  const { status } = useSession.getState();
  if (status !== "booting") return;
  try {
    const me = await api.get<UserDto>("/me");
    useSession.getState().setUser(me);
    useSession.setState({ status: "signedIn" });
  } catch {
    useSession.getState().clearSession();
  }
}

export async function signIn(session: SessionDto) {
  setMemoryToken(session.accessToken);
  useSession.getState().setSession(session);
}

/** Logout: revoke the refresh token server-side (clears the HttpOnly cookie). */
export async function signOut(): Promise<void> {
  try {
    await api.post("/auth/logout", {});
  } catch {
    // Local logout still proceeds when the server is unreachable.
  }
  clearAuthToken();
  useSession.getState().clearSession();
}

/** Re-fetch /me and update the profile (e.g. after refresh). */
export async function refreshProfile(): Promise<UserDto | null> {
  try {
    const me = await api.get<UserDto>("/me");
    useSession.getState().setUser(me);
    return me;
  } catch {
    return null;
  }
}
