import {
  fetchCalendarEvents,
  type EventsQuery,
} from "@/features/events/api";
import type { CalendarEvent, IsoInstant } from "@/generated/entities";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey } from "@/db/db";

export interface EventRange {
  start: IsoInstant;
  end: IsoInstant;
}

/** Single-range events query (covers one week or one month; docs/ui-interaction §11). */
export function useRangeEvents(range: EventRange | null, enabled = true) {
  return useApiQuery<CalendarEvent[]>({
    queryKey: ["events", "range", range?.start, range?.end],
    cacheKey: range
      ? cacheKey("GET", "/calendar/events", {
          start: range.start,
          end: range.end,
          includeCourses: true,
          includeRecurringSchedules: true,
          includeTodoBlocks: true,
          includeDeadlines: true,
        })
      : "",
    fetcher: () => fetchCalendarEvents(range as EventsQuery),
    enabled: !!range && enabled,
    staleTime: 60_000,
  });
}
