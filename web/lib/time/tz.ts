/**
 * Fixed-user-timezone date/time helpers (docs/datetime.md).
 *
 * The device clock/timezone NEVER interprets user schedule data. All absolute
 * instants are Date objects whose epoch is UTC. Rendering/round-tripping goes
 * through a single immutable IANA timezone obtained from the server (/me).
 *
 * Local civil "wall clock" <-> UTC instant conversion is implemented with
 * Intl.DateTimeFormat(timeZone) so DST rules for arbitrary IANA zones are
 * honoured without shipping tz data.
 */

export interface ZonedParts {
  year: number;
  month: number; // 1..12
  day: number; // 1..31
  hour: number; // 0..23
  minute: number; // 0..59
  second: number; // 0..59
}

const fmtCache = new Map<string, Intl.DateTimeFormat>();

function fmtFor(tz: string): Intl.DateTimeFormat {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    });
    fmtCache.set(tz, f);
  }
  return f;
}

/** Wall-clock fields of `instant` in `tz` (never the device zone). */
export function zonedParts(instant: Date, tz: string): ZonedParts {
  const m: Record<string, string> = {};
  for (const p of fmtFor(tz).formatToParts(instant)) {
    if (p.type !== "literal") m[p.type] = p.value;
  }
  return {
    year: Number(m.year),
    month: Number(m.month),
    day: Number(m.day),
    hour: Number(m.hour),
    minute: Number(m.minute),
    second: Number(m.second),
  };
}

/** Local civil date key "YYYY-MM-DD" of `instant` in `tz`. */
export function localDateKey(instant: Date, tz: string): string {
  const p = zonedParts(instant, tz);
  return `${p.year}-${pad2(p.month)}-${pad2(p.day)}`;
}

/** "HH:MM" wall clock of `instant` in `tz`. */
export function localTimeKey(instant: Date, tz: string): string {
  const p = zonedParts(instant, tz);
  return `${pad2(p.hour)}:${pad2(p.minute)}`;
}

/** ISO weekday of a civil date key: 1 = Monday … 7 = Sunday. */
export function weekdayIsoOfKey(dateKey: string): number {
  const [y, m, d] = dateKey.split("-").map(Number);
  const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = Sunday
  return dow === 0 ? 7 : dow;
}

/** Offset (minutes, east of UTC) of `instant` in `tz`. */
export function zonedOffsetMinutes(instant: Date, tz: string): number {
  const p = zonedParts(instant, tz);
  const asUtc = Date.UTC(
    p.year,
    p.month - 1,
    p.day,
    p.hour,
    p.minute,
    p.second
  );
  return Math.round((asUtc - instant.getTime()) / 60000);
}

export interface CivilClock {
  hour?: number;
  minute?: number;
  second?: number;
}

/**
 * Build the UTC instant whose wall clock in `tz` equals the given civil
 * date/clock. Double-pass DST correction; on nonexistent local times (spring
 * forward) the result is nudged forward so the round-trip stays sane.
 */
export function civilToInstant(
  dateKey: string,
  tz: string,
  clock: CivilClock = { hour: 0, minute: 0, second: 0 }
): Date {
  const [y, m, d] = dateKey.split("-").map(Number);
  const h = clock.hour ?? 0;
  const min = clock.minute ?? 0;
  const s = clock.second ?? 0;
  // First pass: guess offset at the naive wall time, then correct.
  const naive = Date.UTC(y, m - 1, d, h, min, s);
  const off = zonedOffsetMinutes(new Date(naive), tz);
  let ms = naive - off * 60000;
  // Second pass: handle DST transitions near the wall time. If the offset
  // changed, resolve toward the offset in force at local noon of that date
  // (the most common interpretation for a nonexistent/ambiguous local time).
  const off2 = zonedOffsetMinutes(new Date(ms), tz);
  if (off2 !== off) {
    const noonOff = zonedOffsetMinutes(
      new Date(Date.UTC(y, m - 1, d, 12) - off2 * 60000),
      tz
    );
    ms = naive - noonOff * 60000;
  }
  return new Date(ms);
}

/** Instant at 00:00 local of `dateKey` in `tz`. */
export function localDayStart(dateKey: string, tz: string): Date {
  return civilToInstant(dateKey, tz);
}

/** Minutes since local midnight (0..1439) of `instant` in `tz`. */
export function minutesOfDay(instant: Date, tz: string): number {
  const p = zonedParts(instant, tz);
  return p.hour * 60 + p.minute + p.second / 60;
}

/** Add `delta` civil days to a date key (pure calendar arithmetic). */
export function addDaysToKey(dateKey: string, delta: number): string {
  const [y, m, d] = dateKey.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + delta));
  return `${dt.getUTCFullYear()}-${pad2(dt.getUTCMonth() + 1)}-${pad2(
    dt.getUTCDate()
  )}`;
}

/** Monday of the local week containing `dateKey`. */
export function weekStartKey(dateKey: string): string {
  const wd = weekdayIsoOfKey(dateKey);
  return addDaysToKey(dateKey, 1 - wd);
}

/** Monday-based week index of dateKey within the semester starting firstDay. */
export function academicWeek(dateKey: string, firstDay: string): number {
  const [fy, fm, fd] = firstDay.split("-").map(Number);
  const [y, m, d] = dateKey.split("-").map(Number);
  const diff =
    (Date.UTC(y, m - 1, d) - Date.UTC(fy, fm - 1, fd)) / 86400000;
  return Math.floor(diff / 7) + 1;
}

/** Month start key "YYYY-MM-01" of the month containing dateKey. */
export function monthStartKey(dateKey: string): string {
  return dateKey.slice(0, 8) + "01";
}

/** Last day key of the month containing dateKey. */
export function monthEndKey(dateKey: string): string {
  const [y, m] = dateKey.split("-").map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return `${y}-${pad2(m)}-${pad2(last)}`;
}

/** Human friendly "MMM d" for a local date key (formatted in `tz`). */
export function formatDateKeyShort(dateKey: string, tz: string): string {
  const dt = civilToInstant(dateKey, tz, { hour: 12 });
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    month: "short",
    day: "numeric",
  }).format(dt);
}

/** "HH:MM" of an instant formatted in the user timezone (string in/out safe). */
export function formatLocalClock(instant: Date, tz: string): string {
  return localTimeKey(instant, tz);
}

export function parseInstant(s: string): Date {
  return new Date(s);
}

export function toIsoUtc(d: Date): string {
  return d.toISOString();
}

export function isSameLocalDay(a: Date, b: Date, tz: string): boolean {
  return localDateKey(a, tz) === localDateKey(b, tz);
}

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}
