/**
 * Event-model helpers shared by week and month views. Everything is derived in
 * the user's fixed timezone (never the device zone).
 */

import type { CalendarEvent } from "@/generated/entities";
import {
  localDateKey,
  localTimeKey,
  minutesOfDay,
  parseInstant,
} from "@/lib/time/tz";

/** Which local day (YYYY-MM-DD) an event visually belongs to. */
export function eventDayKey(event: CalendarEvent, tz: string): string {
  const md = event.metadata?.displayDate;
  if (typeof md === "string" && md.length === 10) return md;
  return localDateKey(parseInstant(event.startAt), tz);
}

/** Start-of-event minutes since local midnight (0..1439). */
export function eventStartMinutes(event: CalendarEvent, tz: string): number {
  return minutesOfDay(parseInstant(event.startAt), tz);
}

/** Duration in minutes; deadlines (endAt null) return 0. */
export function eventDurationMinutes(event: CalendarEvent): number {
  if (!event.endAt) return 0;
  return (parseInstant(event.endAt).getTime() - parseInstant(event.startAt).getTime()) / 60000;
}

export function isDeadline(event: CalendarEvent): boolean {
  return event.type === "deadline";
}

export function eventStartClock(event: CalendarEvent, tz: string): string {
  return localTimeKey(parseInstant(event.startAt), tz);
}

export function eventEndClock(event: CalendarEvent, tz: string): string | null {
  if (!event.endAt) return null;
  return localTimeKey(parseInstant(event.endAt), tz);
}

export interface EventVisualStyle {
  /** fill background (css color) */
  bg: string;
  /** text/left border accent */
  accent: string;
  text: string;
}

const TYPE_LABEL: Record<string, string> = {
  course: "Course",
  recurring_schedule: "Recurring",
  todo_block: "Todo block",
  deadline: "Deadline",
};

export function eventTypeLabel(t: string): string {
  return TYPE_LABEL[t] ?? t;
}

/**
 * Color precedence (docs/domain-model.md §14 metadata): explicit color field on
 * course/recurring/todo; defaults per event type otherwise.
 */
export function eventColor(event: CalendarEvent): string | null {
  const c = event.metadata?.color;
  return typeof c === "string" && c ? c : null;
}

export function eventTitleFallback(event: CalendarEvent): string {
  if (event.title) return event.title;
  return eventTypeLabel(event.type);
}

/** Overlap in UTC instants (deadlines treated as zero-width). */
export function overlapsUtc(
  aStart: string,
  aEnd: string | null,
  bStart: string,
  bEnd: string | null
): boolean {
  const as = parseInstant(aStart).getTime();
  const ae = aEnd ? parseInstant(aEnd).getTime() : as;
  const bs = parseInstant(bStart).getTime();
  const be = bEnd ? parseInstant(bEnd).getTime() : bs;
  return as < be && bs < ae;
}

export function eventSubtitle(event: CalendarEvent): string | null {
  if (event.type === "course") {
    const parts: string[] = [];
    if (event.metadata?.teacher) parts.push(String(event.metadata.teacher));
    if (event.metadata?.location) parts.push(String(event.metadata.location));
    const week = event.metadata?.week;
    if (typeof week === "number") parts.push(`W${week}`);
    return parts.length ? parts.join(" · ") : null;
  }
  if (event.type === "todo_block" && event.metadata?.blockNote) {
    return String(event.metadata.blockNote);
  }
  if (event.type === "recurring_schedule") {
    return event.metadata?.notes ? String(event.metadata.notes) : null;
  }
  return null;
}
