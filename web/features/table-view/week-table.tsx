"use client";

/**
 * Table (课表) week view: rows = 第几节 (active semester template), columns =
 * Mon..Sun, no time axis / no 凌晨/午休 rows, clear morning/afternoon divider.
 *
 * Interaction (mirrors the timeline week view):
 * - Drag an event to move it (also across days — target column is detected
 *   from the pointer). A merged course keeps its duration.
 * - Resize: the TOP handle snaps the start to class-start times (上课时间),
 *   the BOTTOM handle snaps the end to class-end times (下课时间).
 * - Todo time blocks are clipped to the period rows they touch: fully inside
 *   午休 -> hidden; partial -> lunch portion trimmed.
 */

import * as React from "react";
import { ChevronLeft, ChevronRight, TriangleAlert } from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { useSession } from "@/features/auth/session-store";
import { useServerNow } from "@/features/time/clock";
import { useDateNav, anchorWeekStart } from "@/features/views/date-nav-store";
import { useAllPeriods } from "@/features/calendars/hooks";
import { useRangeEvents } from "@/features/events/hooks";
import { dropCachePrefix } from "@/db/db";
import { updateTodoBlock } from "@/features/todos/api";
import { applySeriesChange } from "@/features/series/api";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  addDaysToKey,
  civilToInstant,
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
/** Split a bar into two when the touched-period gap is ≥ this (午休 etc). */
const SEGMENT_GAP_MIN = 45;
const MIN_DUR_MIN = 15;

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

type DragMode = "move" | "top" | "bottom";

interface DragInfo {
  ev: CalendarEvent;
  mode: DragMode;
  pointerId: number;
  anchorTop: number;
  relStart: number;
  baseStart: number;
  baseEnd: number;
  moved: boolean;
}

interface PreviewPos {
  ev: CalendarEvent;
  dayIdx: number;
  s: number;
  e: number;
}

// ---- pure helpers -----------------------------------------------------------

function clockToMin(c: string): number {
  const [h, m] = c.split(":").map(Number);
  return h * 60 + m;
}
function clockOf(min: number): string {
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

/** minute-of-day at a vertical pixel offset inside the rows body. */
function minuteAtY(y: number, rows: RowDef[]): number {
  if (!rows.length) return 0;
  const idx = clamp(Math.floor(y / ROW_HEIGHT), 0, rows.length - 1);
  const r = rows[idx];
  const frac = clamp((y - idx * ROW_HEIGHT) / ROW_HEIGHT, 0, 1);
  return Math.round(r.startMin + frac * (r.endMin - r.startMin));
}

/** Nearest value in `list` to `v`, clamped into [lo, hi] (0..1440 by default). */
function snapTo(value: number, list: number[], lo = 0, hi = 1440): number {
  if (!list.length) return clamp(value, lo, hi);
  let best = list[0];
  let bestDist = Infinity;
  for (const x of list) {
    const d = Math.abs(x - value);
    if (d < bestDist) {
      bestDist = d;
      best = x;
    }
  }
  return clamp(best, lo, hi);
}

/**
 * Map an event minute range onto the chronological period rows, splitting when
 * the event crosses a long no-period gap (午休/夜间). The lunch-spanning part
 * is simply not drawn. Returns pixel top/bottom per visible segment.
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
  if (!touched.length) return []; // fully inside 午休/凌晨 etc

  const segs: { top: number; bottom: number; rowStart: number; rowEnd: number }[] = [];
  let segStartIdx = touched[0];
  for (let k = 1; k <= touched.length; k++) {
    const prev = touched[k - 1];
    const cur = k < touched.length ? touched[k] : null;
    if (cur !== null && rows[cur].startMin - rows[prev].endMin < SEGMENT_GAP_MIN) {
      continue; // consecutive periods, keep the segment open
    }
    const r1 = rows[segStartIdx];
    const r2 = rows[prev];
    const startFrac =
      s > r1.startMin ? clamp((s - r1.startMin) / (r1.endMin - r1.startMin), 0, 1) : 0;
    const endFrac =
      e < r2.endMin ? clamp((e - r2.startMin) / (r2.endMin - r2.startMin), 0, 1) : 1;
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

function toPlaced(b: Bar): PlacedBar {
  return { ...b, lane: 0, leftPct: 0, widthPct: 100 };
}

function clockInstant(day: LocalDate, minute: number, tz: string): string {
  const h = Math.floor(minute / 60) % 24;
  const m = minute % 60;
  return toIsoUtc(civilToInstant(day, tz, { hour: h, minute: m }));
}

interface DragApi {
  begin: (
    ev: CalendarEvent,
    srcIdx: number,
    mode: DragMode,
    pe: React.PointerEvent<HTMLElement>
  ) => void;
  move: (pe: React.PointerEvent<HTMLElement>) => void;
  end: (pe: React.PointerEvent<HTMLElement>) => void;
  cancel: () => void;
}

// ---- view ------------------------------------------------------------------

export function WeekTableView() {
  const tz = useSession((s) => s.user?.timezone ?? "");
  const now = useServerNow(60_000);
  const dateNav = useDateNav();
  const queryClient = useQueryClient();

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
  const pmIndex = rows.findIndex((r) => r.startMin >= 12 * 60);
  const boundary = pmIndex === -1 ? rows.length : pmIndex;
  const startCandidates = React.useMemo(() => rows.map((r) => r.startMin), [rows]);
  const endCandidates = React.useMemo(() => rows.map((r) => r.endMin), [rows]);

  // Bars per day from the event projection.
  const byDay = React.useMemo(() => {
    const map = new Map<LocalDate, Bar[]>();
    if (!eventsQuery.data || !rows.length) return map;
    for (const ev of eventsQuery.data) {
      if (ev.type === "deadline") continue;
      const key = eventDayKey(ev, tz);
      if (!days.includes(key)) continue;
      const s = eventStartMinutes(ev, tz);
      const e = s + Math.max(eventDurationMinutes(ev), 1);
      for (const seg of splitToRowSegments(s, e, rows)) {
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

  // ---- drag & drop state ----------------------------------------------------

  const colEls = React.useRef<(HTMLDivElement | null)[]>([]);
  const dragRef = React.useRef<DragInfo | null>(null);
  const [dragId, setDragId] = React.useState<string | null>(null);
  const [preview, setPreview] = React.useState<PreviewPos | null>(null);

  function beginDrag(
    ev: CalendarEvent,
    srcIdx: number,
    mode: DragMode,
    pe: React.PointerEvent<HTMLElement>
  ) {
    if (ev.type === "deadline") return;
    pe.preventDefault();
    pe.stopPropagation();
    (pe.currentTarget as HTMLElement).setPointerCapture(pe.pointerId);
    const el = colEls.current[srcIdx];
    const anchorTop = el ? el.getBoundingClientRect().top : 0;
    const baseStart = Math.min(eventStartMinutes(ev, tz), 1439);
    const baseEnd =
      ev.endAt == null
        ? baseStart
        : Math.min(baseStart + Math.max(eventDurationMinutes(ev), 1), 1440);
    dragRef.current = {
      ev,
      mode,
      pointerId: pe.pointerId,
      anchorTop,
      relStart: pe.clientY - anchorTop,
      baseStart,
      baseEnd,
      moved: false,
    };
    // NOTE: do NOT hide the source element here. Unmounting it releases the
    // pointer capture and the pointerup handler never runs — a plain click
    // would leave the block invisible forever.
  }

  /** Column index under clientX (uses live column rects). */
  function columnAtX(clientX: number): number {
    for (let i = 0; i < 7; i++) {
      const el = colEls.current[i];
      if (!el) continue;
      const r = el.getBoundingClientRect();
      if (clientX >= r.left && clientX < r.right) return i;
    }
    // Fallback: nearest by center distance.
    let best = 0;
    let bestDist = Infinity;
    for (let i = 0; i < 7; i++) {
      const el = colEls.current[i];
      if (!el) continue;
      const cx = el.getBoundingClientRect().left + el.offsetWidth / 2;
      const d = Math.abs(clientX - cx);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }

  function moveDrag(pe: React.PointerEvent<HTMLElement>) {
    const d = dragRef.current;
    if (!d || d.pointerId !== pe.pointerId) return;
    const relY = pe.clientY - d.anchorTop;
    d.moved = d.moved || Math.abs(relY - d.relStart) > 3;
    if (!d.moved) return;
    setDragId(d.ev.id); // drag really started: hide source via opacity below
    const delta = minuteAtY(relY, rows) - minuteAtY(d.relStart, rows);
    const dayIdx = columnAtX(pe.clientX);
    const dur = d.baseEnd - d.baseStart;
    let s = d.baseStart;
    let e = d.baseEnd;
    if (d.mode === "move") {
      // Whole-block move: keep duration, snap start to a class start time.
      s = snapTo(d.baseStart + delta, startCandidates, 0, 1440 - dur);
      e = s + dur;
    } else if (d.mode === "top") {
      // Top handle: snap the start to 上课时间 (period start).
      s = snapTo(d.baseStart + delta, startCandidates, 0, d.baseEnd - MIN_DUR_MIN);
      e = d.baseEnd;
    } else {
      // Bottom handle: snap the end to 下课时间 (period end).
      e = snapTo(d.baseEnd + delta, endCandidates, d.baseStart + MIN_DUR_MIN, 1440);
      s = d.baseStart;
    }
    setPreview({ ev: d.ev, dayIdx, s, e });
  }

  function endDrag(pe: React.PointerEvent<HTMLElement>) {
    const d = dragRef.current;
    if (!d || d.pointerId !== pe.pointerId) return;
    const moved = d.moved;
    const p = preview;
    dragRef.current = null;
    setDragId(null);
    setPreview(null);
    if (moved && p && (p.s !== d.baseStart || p.e !== d.baseEnd)) {
      void commitDrag(d.ev, days[p.dayIdx], p.s, p.e);
    }
  }

  function cancelDrag() {
    dragRef.current = null;
    setDragId(null);
    setPreview(null);
  }

  async function commitDrag(ev: CalendarEvent, dayKey: LocalDate, s: number, e: number) {
    const startAt = clockInstant(dayKey, s, tz);
    const endAt = clockInstant(dayKey, e, tz);
    try {
      if (ev.source.type === "todo_block") {
        await updateTodoBlock(ev.source.id, { startAt, endAt });
        toast.success("Block moved");
      } else {
        const seriesType =
          ev.source.type === "course_meeting" ? "course_meeting" : "recurring_schedule";
        await applySeriesChange(seriesType, ev.source.id, {
          scope: "THIS",
          occurrenceDateLocal: dayKey,
          operation: { type: "MOVE", startAt, endAt },
        });
        toast.success("Occurrence moved");
      }
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Move failed");
    }
    await invalidateEvents();
  }

  async function invalidateEvents() {
    await dropCachePrefix("/calendar/events");
    await queryClient.invalidateQueries({ queryKey: ["events"] });
  }

  const isLoading = eventsQuery.isLoading || eventsQuery.isPending;
  const totalH = rows.length * ROW_HEIGHT;
  const year = Number(weekStart.slice(0, 4));

  function go(delta: number) {
    dateNav.shiftDays(delta, tz);
  }

  // bars used for preview while dragging (drop ghost in target column)
  function previewBarsFor(dayIdx: number): PlacedBar[] {
    if (!preview || preview.dayIdx !== dayIdx) return [];
    return splitToRowSegments(preview.s, preview.e, rows).map((seg, k) => ({
      id: `preview-${preview.ev.id}-${k}`,
      ev: preview.ev,
      topPx: seg.top,
      bottomPx: seg.bottom,
      rowStart: seg.rowStart,
      rowEnd: seg.rowEnd,
      lane: 0,
      leftPct: 0,
      widthPct: 100,
    }));
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
        <span className="hidden text-[11px] text-muted-foreground sm:inline">
          Drag to move (cross-day ok) · ⇕ resize snaps to 上课/下课时间
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
                  idx={di}
                  weekend={di >= 5}
                  rows={rows}
                  boundary={boundary}
                  colRef={(el) => {
                    colEls.current[di] = el;
                  }}
                  bars={(byDay.get(d) ?? []).map(toPlaced)}
                  previewBars={previewBarsFor(di)}
                  dragActiveId={dragId}
                  dragApi={{
                    begin: beginDrag,
                    move: moveDrag,
                    end: endDrag,
                    cancel: cancelDrag,
                  }}
                />
              ))}
            </div>

            {/* Morning / afternoon divider line + pill */}
            {boundary > 0 && boundary < rows.length && (
              <div
                className="pointer-events-none absolute z-20"
                style={{
                  left: GUTTER,
                  right: 0,
                  top: boundary * ROW_HEIGHT,
                  height: 0,
                  borderTop:
                    "2px solid color-mix(in srgb, var(--foreground) 55%, transparent)",
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

// ---- day column ---------------------------------------------------------------

function DayGridColumn({
  idx,
  weekend,
  rows,
  boundary,
  colRef,
  bars,
  previewBars,
  dragActiveId,
  dragApi,
}: {
  idx: number;
  weekend: boolean;
  rows: RowDef[];
  boundary: number;
  colRef: (el: HTMLDivElement | null) => void;
  bars: PlacedBar[];
  previewBars: PlacedBar[];
  dragActiveId: string | null;
  dragApi: DragApi;
}) {
  const totalH = rows.length * ROW_HEIGHT;
  const intervals = bars.map((b) => ({ start: b.topPx, end: b.bottomPx }));
  const placed = layoutColumns(intervals);
  const items = bars.map((b, i) => ({ ...b, ...placed[i] }));

  return (
    <div
      ref={colRef}
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

      {/* drop ghost while dragging */}
      {previewBars.map((pb) => (
        <div
          key={pb.id}
          className="pointer-events-none absolute z-40 rounded border-2 border-dashed opacity-60"
          style={{
            top: pb.topPx,
            height: Math.max(pb.bottomPx - pb.topPx, 4),
            left: "1%",
            width: "98%",
            borderColor: "var(--primary)",
            background: "color-mix(in srgb, var(--primary) 12%, transparent)",
          }}
        />
      ))}

      {/* event bars (source bar stays mounted during drag: hidden via opacity) */}
      {items.map((it) => (
        <TableCell
          key={it.id}
          bar={it}
          colIdx={idx}
          hiddenDuringDrag={dragActiveId === it.ev.id}
          dragApi={dragApi}
        />
      ))}
    </div>
  );
}

function TableCell({
  bar,
  colIdx,
  hiddenDuringDrag,
  dragApi,
}: {
  bar: PlacedBar;
  colIdx: number;
  hiddenDuringDrag: boolean;
  dragApi: DragApi;
}) {
  const { ev } = bar;
  const isBlock = ev.type === "todo_block";
  const style = paletteFor(ev);
  const top = bar.topPx;
  const height = Math.max(bar.bottomPx - top, 6);
  const periodLabel =
    ev.type === "course" && typeof ev.metadata?.periodStart === "number"
      ? ev.metadata.periodStart === ev.metadata?.periodEnd
        ? `第${ev.metadata.periodStart}节`
        : `第${ev.metadata.periodStart}–${ev.metadata.periodEnd}节`
      : null;
  const loc =
    ev.type === "course"
      ? [ev.metadata?.location, ev.metadata?.teacher].filter(Boolean).join(" · ")
      : null;
  const note: string | null =
    ev.type === "todo_block" && typeof ev.metadata?.blockNote === "string"
      ? ev.metadata.blockNote
      : null;

  return (
    <div
      className={cn(
        "group absolute z-10 cursor-grab touch-none select-none overflow-hidden rounded border shadow-sm active:cursor-grabbing",
        isBlock ? "z-20" : "z-10",
        conflictTextureClass(ev.conflictState),
        hiddenDuringDrag && "pointer-events-none opacity-0"
      )}
      style={{
        top,
        height,
        left: `${bar.leftPct + (bar.widthPct < 100 ? 0.5 : 0)}%`,
        width: `${bar.widthPct < 100 ? bar.widthPct - 0.5 : 100}%`,
        background: isBlock
          ? "color-mix(in srgb, var(--cp-todo) 16%, transparent)"
          : style.bg,
        borderColor: style.border,
        color: style.text,
      }}
      title={`${ev.title}${periodLabel ? " " + periodLabel : ""}`}
      onPointerDown={(e) => {
        if (ev.type !== "deadline") dragApi.begin(ev, colIdx, "move", e);
      }}
      onPointerMove={(e) => dragApi.move(e)}
      onPointerUp={(e) => dragApi.end(e)}
      onPointerCancel={() => dragApi.cancel()}
    >
      <div className="flex min-w-0 items-center gap-1 px-1 py-0.5">
        {ev.conflictState !== "none" && (
          <TriangleAlert
            className="h-3 w-3 shrink-0"
            style={{ color: "var(--cp-hard-conflict)" }}
          />
        )}
        <span className="truncate text-[11px] font-semibold leading-tight">{ev.title}</span>
      </div>
      {(periodLabel || loc || note) && (
        <div className="truncate px-1 text-[10px] leading-tight text-muted-foreground">
          <span
            className="font-medium"
            style={{ color: isBlock ? "var(--cp-todo)" : style.accent }}
          >
            {periodLabel}
          </span>
          {loc || note ? ` · ${loc || note}` : ""}
        </div>
      )}

      {/* resize handles: top snaps to 上课时间, bottom snaps to 下课时间 */}
      {ev.type !== "deadline" && (
        <>
          <span
            className="absolute inset-x-0 top-0 z-30 h-2 cursor-n-resize"
            onPointerDown={(e) => {
              e.stopPropagation();
              dragApi.begin(ev, colIdx, "top", e);
            }}
          />
          <span
            className="absolute inset-x-0 bottom-0 z-30 h-2 cursor-s-resize"
            onPointerDown={(e) => {
              e.stopPropagation();
              dragApi.begin(ev, colIdx, "bottom", e);
            }}
          />
        </>
      )}
    </div>
  );
}
