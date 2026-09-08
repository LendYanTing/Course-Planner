import { api } from "@/lib/api/http";
import type {
  RecurringRule,
  RecurringSchedule,
  Uuid,
} from "@/generated/entities";

export async function listRecurringSchedules(): Promise<RecurringSchedule[]> {
  return api.get<RecurringSchedule[]>("/recurring-schedules");
}

export async function createRecurringSchedule(payload: {
  title: string;
  color?: string | null;
  notes?: string | null;
  rule: RecurringRule;
}): Promise<RecurringSchedule> {
  return api.post<RecurringSchedule>("/recurring-schedules", payload);
}

export async function updateRecurringSchedule(
  id: Uuid,
  patch: Partial<{
    title: string;
    color: string | null;
    notes: string | null;
    rule: RecurringRule;
    baseRevision: number;
  }>
): Promise<RecurringSchedule> {
  return api.patch<RecurringSchedule>(`/recurring-schedules/${id}`, patch);
}

export async function deleteRecurringSchedule(id: Uuid): Promise<void> {
  return api.del(`/recurring-schedules/${id}`);
}
