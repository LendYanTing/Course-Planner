/**
 * Thin typed HTTP transport for the Course Planner REST API.
 *
 * - Talks to `/api/v1` on the same origin (Next rewrites proxy the Go backend
 *   in dev; a reverse proxy / Cloudflare does so in prod).
 * - Access token is injected from memory only (never localStorage,
 *   docs/security.md). A missing/expired access token triggers one silent
 *   /auth/refresh round-trip (HttpOnly cookie) and one retry.
 * - Parses the shared `{"data": ...}` / `{"error": {...}}` envelope
 *   (docs/api.md §2) and raises ApiError keyed on error.code.
 */

import { ApiErrorBody } from "@/generated/entities";

export const API_BASE = "/api/v1";

export type HttpMethod = "GET" | "POST" | "PATCH" | "DELETE";

export type QueryValue = string | number | boolean | null | undefined;

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly details?: Record<string, unknown>;
  constructor(status: number, code: string, message: string, details?: Record<string, unknown>) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

// ---- auth hooks (registered by features/auth) ---------------------------------

interface AuthHooks {
  getAccessToken: () => string | null;
  refresh: () => Promise<string | null>; // returns new access token or null
  onSessionExpired: () => void;
}

let hooks: AuthHooks = {
  getAccessToken: () => null,
  refresh: async () => null,
  onSessionExpired: () => {},
};

export function setAuthHooks(h: AuthHooks) {
  hooks = h;
}

let refreshing: Promise<string | null> | null = null;

/** POST /auth/refresh (single-flight) using the HttpOnly cookie. */
export async function refreshAccessToken(): Promise<string | null> {
  if (!refreshing) {
    refreshing = (async () => {
      try {
        const res = await rawFetch("/auth/refresh", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        });
        if (!res.ok) return null;
        const json = (await res.json()) as { data?: { accessToken?: string } };
        return json.data?.accessToken ?? null;
      } catch {
        return null;
      } finally {
        setTimeout(() => {
          refreshing = null;
        }, 0);
      }
    })();
  }
  return refreshing;
}

export interface RequestOptions {
  query?: Record<string, QueryValue>;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

async function rawFetch(path: string, init: RequestInit): Promise<Response> {
  return fetch(`${API_BASE}${path}`, {
    ...init,
    credentials: "include", // HttpOnly refresh cookie rides along
    headers: {
      ...(init.body ? { "Content-Type": "application/json" } : {}),
      ...init.headers,
    },
  });
}

async function doRequest(
  method: HttpMethod,
  path: string,
  body?: unknown,
  opts: RequestOptions = {}
): Promise<Response> {
  const token = hooks.getAccessToken();
  const headers: Record<string, string> = { ...opts.headers };
  if (token) headers.Authorization = `Bearer ${token}`;

  let res = await rawFetch(path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: opts.signal,
  });

  if (res.status === 401 && !path.startsWith("/auth/")) {
    // One silent refresh + retry.
    const fresh = await hooks.refresh();
    if (fresh) {
      res = await rawFetch(path, {
        method,
        headers: { ...headers, Authorization: `Bearer ${fresh}` },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: opts.signal,
      });
    } else {
      hooks.onSessionExpired();
    }
  }
  return res;
}

async function parseError(res: Response): Promise<ApiError> {
  let body: { error?: ApiErrorBody } | null = null;
  try {
    body = (await res.json()) as { error?: ApiErrorBody };
  } catch {
    body = null;
  }
  const err = body?.error;
  return new ApiError(
    res.status,
    err?.code ?? "INTERNAL_ERROR",
    err?.message ?? `HTTP ${res.status}`,
    err?.details
  );
}

async function execute<T>(
  method: HttpMethod,
  path: string,
  body?: unknown,
  opts?: RequestOptions
): Promise<T> {
  const res = await doRequest(method, path, body, opts);
  if (res.status === 204) return undefined as T;
  if (!res.ok) throw await parseError(res);
  const json = (await res.json()) as { data: T } | T;
  // Envelope is always {"data": ...}; be defensive.
  return (json as { data: T }).data;
}

function buildQuery(q: Record<string, QueryValue>): string {
  const sp = new URLSearchParams();
  for (const [k, v] of Object.entries(q)) {
    if (v === undefined || v === null) continue;
    sp.set(k, String(v));
  }
  const s = sp.toString();
  return s ? `?${s}` : "";
}

export const api = {
  get<T>(path: string, opts: RequestOptions = {}): Promise<T> {
    const q = opts.query ? buildQuery(opts.query) : "";
    return execute<T>("GET", `${path}${q}`, undefined, opts);
  },
  post<T>(path: string, body?: unknown, opts: RequestOptions = {}): Promise<T> {
    return execute<T>("POST", path, body, opts);
  },
  patch<T>(path: string, body?: unknown, opts: RequestOptions = {}): Promise<T> {
    return execute<T>("PATCH", path, body, opts);
  },
  del(path: string, opts: RequestOptions = {}): Promise<void> {
    return execute<void>("DELETE", path, undefined, opts);
  },
};

/** Raw text/csv upload (multipart not needed: body is the CSV itself). */
export async function postCsv<T>(path: string, csv: string, query?: Record<string, QueryValue>): Promise<T> {
  const q = query ? buildQuery(query) : "";
  const token = hooks.getAccessToken();
  let res = await rawFetch(`${path}${q}`, {
    method: "POST",
    headers: {
      "Content-Type": "text/csv",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: csv,
  });
  if (res.status === 401 && !path.startsWith("/auth/")) {
    const fresh = await hooks.refresh();
    if (fresh) {
      res = await rawFetch(`${path}${q}`, {
        method: "POST",
        headers: {
          "Content-Type": "text/csv",
          Authorization: `Bearer ${fresh}`,
        },
        body: csv,
      });
    } else {
      hooks.onSessionExpired();
    }
  }
  if (!res.ok) throw await parseError(res);
  const json = (await res.json()) as { data: T };
  return json.data;
}
