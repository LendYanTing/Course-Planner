import { api } from "@/lib/api/http";
import type {
  CalendarEvent,
  FreeSlot,
  IsoInstant,
  SlotAlignment,
} from "@/generated/entities";

export interface EventsQuery {
  start: IsoInstant;
  end: IsoInstant;
  includeCourses?: boolean;
  includeRecurringSchedules?: boolean;
  includeTodoBlocks?: boolean;
  includeDeadlines?: boolean;
}

export async function fetchCalendarEvents(q: EventsQuery): Promise<CalendarEvent[]> {
  return api.get<CalendarEvent[]>("/calendar/events", {
    query: {
      start: q.start,
      end: q.end,
      includeCourses: q.includeCourses ?? true,
      includeRecurringSchedules: q.includeRecurringSchedules ?? true,
      includeTodoBlocks: q.includeTodoBlocks ?? true,
      includeDeadlines: q.includeDeadlines ?? true,
    },
  });
}

export interface FreeSlotQuery {
  start: IsoInstant;
  end: IsoInstant;
  durationMinutes?: number;
  alignment?: SlotAlignment;
  considerCourses?: boolean;
  considerRecurringSchedules?: boolean;
  considerTodoBlocks?: boolean;
}

export async function fetchFreeSlots(q: FreeSlotQuery): Promise<FreeSlot[]> {
  return api.get<FreeSlot[]>("/free-slots", {
    query: {
      start: q.start,
      end: q.end,
      durationMinutes: q.durationMinutes ?? 60,
      alignment: q.alignment ?? "period",
      considerCourses: q.considerCourses ?? true,
      considerRecurringSchedules: q.considerRecurringSchedules ?? true,
      considerTodoBlocks: q.considerTodoBlocks ?? true,
    },
  });
}
