import { useQuery, useQueryClient } from "@tanstack/react-query";
import { cacheKey, dropCachePrefix } from "@/db/db";
import {
  listCalendars,
  listPeriods,
  createCalendar,
  updateCalendar,
  deleteCalendar,
  createPeriod,
  updatePeriod,
  deletePeriod,
} from "@/features/calendars/api";
import type {
  AcademicCalendar,
  CalendarCreatePayload,
  PeriodCreatePayload,
  PeriodTemplate,
  Uuid,
} from "@/generated/entities";
import { useApiQuery } from "@/lib/api/hooks";

export const CALENDAR_PREFIX = "/calendars";

export function useCalendars(enabled = true) {
  return useApiQuery<AcademicCalendar[]>({
    queryKey: ["calendars"],
    cacheKey: cacheKey("GET", "/calendars"),
    fetcher: () => listCalendars(),
    enabled,
  });
}

export function usePeriods(calendarId?: Uuid) {
  const query = useApiQuery<PeriodTemplate[]>({
    queryKey: ["calendars", calendarId, "periods"],
    cacheKey: calendarId
      ? cacheKey("GET", `/calendars/${calendarId}/periods`)
      : "",
    fetcher: () => listPeriods(calendarId as Uuid),
    enabled: !!calendarId,
  });
  return query;
}

/**
 * Period templates of every calendar the user owns, flattened for snap
 * boundaries (docs/ui-interaction.md §8). Single aggregated query.
 */
export function useAllPeriods() {
  const cals = useCalendars();
  return useQuery({
    queryKey: ["calendars", "all-periods"],
    queryFn: async () => {
      const list = cals.data ?? [];
      const grouped = new Map<Uuid, PeriodTemplate[]>();
      for (const cal of list) {
        const periods = await listPeriods(cal.id);
        grouped.set(cal.id, periods);
      }
      const byCalendar: { calendar: AcademicCalendar; periods: PeriodTemplate[] }[] =
        list.map((calendar) => ({
          calendar,
          periods: grouped.get(calendar.id) ?? [],
        }));
      return byCalendar;
    },
    enabled: !!cals.data,
    staleTime: 60_000,
  });
}

/** Minutes-of-day boundaries (00:00 and 24:00 implied) across all templates. */
export function periodBoundariesFromTemplates(
  groups: { calendar: AcademicCalendar; periods: PeriodTemplate[] }[]
): number[] {
  const set = new Set<number>([0, 24 * 60]);
  for (const g of groups) {
    for (const p of g.periods) {
      const [sh, sm] = p.startLocal.split(":").map(Number);
      const [eh, em] = p.endLocal.split(":").map(Number);
      set.add(sh * 60 + sm);
      set.add(eh * 60 + em);
    }
  }
  return [...set].sort((a, b) => a - b);
}

export async function mutateCalendarCreate(payload: CalendarCreatePayload) {
  const created = await createCalendar(payload);
  await dropCachePrefix(CALENDAR_PREFIX);
  return created;
}

export async function mutateCalendarUpdate(
  id: Uuid,
  patch: Partial<CalendarCreatePayload> & { baseRevision?: number }
) {
  const updated = await updateCalendar(id, patch);
  await dropCachePrefix(CALENDAR_PREFIX);
  return updated;
}

export async function mutateCalendarDelete(id: Uuid) {
  await deleteCalendar(id);
  await dropCachePrefix(CALENDAR_PREFIX);
}

export async function mutatePeriodCreate(
  calendarId: Uuid,
  payload: PeriodCreatePayload
) {
  const created = await createPeriod(calendarId, payload);
  await dropCachePrefix(CALENDAR_PREFIX);
  return created;
}

export async function mutatePeriodUpdate(
  calendarId: Uuid,
  periodId: Uuid,
  patch: Partial<PeriodCreatePayload> & { baseRevision?: number }
) {
  const updated = await updatePeriod(calendarId, periodId, patch);
  await dropCachePrefix(CALENDAR_PREFIX);
  return updated;
}

export async function mutatePeriodDelete(calendarId: Uuid, periodId: Uuid) {
  await deletePeriod(calendarId, periodId);
  await dropCachePrefix(CALENDAR_PREFIX);
}

export { useQueryClient };
