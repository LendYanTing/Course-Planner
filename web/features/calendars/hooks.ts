import { useQueryClient } from "@tanstack/react-query";
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

function useInvalidate() {
  const qc = useQueryClient();
  return {
    invalidate: () => void qc.invalidateQueries({ queryKey: ["calendars"] }),
  };
}

export function useCalendars(enabled = true) {
  return useApiQuery<AcademicCalendar[]>({
    queryKey: ["calendars"],
    cacheKey: cacheKey("GET", "/calendars"),
    fetcher: () => listCalendars(),
    enabled,
  });
}

export function usePeriods(calendarId?: Uuid) {
  const { invalidate } = useInvalidate();
  const query = useApiQuery<PeriodTemplate[]>({
    queryKey: ["calendars", calendarId, "periods"],
    cacheKey: calendarId ? cacheKey("GET", `/calendars/${calendarId}/periods`) : "",
    fetcher: () => listPeriods(calendarId as Uuid),
    enabled: !!calendarId,
  });
  return { ...query, invalidate };
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

export async function mutatePeriodCreate(calendarId: Uuid, payload: PeriodCreatePayload) {
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
