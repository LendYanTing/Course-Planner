"use client";

/**
 * Table (课表) week view: rows = 第几节 (from the active semester template),
 * columns = Mon..Sun. No time axis, no 凌晨/午休 rows — just the class grid
 * with a clear morning/afternoon divider. Todo time blocks are clipped to the
 * period rows they overlap: a block fully inside 午休 disappears, a partially
 * overlapping one is cut at the break edges.
 */

import * as React from "react";
import { ChevronLeft, ChevronRight, TriangleAlert } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { useSession } from "@/features/auth/session-store";
import { useServerNow } from "@/features/time/clock";
import { useDateNav, anchorWeekStart } from "@/features/views/date-nav-store";
import { useAllPeriods } from "@/features/calendars/hooks";
import { useRangeEvents } from "@/features/events/hooks";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  addDaysToKey,
  localDateKey,
  localDayStart,
  toIsoUtc,
  formatDateKeyShort,
} from "@/lib/time/tz";
import { eventDayKey, eventDurationMinutes, eventStartMinutes } from "@/lib/event-model";
import { layoutColumns } from "@/lib/overlap-layout";
import { conflictTextureClass, paletteFor } from "@/lib/event-style";

const DAY_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const ROW_HEIGHT = 54;
const GUTTER = 64;
/** split segments when the gap between two touched periods is ≥ this (lunch) */
const SEGMENT_GAP_MIN = 45;

interface RowDef {
  no: number;
  startMin: number;
  endMin: number;
}

/** One visual cell bar clipped to the period rows. */
interface Bar {
  id: string;
  ev: CalendarEvent;
  topPx: number;
  bottomPx: number;
  rowStart: number;
  rowEnd: number;
}

interface PlacedBar extends Bar {
  lane: number;
  leftPct: number;
  widthPct: number;
}

export function WeekTableView() {
  const tz = useSession((s) => s.user?.timezone ?? "");
  const now = useServerNow(60_000);
  const dateNav = useDateNav();

  React.useEffect(() => {
    if (tz) dateNav.ensure(tz);
  }, [tz, dateNav]);

  const anchor = dateNav.date ?? (tz ? localDateKey(now, tz) : "");
  const weekStart = anchorWeekStart(anchor, tz);
  const todayKey = tz ? localDateKey(now, tz) : "";

  const days = React.useMemo(
    () => Array.from({ length: 7 }, (_, i) => addDaysToKey(weekStart, i)),
    [weekStart]
  );
  const range = React.useMemo(() => {
    if (!tz || !days.length) return null;
    return {
      start: toIsoUtc(localDayStart(days[0], tz)),
      end: toIsoUtc(localDayStart(addDaysToKey(days[0], 7), tz)),
    };
  }, [days, tz]);

  const eventsQuery = useRangeEvents(range, !!tz);
  const calendarsQuery = useAllPeriods();

  // Chronological rows from the period template (dedup duplicate starts).
  const rows: RowDef[] = React.useMemo(() => {
    const flat: RowDef[] = [];
    for (const g of calendarsQuery.data ?? []) {
      for (const p of g.periods) {
        flat.push({ no: p.periodNo, startMin: clockToMin(p.startLocal), endMin: clockToMin(p.endLocal) });
      }
    }
    flat.sort((a, b) => a.startMin - b.startMin || a.no - b.no);
    const seen = new Set<number>();
    const out: RowDef[] = [];
    for (const r of flat) {
      if (!seen.has(r.startMin)) {
        seen.add(r.startMin);
        out.push(r);
      }
    }
    return out;
  }, [calendarsQuery.data]);
  // Split morning (start < 12:00) vs afternoon.
  const pmIndex = rows.findIndex((r) => r.startMin >= 12 * 60);
  const boundary = pmIndex === -1 ? rows.length : pmIndex;

  // Visual bars per day: (event, rowTop/rowBottom px segment).
  const byDay = React.useMemo(() => {
    const map = new Map<LocalDate, Bar[]>();
    if (!eventsQuery.data || !rows.length) return map;
    for (const ev of eventsQuery.data) {
      if (ev.type === "deadline") continue; // deadlines have no duration cell
      const key = eventDayKey(ev, tz);
      if (!days.includes(key)) continue;
      const s = eventStartMinutes(ev, tz);
      const dur = Math.max(eventDurationMinutes(ev), 1);
      const e = s + dur;
      const segments = splitToRowSegments(s, e, rows);
      for (const seg of segments) {
        const list = map.get(key) ?? [];
        list.push({
          id: `${ev.id}-${seg.rowStart}-${seg.rowEnd}`,
          ev,
          topPx: seg.top,
          bottomPx: seg.bottom,
          rowStart: seg.rowStart,
          rowEnd: seg.rowEnd,
        });
        map.set(key, list);
      }
    }
    for (const list of map.values()) {
      list.sort((a, b) => a.topPx - b.topPx || a.rowStart - b.rowStart);
    }
    return map;
  }, [eventsQuery.data, rows, days, tz]);

  const isLoading = eventsQuery.isLoading || eventsQuery.isPending;
  const totalH = rows.length * ROW_HEIGHT;
  const year = Number(weekStart.slice(0, 4));

  function go(delta: number) {
    dateNav.shiftDays(delta, tz);
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Toolbar */}
      <div className="flex h-12 shrink-0 items-center gap-2 border-b px-3">
        <Button variant="outline" size="icon" onClick={() => go(-7)} aria-label="Previous week">
          <ChevronLeft />
        </Button>
        <Button variant="outline" size="icon" onClick={() => go(7)} aria-label="Next week">
          <ChevronRight />
        </Button>
        <Button variant="secondary" size="sm" onClick={() => dateNav.goToday(tz)}>
          Today
        </Button>
        <span className="ml-1 text-sm font-medium">
          {formatDateKeyShort(days[0], tz)} – {formatDateKeyShort(days[6], tz)} · {year}
        </span>
        <div className="flex-1" />
        <span className="text-[11px] text-muted-foreground">
          {rows.length ? `第1–${rows[rows.length - 1].no}节` : ""}
        </span>
      </div>

      {/* Column headers */}
      <div
        className="flex h-10 shrink-0 items-stretch border-b bg-background"
        style={{ paddingLeft: GUTTER }}
      >
        {days.map((d, i) => {
          const isToday = d === todayKey;
          const weekend = i >= 5;
          return (
            <div
              key={d}
              className={cn(
                "flex flex-1 items-center justify-center gap-1.5 border-l text-xs",
                weekend && "text-muted-foreground"
              )}
            >
              <span className="hidden md:inline">{DAY_LABELS[i]}</span>
              <span
                className={cn(
                  "flex h-6 w-6 items-center justify-center rounded-full text-sm",
                  isToday && "bg-primary font-semibold text-primary-foreground"
                )}
              >
                {Number(d.slice(8, 10))}
              </span>
              <span className="hidden text-[10px] text-muted-foreground lg:inline">
                {formatDateKeyShort(d, "UTC").split(" ")[0]}
              </span>
            </div>
          );
        })}
      </div>

      {isLoading && !eventsQuery.data ? (
        <div className="flex flex-1 items-center justify-center text-sm text-muted-foreground">
          Loading…
        </div>
      ) : (
        <div className="min-h-0 flex-1 overflow-auto">
          <div className="relative" style={{ minWidth: 760 }}>
            {/* grid columns: gutter + 7 day columns */}
            <div
              className="relative"
              style={{
                display: "grid",
                gridTemplateColumns: `${GUTTER}px repeat(7, minmax(0, 1fr))`,
              }}
            >
              {/* Left period number column */}
              <div className="relative border-r" style={{ height: totalH }}>
                {rows.map((r, i) => {
                  const morning = i < boundary;
                  return (
                    <div
                      key={`${r.no}-${i}`}
                      className="absolute inset-x-0 flex items-center justify-center"
                      style={{
                        top: i * ROW_HEIGHT,
                        height: ROW_HEIGHT,
                        background: morning
                          ? "color-mix(in srgb, var(--cp-course) 4%, transparent)"
                          : "color-mix(in srgb, var(--cp-now) 4%, transparent)",
                      }}
                    >
                      <div className="flex flex-col items-center leading-none">
                        <span
                          className="text-base font-bold"
                          style={{
                            color: morning
                              ? "color-mix(in srgb, var(--cp-course) 88%, var(--foreground))"
                              : "color-mix(in srgb, var(--cp-now) 82%, var(--foreground))",
                          }}
                        >
                          {r.no}
                        </span>
                        <span className="mt-0.5 text-[8px] text-muted-foreground">
                          {clockOf(r.startMin)}
                        </span>
                      </div>
                    </div>
                  );
                })}
              </div>

              {/* Day columns */}
              {days.map((d, di) => (
                <DayGridColumn
                  key={d}
                  weekend={di >= 5}
                  rows={rows}
                  boundary={boundary}
                  bars={(byDay.get(d) ?? []).map((b) => ({
                    ...b,
                    lane: 0,
                    leftPct: 0,
                    widthPct: 100,
                  }))}
                />
              ))}
            </div>

            {/* Morning / afternoon divider line + pill across the whole body */}
            {boundary > 0 && boundary < rows.length && (
              <div
                className="pointer-events-none absolute inset-y-0 z-20"
                style={{
                  left: GUTTER,
                  right: 0,
                  top: boundary * ROW_HEIGHT,
                  height: 0,
                  borderTop: "2px solid color-mix(in srgb, var(--foreground) 55%, transparent)",
                }}
              >
                <span
                  className="absolute -translate-y-1/2 rounded-full border bg-background px-2 py-px text-[9px] font-semibold uppercase tracking-wider text-muted-foreground"
                  style={{ left: "30%", whiteSpace: "nowrap" }}
                >
                  上午 AM · 下午 PM
                </span>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function DayGridColumn({
  weekend,
  rows,
  boundary,
  bars,
}: {
  weekend: boolean;
  rows: RowDef[];
  boundary: number;
  bars: PlacedBar[];
}) {
  const totalH = rows.length * ROW_HEIGHT;
  const intervals = bars.map((b) => ({ start: b.topPx, end: b.bottomPx }));
  const placed = layoutColumns(intervals);
  const items = bars.map((b, i) => ({ ...b, ...placed[i] }));

  return (
    <div
      className={cn("relative border-l", weekend && "bg-weekend/50")}
      style={{ height: totalH }}
    >
      {/* row separators + morning/afternoon tints */}
      {rows.map((r, i) => {
        const morning = i < boundary;
        return (
          <div
            key={`${r.no}-${i}`}
            className="absolute inset-x-0 border-b"
            style={{
              top: i * ROW_HEIGHT,
              height: ROW_HEIGHT,
              background: morning
                ? "color-mix(in srgb, var(--cp-course) 3%, transparent)"
                : "color-mix(in srgb, var(--cp-now) 3.5%, transparent)",
              borderColor: "color-mix(in srgb, var(--border) 75%, transparent)",
            }}
          />
        );
      })}
      {/* event bars */}
      {items.map((it) => (
        <TableCell key={it.id} bar={it} />
      ))}
    </div>
  );
}

function TableCell({ bar }: { bar: PlacedBar }) {
  const { ev } = bar;
  const isBlock = ev.type === "todo_block";
  const style = paletteFor(ev);
  const top = bar.topPx;
  const height = Math.max(bar.bottomPx - top, 4);
  const periodLabel =
    ev.type === "course" && typeof ev.metadata?.periodStart === "number"
      ? ev.metadata.periodStart === ev.metadata?.periodEnd
        ? `第${ev.metadata.periodStart}节`
        : `第${ev.metadata.periodStart}–${ev.metadata.periodEnd}节`
      : null;
  const loc = ev.type === "course" ? [ev.metadata?.location, ev.metadata?.teacher].filter(Boolean).join(" · ") : null;
  const note: string | null =
    ev.type === "todo_block" && typeof ev.metadata?.blockNote === "string"
      ? ev.metadata.blockNote
      : null;

  return (
    <div
      className={cn(
        "absolute z-10 overflow-hidden rounded border shadow-sm",
        isBlock ? "z-20" : "z-10",
        conflictTextureClass(ev.conflictState),
        bar.rowStart === bar.rowEnd ? "" : "my-[-1px]"
      )}
      style={{
        top,
        height,
        left: `${(bar.leftPct + (bar.widthPct < 100 ? 1 : 0))}%`,
        width: `${bar.widthPct < 100 ? bar.widthPct - 1 : 100}%`,
        background: isBlock ? "color-mix(in srgb, var(--cp-todo) 16%, transparent)" : style.bg,
        borderColor: style.border,
        color: style.text,
      }}
      title={`${ev.title}${periodLabel ? " " + periodLabel : ""}`}
    >
      <div className="flex min-w-0 items-center gap-1 px-1 py-0.5">
        {ev.conflictState !== "none" && (
          <TriangleAlert className="h-3 w-3 shrink-0" style={{ color: "var(--cp-hard-conflict)" }} />
        )}
        <span className="truncate text-[11px] font-semibold leading-tight">{ev.title}</span>
      </div>
      {(periodLabel || loc || note) && (
        <div className="truncate px-1 text-[10px] leading-tight text-muted-foreground">
          <span className="font-medium" style={{ color: isBlock ? "var(--cp-todo)" : style.accent }}>
            {periodLabel}
          </span>
          {loc || note ? ` · ${loc || note}` : ""}
        </div>
      )}
    </div>
  );
}

// ---- helpers -------------------------------------------------------------

function clockToMin(c: string): number {
  const [h, m] = c.split(":").map(Number);
  return h * 60 + m;
}
function clockOf(min: number): string {
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/**
 * Map an event minute range onto the chronological period rows, splitting when
 * the event crosses a long no-period gap (午休/夜间) so that segment is not
 * drawn at all. Returns pixel top/bottom per visible segment.
 */
function splitToRowSegments(
  s: number,
  e: number,
  rows: RowDef[]
): { top: number; bottom: number; rowStart: number; rowEnd: number }[] {
  if (e <= s || !rows.length) return [];
  const touched: number[] = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (r.endMin <= s || r.startMin >= e) continue;
    touched.push(i);
  }
  if (!touched.length) return []; // fully inside 午休/凌晨/夜间 etc
  const segs: { top: number; bottom: number; rowStart: number; rowEnd: number }[] = [];
  let segStartIdx = touched[0];
  for (let k = 1; k <= touched.length; k++) {
    const prev = touched[k - 1];
    const cur = k < touched.length ? touched[k] : null;
    const gapMin =
      cur !== null ? rows[cur].startMin - rows[prev].endMin : 0;
    if (cur !== null && gapMin < SEGMENT_GAP_MIN) continue; // keep segment open
    // close segment [segStartIdx .. prev]
    const r1 = rows[segStartIdx];
    const r2 = rows[prev];
    const startFrac =
      s > r1.startMin ? Math.min((s - r1.startMin) / (r1.endMin - r1.startMin), 1) : 0;
    const endFrac =
      e < r2.endMin ? Math.max((e - r2.startMin) / (r2.endMin - r2.startMin), 0) : 1;
    segs.push({
      top: (segStartIdx + startFrac) * ROW_HEIGHT,
      bottom: (prev + endFrac) * ROW_HEIGHT,
      rowStart: segStartIdx,
      rowEnd: prev,
    });
    if (cur !== null) segStartIdx = cur;
  }
  return segs;
}
