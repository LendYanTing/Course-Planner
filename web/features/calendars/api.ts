import { api } from "@/lib/api/http";
import type {
  AcademicCalendar,
  CalendarCreatePayload,
  PeriodCreatePayload,
  PeriodTemplate,
  Uuid,
} from "@/generated/entities";

// ---- REST endpoints -----------------------------------------------------------

export async function listCalendars(): Promise<AcademicCalendar[]> {
  return api.get<AcademicCalendar[]>("/calendars");
}

export async function createCalendar(payload: CalendarCreatePayload): Promise<AcademicCalendar> {
  return api.post<AcademicCalendar>("/calendars", payload);
}

export async function getCalendar(id: Uuid): Promise<AcademicCalendar> {
  return api.get<AcademicCalendar>(`/calendars/${id}`);
}

export async function updateCalendar(
  id: Uuid,
  patch: Partial<CalendarCreatePayload> & { baseRevision?: number }
): Promise<AcademicCalendar> {
  return api.patch<AcademicCalendar>(`/calendars/${id}`, patch);
}

export async function deleteCalendar(id: Uuid): Promise<void> {
  return api.del(`/calendars/${id}`);
}

export async function listPeriods(calendarId: Uuid): Promise<PeriodTemplate[]> {
  return api.get<PeriodTemplate[]>(`/calendars/${calendarId}/periods`);
}

export async function createPeriod(
  calendarId: Uuid,
  payload: PeriodCreatePayload
): Promise<PeriodTemplate> {
  return api.post<PeriodTemplate>(`/calendars/${calendarId}/periods`, payload);
}

export async function updatePeriod(
  calendarId: Uuid,
  periodId: Uuid,
  patch: Partial<PeriodCreatePayload> & { baseRevision?: number }
): Promise<PeriodTemplate> {
  return api.patch<PeriodTemplate>(
    `/calendars/${calendarId}/periods/${periodId}`,
    patch
  );
}

export async function deletePeriod(calendarId: Uuid, periodId: Uuid): Promise<void> {
  return api.del(`/calendars/${calendarId}/periods/${periodId}`);
}
