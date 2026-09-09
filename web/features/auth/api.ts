import { api, ApiError } from "@/lib/api/http";
import type { SessionDto } from "@/generated/entities";

export async function login(username: string, password: string): Promise<SessionDto> {
  return api.post<SessionDto>("/auth/login", { username, password });
}

export interface 注册Input {
  username: string;
  email?: string | null;
  password: string;
  timezone: string;
}

export async function register(input: 注册Input): Promise<SessionDto> {
  return api.post<SessionDto>("/auth/register", input);
}

export function errorMessage(err: unknown): string {
  if (err instanceof ApiError) return err.message;
  if (err instanceof Error) return err.message;
  return "Something went wrong";
}
