"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { useSession } from "@/features/auth/session-store";
import { useServerNow } from "@/features/time/clock";
import { useDateNav, anchorWeekStart } from "@/features/views/date-nav-store";
import { useAllPeriods } from "@/features/calendars/hooks";
import { useRangeEvents } from "@/features/events/hooks";
import { listTodos } from "@/features/todos/api";
import { updateTodoBlock } from "@/features/todos/api";
import { applySeriesChange } from "@/features/series/api";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey, dropCachePrefix } from "@/db/db";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  addDaysToKey,
  localDateKey,
  localDayStart,
  minutesOfDay,
  toIsoUtc,
  formatDateKeyShort,
} from "@/lib/time/tz";
import { eventDayKey, eventDurationMinutes, eventStartMinutes } from "@/lib/event-model";
import { layoutColumns } from "@/lib/overlap-layout";
import { DAY_MINUTES, snapMinute, type SnapMode } from "@/features/week-view/geometry";
import {
  buildScale,
  proposeFoldBands,
  clipToVisible,
  FOLD_HEIGHT_PX,
  type DayScale,
} from "@/features/week-view/fold";
import { WeekToolbar } from "@/features/week-view/week-toolbar";
import { WeekDayHeader, GUTTER_WIDTH } from "@/features/week-view/day-header";
import { EventNode } from "@/features/week-view/event-node";
import {
  BlockEditorDialog,
  OccurrenceTimeDialog,
  OccurrenceDeleteDialog,
  EventDetailsDialog,
  instantFor,
} from "@/features/week-view/dialogs";
import type { Todo } from "@/generated/entities";

type DialogState =
  | { kind: "none" }
  | { kind: "details"; event: CalendarEvent }
  | { kind: "editBlock"; event: CalendarEvent }
  | { kind: "time"; event: CalendarEvent }
  | { kind: "delete"; event: CalendarEvent };

interface DayBundle {
  day: LocalDate;
  /** partitioned course/recurring events */
  lanes: { event: CalendarEvent; leftPct: number; widthPct: number }[];
  todos: CalendarEvent[];
  deadlines: CalendarEvent[];
}

/** minutes-of-day helpers */
function minFromClock(clock: string): number {
  const [h, m] = clock.split(":").map(Number);
  return h * 60 + m;
}
function clockFromMin(minutes: number): string {
  const h = Math.floor(minutes / 60) % 24;
  const m = Math.round(minutes % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export function WeekView() {
  const tz = useSession((s) => s.user?.timezone ?? "");
  const now = useServerNow(60_000);
  const dateNav = useDateNav();

  React.useEffect(() => {
    if (tz) dateNav.ensure(tz);
  }, [tz, dateNav]);

  const anchor = dateNav.date ?? (tz ? localDateKey(now, tz) : "");
  const weekStart = anchor ? anchorWeekStart(anchor, tz) : "";
  const todayKey = tz ? localDateKey(now, tz) : "";

  const days = React.useMemo(() => {
    return Array.from({ length: 7 }, (_, i) => addDaysToKey(weekStart, i));
  }, [weekStart]);

  const range = React.useMemo(() => {
    if (!tz || !days.length) return null;
    return {
      start: toIsoUtc(localDayStart(days[0], tz)),
      end: toIsoUtc(localDayStart(addDaysToKey(days[0], 7), tz)),
    };
  }, [days, tz]);

  const eventsQuery = useRangeEvents(range, !!tz);
  const calendarsQuery = useAllPeriods();

  // Period template of every calendar: {no, start, end} minute-of-day.
  // If a template contains duplicated start times (dirty data), keep the first
  // (smallest periodNo) so labels/lines stay unambiguous.
  const periodSlots = React.useMemo(() => {
    const flat: { no: number; start: number; end: number }[] = [];
    for (const g of calendarsQuery.data ?? []) {
      for (const p of g.periods) {
        flat.push({
          no: p.periodNo,
          start: minFromClock(p.startLocal),
          end: minFromClock(p.endLocal),
        });
      }
    }
    flat.sort((a, b) => a.start - b.start || a.no - b.no);
    const merged = new Map<number, { no: number; start: number; end: number }>();
    for (const p of flat) {
      if (!merged.has(p.start)) merged.set(p.start, p);
    }
    return [...merged.values()].sort((a, b) => a.start - b.start || a.no - b.no);
  }, [calendarsQuery.data]);
  const boundaries = React.useMemo(
    () =>
      [...new Set(periodSlots.flatMap((p) => [p.start, p.end]))].sort(
        (a, b) => a - b
      ),
    [periodSlots]
  );

  const [snap, setSnap] = React.useState<SnapMode>("period");
  // Folding (docs/ui-interaction.md §3): auto folds empty 凌晨/午休/夜间 spans.
  const [foldMode, setFoldMode] = React.useState<"auto" | "none">("auto");
  const [removedFolds, setRemovedFolds] = React.useState<string[]>([]);
  const [dialog, setDialog] = React.useState<DialogState>({ kind: "none" });
  const [newBlockSlot, setNewBlockSlot] = React.useState<{
    day: LocalDate;
    start: number;
    end: number;
  } | null>(null);
  const queryClient = useQueryClient();

  const nowMin = tz ? minutesOfDay(now, tz) : 0;

  const events = eventsQuery.data ?? [];

  // Which fold bands apply this week. 课间 gaps fold even inside merged
  // classes (they are real breaks) unless a todo block/deadline is scheduled
  // there; long bands (凌晨/午休/夜间) need the week empty.
  const foldBands = React.useMemo(() => {
    if (foldMode === "none" || !events.length || !periodSlots.length) return [];
    const occupied = events.map((ev) => {
      const s = eventStartMinutes(ev, tz);
      const dur = Math.max(eventDurationMinutes(ev), 1);
      return { from: s, to: Math.min(DAY_MINUTES, s + dur) };
    });
    const gapForbidden = events
      .filter(
        (ev) => ev.type === "todo_block" || ev.type === "deadline"
      )
      .map((ev) => {
        const s = eventStartMinutes(ev, tz);
        const dur = Math.max(eventDurationMinutes(ev), 1);
        return { from: s, to: Math.min(DAY_MINUTES, s + dur) };
      });
    const bands = proposeFoldBands({
      periodStarts: periodSlots,
      occupied,
      gapForbidden,
      nowMin,
    });
    return bands.filter((b) => !removedFolds.includes(b.id));
  }, [foldMode, events, periodSlots, removedFolds, nowMin, tz]);

  const scale = React.useMemo(() => buildScale(foldBands), [foldBands]);

  // Group events per day.
  const bundles = React.useMemo(() => {
    const byDay = new Map<LocalDate, DayBundle>();
    for (const day of days) {
      byDay.set(day, { day, lanes: [], todos: [], deadlines: [] });
    }
    for (const ev of events) {
      const key = eventDayKey(ev, tz);
      const bundle = byDay.get(key);
      if (!bundle) continue;
      if (ev.type === "deadline") bundle.deadlines.push(ev);
      else if (ev.type === "todo_block") bundle.todos.push(ev);
      else bundle.lanes.push({ event: ev, leftPct: 0, widthPct: 100 });
    }
    const out: DayBundle[] = [];
    for (const day of days) {
      const b = byDay.get(day)!;
      const items = b.lanes.map((l) => {
        const s = eventStartMinutes(l.event, tz);
        return { start: s, end: s + Math.max(eventDurationMinutes(l.event), 1) };
      });
      const placed = layoutColumns(items);
      b.lanes = b.lanes.map((l, i) => ({
        ...l,
        leftPct: placed[i].leftPct,
        widthPct: placed[i].widthPct,
      }));
      b.todos.sort((a, b) => eventStartMinutes(a, tz) - eventStartMinutes(b, tz));
      out.push(b);
    }
    return out;
  }, [events, days, tz]);

  async function invalidateEventsAfterWrite() {
    await dropCachePrefix("/calendar/events");
    await queryClient.invalidateQueries({ queryKey: ["events"] });
  }

  function handleMoveCommit(
    event: CalendarEvent,
    dayKey: LocalDate,
    startMinutes: number,
    endMinutes: number
  ) {
    const startAt = instantFor(dayKey, clockFromMin(startMinutes), tz);
    const endAt = instantFor(dayKey, clockFromMin(endMinutes), tz);
    moveEventMutation(event, startAt, endAt, dayKey)
      .then(async () => {
        await invalidateEventsAfterWrite();
        toast.success(
          event.source.type === "todo_block"
            ? "Block moved"
            : "Occurrence moved (this date)"
        );
      })
      .catch((err) => {
        toast.error(err instanceof Error ? err.message : "Move failed");
        void invalidateEventsAfterWrite();
      });
  }

  if (!tz) return <div className="p-4 text-sm text-muted-foreground">Loading timezone…</div>;

  const isLoading = eventsQuery.isLoading || eventsQuery.isPending;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <WeekToolbar
        rangeLabel={`${formatDateKeyShort(days[0], tz)} – ${formatDateKeyShort(days[6], tz)}`}
        onToday={() => dateNav.goToday(tz)}
        onPrev={() => dateNav.shiftDays(-7, tz)}
        onNext={() => dateNav.shiftDays(7, tz)}
        snap={snap}
        onSnapChange={setSnap}
        foldMode={foldMode}
        onFoldChange={(v) => {
          setFoldMode(v);
          setRemovedFolds([]);
        }}
        onNewBlock={() => {
          const start = snapMinute(nowMin + 60, snap, boundaries);
          setNewBlockSlot({
            day: todayKey,
            start,
            end: Math.min(start + 60, DAY_MINUTES),
          });
        }}
      />
      <WeekDayHeader days={days} todayKey={todayKey} />

      {/* Active fold chips */}
      {(scale.bands.length > 0 || removedFolds.length > 0) && (
        <div className="flex shrink-0 flex-wrap items-center gap-1.5 border-b bg-muted/20 px-3 py-1">
          <span className="text-[10px] uppercase tracking-wide text-muted-foreground">
            折叠
          </span>
          {scale.bands
            .filter((b) => !b.id.startsWith("gap-"))
            .map((b) => (
              <button
                key={b.id}
                type="button"
                onClick={() => setRemovedFolds((cur) => [...cur, b.id])}
                className="rounded-full border border-dashed px-2 py-0.5 text-[11px] text-muted-foreground hover:bg-accent"
                title="Click to expand this segment"
              >
                {b.label}
              </button>
            ))}
          {scale.bands.filter((b) => b.id.startsWith("gap-")).length > 0 && (
            <button
              type="button"
              onClick={() =>
                setRemovedFolds((cur) => [
                  ...cur,
                  ...scale.bands
                    .filter((b) => b.id.startsWith("gap-"))
                    .map((b) => b.id),
                ])
              }
              className="rounded-full border border-dashed px-2 py-0.5 text-[11px] text-muted-foreground hover:bg-accent"
              title="展开全部课间"
            >
              课间 ×
              {scale.bands.filter((b) => b.id.startsWith("gap-")).length}
            </button>
          )}
          {removedFolds.length > 0 && (
            <button
              type="button"
              onClick={() => setRemovedFolds([])}
              className="text-[11px] text-primary hover:underline"
            >
              Expand all
            </button>
          )}
        </div>
      )}

      <div className="min-h-0 flex-1 overflow-auto">
        <div
          className="relative min-w-[900px]"
          style={{
            display: "grid",
            gridTemplateColumns: `${GUTTER_WIDTH}px repeat(7, minmax(0, 1fr))`,
          }}
        >
          {/* Time + period gutter */}
          <div className="relative border-r" style={{ height: scale.heightPx }}>
            {HOURS.map((h) => {
              const m = h * 60;
              if (scale.insideBand(m)) return null;
              return (
                <div
                  key={h}
                  className="absolute right-1 -translate-y-1/2 text-[9px] text-muted-foreground"
                  style={{ top: scale.yOf(m) }}
                >
                  {String(h).padStart(2, "0")}:00
                </div>
              );
            })}
            {/* period start markers: which 节 begins at this line */}
            {periodSlots.map((p) => {
              if (p.start === 0 || scale.insideBand(p.start)) return null;
              return (
                <div
                  key={`${p.no}-${p.start}`}
                  className="absolute right-0.5 flex flex-col items-end text-[9px] leading-none"
                  style={{ top: scale.yOf(p.start) + 10 }}
                  title={`第${p.no}节 ${clockFromMin(p.start)}–${clockFromMin(p.end)}`}
                >
                  <span
                    className="rounded-sm px-0.5 font-semibold"
                    style={{
                      color: "color-mix(in srgb, var(--foreground) 68%, transparent)",
                      background: "color-mix(in srgb, var(--muted-foreground) 12%, transparent)",
                    }}
                  >
                    第{p.no}节
                  </span>
                </div>
              );
            })}
          </div>

          {isLoading && !eventsQuery.data ? (
            <div className="col-span-7 flex items-center justify-center text-muted-foreground">
              <Loader2 className="mr-2 h-5 w-5 animate-spin" />
              Loading week…
            </div>
          ) : (
            bundles.map((b, i) => (
              <DayColumn
                key={b.day}
                bundle={b}
                idx={i}
                tz={tz}
                scale={scale}
                periodSlots={periodSlots}
                nowMinutes={b.day === todayKey ? nowMin : null}
                snap={snap}
                boundaries={boundaries}
                onMoveCommit={handleMoveCommit}
                onOpen={(ev) => setDialog({ kind: "details", event: ev })}
                onToggleBand={(id) => setRemovedFolds((cur) => [...cur, id])}
                onEmptyClick={(minutes) => {
                  const s = snapMinute(minutes, snap, boundaries);
                  setNewBlockSlot({
                    day: b.day,
                    start: s,
                    end: Math.min(s + 60, DAY_MINUTES),
                  });
                }}
              />
            ))
          )}
        </div>
      </div>

      {dialog.kind !== "none" && dialog.kind === "details" && (
        <EventDetailsDialog
          event={dialog.event}
          open
          onOpenChange={() => setDialog({ kind: "none" })}
          onEditBlock={() => setDialog({ kind: "editBlock", event: dialog.event })}
          onChangeTime={() => setDialog({ kind: "time", event: dialog.event })}
          onDelete={() => setDialog({ kind: "delete", event: dialog.event })}
        />
      )}
      {dialog.kind === "editBlock" && (
        <BlockEditorDialog
          event={dialog.event}
          open
          onOpenChange={() => setDialog({ kind: "none" })}
        />
      )}
      {dialog.kind === "time" && (
        <OccurrenceTimeDialog
          event={dialog.event}
          open
          onOpenChange={() => setDialog({ kind: "none" })}
        />
      )}
      {dialog.kind === "delete" && (
        <OccurrenceDeleteDialog
          event={dialog.event}
          open
          onOpenChange={() => setDialog({ kind: "none" })}
        />
      )}
      {newBlockSlot && (
        <NewBlockDialog
          day={newBlockSlot.day}
          startMinutes={newBlockSlot.start}
          endMinutes={newBlockSlot.end}
          tz={tz}
          onOpenChange={() => setNewBlockSlot(null)}
          onCreated={() => {
            void invalidateEventsAfterWrite();
            setNewBlockSlot(null);
          }}
        />
      )}
    </div>
  );
}

const HOURS = Array.from({ length: 24 }, (_, i) => i);

async function moveEventMutation(
  event: CalendarEvent,
  startAt: string,
  endAt: string,
  dayKey: LocalDate
) {
  if (event.source.type === "todo_block") {
    await updateTodoBlock(event.source.id, { startAt, endAt });
    return;
  }
  const seriesType =
    event.source.type === "course_meeting" ? "course_meeting" : "recurring_schedule";
  await applySeriesChange(seriesType, event.source.id, {
    scope: "THIS",
    occurrenceDateLocal: dayKey,
    operation: { type: "MOVE", startAt, endAt },
  });
}

// ---- day column ---------------------------------------------------------------

const SEGMENT_TINTS: { id: string; from: number; to: number; css: string }[] = [
  { id: "night", from: 0, to: 6 * 60, css: "var(--muted-foreground)" },
  { id: "morning", from: 6 * 60, to: 12 * 60, css: "var(--cp-course)" },
  { id: "afternoon", from: 12 * 60, to: 18 * 60, css: "var(--cp-now)" },
  { id: "evening", from: 18 * 60, to: 24 * 60, css: "var(--cp-recurring)" },
];

function DayColumn({
  bundle,
  idx,
  tz,
  scale,
  periodSlots,
  nowMinutes,
  snap,
  boundaries,
  onMoveCommit,
  onOpen,
  onToggleBand,
  onEmptyClick,
}: {
  bundle: DayBundle;
  idx: number;
  tz: string;
  scale: DayScale;
  periodSlots: { no: number; start: number; end: number }[];
  nowMinutes: number | null;
  snap: SnapMode;
  boundaries: number[];
  onMoveCommit: (event: CalendarEvent, day: LocalDate, s: number, e: number) => void;
  onOpen: (event: CalendarEvent) => void;
  onToggleBand: (bandId: string) => void;
  onEmptyClick: (minutes: number) => void;
}) {
  const weekend = idx >= 5;
  const colRef = React.useRef<HTMLDivElement>(null);

  function handleClick(e: React.MouseEvent) {
    const el = colRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const minutes = scale.minAt(e.clientY - rect.top);
    onEmptyClick(minutes);
  }

  return (
    <div
      ref={colRef}
      onClick={handleClick}
      className={`relative cursor-pointer border-l ${weekend ? "bg-weekend/40" : ""}`}
      style={{ height: scale.heightPx }}
    >
      {/* Morning / afternoon / evening tint bands (clipped outside folded spans) */}
      {SEGMENT_TINTS.map((seg) =>
        clipToVisible(seg.from, seg.to, scale).map((r) => (
          <div
            key={`${seg.id}-${r.from}`}
            className="pointer-events-none absolute inset-x-0"
            style={{
              top: scale.yOf(r.from),
              height: Math.max(scale.yOf(r.to) - scale.yOf(r.from), 0),
              background: `color-mix(in srgb, ${seg.css} 3.5%, transparent)`,
            }}
          />
        ))
      )}

      {/* Hour grid lines */}
      {HOURS.map((h) => {
        const m = h * 60;
        if (scale.insideBand(m)) return null;
        return (
          <div
            key={h}
            className="pointer-events-none absolute inset-x-0"
            style={{
              top: scale.yOf(m),
              borderTop: `1px solid color-mix(in srgb, var(--border) 80%, transparent)`,
            }}
          />
        );
      })}

      {/* Period boundaries: soft slot bands + guide lines to locate 第几节 */}
      {periodSlots.map((p) => {
        if (p.start < 0 || p.start >= DAY_MINUTES) return null;
        const vis = clipToVisible(p.start, p.end, scale);
        return vis.map((r, ri) => (
          <div key={`slot-${p.no}-${ri}`}>
            <div
              className="pointer-events-none absolute inset-x-0"
              style={{
                top: scale.yOf(r.from),
                height: Math.max(scale.yOf(r.to) - scale.yOf(r.from), 0),
                background: `color-mix(in srgb, var(--cp-course) 4%, transparent)`,
              }}
            />
            <div
              className="pointer-events-none absolute inset-x-0 border-t border-dashed"
              style={{
                top: scale.yOf(r.from),
                borderColor: "color-mix(in srgb, var(--cp-course) 35%, transparent)",
              }}
            />
          </div>
        ));
      })}

      {/* Collapsed fold strips (visual compression markers) */}
      {scale.bands.map((b) => {
        const stripH = b.height ?? FOLD_HEIGHT_PX;
        return (
          <button
            type="button"
            key={b.id}
            onClick={(e) => {
              e.stopPropagation();
              onToggleBand(b.id);
            }}
            className="absolute inset-x-0 z-20 flex items-center overflow-hidden border-y border-dashed text-muted-foreground hover:bg-accent/60"
            style={{
              top: scale.yOf(b.from),
              height: stripH,
              backgroundImage:
                "repeating-linear-gradient(-45deg, transparent, transparent 6px, color-mix(in srgb, var(--muted-foreground) 12%, transparent) 6px, color-mix(in srgb, var(--muted-foreground) 12%, transparent) 12px)",
            }}
            title={`${b.label} — click to expand`}
          >
            {idx === 0 && stripH >= 20 ? (
              <span className="truncate px-1 text-[9px]">{b.label} ⇅</span>
            ) : (
              <span className="mx-auto text-[10px]">···</span>
            )}
          </button>
        );
      })}

      {/* Course + recurring lanes */}
      {bundle.lanes.map((l) => (
        <EventNode
          key={l.event.id}
          event={l.event}
          dayKey={bundle.day}
          placement={{ leftPct: l.leftPct + 1, widthPct: Math.max(l.widthPct - 2, 8) }}
          tz={tz}
          snap={snap}
          boundaries={boundaries}
          scale={scale}
          draggable
          onMoveCommit={onMoveCommit}
          onOpen={onOpen}
        />
      ))}

      {/* Todo blocks overlay (course layer below, docs/ui-interaction §5) */}
      {bundle.todos.map((ev) => (
        <EventNode
          key={ev.id}
          event={ev}
          dayKey={bundle.day}
          placement={{ leftPct: 0, widthPct: 100 }}
          tz={tz}
          snap={snap}
          boundaries={boundaries}
          scale={scale}
          draggable
          onMoveCommit={onMoveCommit}
          onOpen={onOpen}
        />
      ))}

      {/* Deadlines */}
      {bundle.deadlines.map((ev) => (
        <EventNode
          key={ev.id}
          event={ev}
          dayKey={bundle.day}
          placement={{ leftPct: 0, widthPct: 100 }}
          tz={tz}
          snap={snap}
          boundaries={boundaries}
          scale={scale}
          draggable={false}
          onMoveCommit={onMoveCommit}
          onOpen={onOpen}
        />
      ))}

      {/* Current time line */}
      {nowMinutes !== null && !scale.insideBand(nowMinutes) && (
        <div
          className="pointer-events-none absolute inset-x-0 z-30"
          style={{ top: scale.yOf(nowMinutes) }}
        >
          <div className="h-[2px] w-full" style={{ background: "var(--cp-now)" }} />
          <div
            className="absolute -left-[3px] -top-[3px] h-2 w-2 rounded-full"
            style={{ background: "var(--cp-now)" }}
          />
        </div>
      )}
    </div>
  );
}

// ---- 新建待办-block dialog -------------------------------------------------------

function NewBlockDialog({
  day,
  startMinutes,
  endMinutes,
  tz,
  onOpenChange,
  onCreated,
}: {
  day: LocalDate;
  startMinutes: number;
  endMinutes: number;
  tz: string;
  onOpenChange: (o: boolean) => void;
  onCreated: () => void;
}) {
  const todosQuery = useApiQuery<Todo[]>({
    queryKey: ["todos"],
    cacheKey: cacheKey("GET", "/todos"),
    fetcher: () => listTodos(),
  });
  const [todoId, setTodoId] = React.useState<string>("");
  const [note, setNote] = React.useState("");
  const [start, setStart] = React.useState(clockFromMin(startMinutes));
  const [end, setEnd] = React.useState(clockFromMin(endMinutes));

  const create = useMutation({
    mutationFn: () =>
      import("@/features/todos/api").then((m) =>
        m.createTodoBlock(todoId, {
          startAt: instantFor(day, start, tz),
          endAt: instantFor(day, end, tz),
          blockNote: note || null,
        })
      ),
    onSuccess: () => {
      toast.success("Block scheduled");
      onCreated();
    },
    onError: (err) => toast.error(err instanceof Error ? err.message : "Failed"),
  });

  const todos = todosQuery.data ?? [];
  const empty = !todosQuery.isLoading && todos.length === 0;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
      onClick={onOpenChange as never}
    >
      <div
        className="w-full max-w-sm rounded-lg border bg-background p-5 shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="mb-3 text-base font-semibold">Schedule todo block</h3>
        <p className="mb-3 text-xs text-muted-foreground">{day}</p>
        {empty ? (
          <p className="text-sm text-muted-foreground">
            You don’t have any todos yet — create one on the Todos page first.
          </p>
        ) : (
          <div className="flex flex-col gap-3">
            <select
              className="h-9 w-full rounded-md border border-input bg-transparent px-2 text-sm"
              value={todoId}
              onChange={(e) => setTodoId(e.target.value)}
            >
              <option value="">Select a todo…</option>
              {todos
                .filter((t) => t.status !== "completed" && t.status !== "cancelled")
                .map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.title}
                  </option>
                ))}
            </select>
            <div className="grid grid-cols-2 gap-2">
              <label className="text-xs text-muted-foreground">
                Start
                <input
                  type="time"
                  className="mt-1 h-8 w-full rounded-md border border-input bg-transparent px-2 text-sm"
                  value={start}
                  onChange={(e) => setStart(e.target.value)}
                />
              </label>
              <label className="text-xs text-muted-foreground">
                End
                <input
                  type="time"
                  className="mt-1 h-8 w-full rounded-md border border-input bg-transparent px-2 text-sm"
                  value={end}
                  onChange={(e) => setEnd(e.target.value)}
                />
              </label>
            </div>
            <input
              className="h-9 w-full rounded-md border border-input bg-transparent px-2 text-sm"
              placeholder="时间块备注 (optional)"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
            <div className="flex justify-end gap-2">
              <button
                type="button"
                className="rounded-md px-3 py-1.5 text-sm text-muted-foreground hover:bg-accent"
                onClick={() => onOpenChange(false)}
              >
                取消
              </button>
              <button
                type="button"
                disabled={!todoId || create.isPending}
                className="rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground disabled:opacity-50"
                onClick={() => create.mutate()}
              >
                {create.isPending ? "Saving…" : "Schedule"}
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
