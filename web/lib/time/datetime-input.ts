/**
 * <input type="datetime-local>/<date>/<time> bridging.
 * Native inputs expose device-local values; we must always interpret the text
 * the user typed as wall-clock in the fixed user timezone (docs/datetime.md §4).
 */

import { civilToInstant, zonedParts } from "@/lib/time/tz";

/** "YYYY-MM-DDTHH:MM" (datetime-local value) for `iso` shown in `tz`. */
export function toLocalInputValue(iso: string, tz: string): string {
  const p = zonedParts(new Date(iso), tz);
  const d = `${p.year}-${pad(p.month)}-${pad(p.day)}`;
  const t = `${pad(p.hour)}:${pad(p.minute)}`;
  return `${d}T${t}`;
}

/** Parse a datetime-local value typed in the user timezone to UTC ISO. */
export function fromLocalInputValue(value: string, tz: string): string {
  const [date, time = "00:00"] = value.split("T");
  const [h, m] = time.split(":").map(Number);
  const [y, mo, d] = date.split("-").map(Number);
  return civilToInstant(
    `${y}-${pad(mo)}-${pad(d)}`,
    tz,
    { hour: h || 0, minute: m || 0 }
  ).toISOString();
}

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}
