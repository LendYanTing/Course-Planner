import { useSession } from "@/features/auth/session-store";

/** The authenticated user's immutable IANA timezone (docs/datetime.md §2). */
export function useTimezone(): string {
  return useSession((s) => s.user?.timezone ?? "Asia/Shanghai");
}
