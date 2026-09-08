"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { useSession } from "@/features/auth/session-store";
import { useServerNow } from "@/features/time/clock";
import { useDateNav, anchorWeekStart } from "@/features/views/date-nav-store";
import {
  useAllPeriods,
  periodBoundariesFromTemplates,
} from "@/features/calendars/hooks";
import { useRangeEvents } from "@/features/events/hooks";
import { listTodos } from "@/features/todos/api";
import { updateTodoBlock } from "@/features/todos/api";
import { applySeriesChange } from "@/features/series/api";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey, dropCachePrefix } from "@/db/db";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  addDaysToKey,
  civilToInstant,
  localDateKey,
  localDayStart,
  minutesOfDay,
  toIsoUtc,
  weekStartKey,
  formatDateKeyShort,
} from "@/lib/time/tz";
import { eventDayKey, eventDurationMinutes, eventStartMinutes, isDeadline } from "@/lib/event-model";
import { layoutColumns } from "@/lib/overlap-layout";
import {
  DAY_MINUTES,
  GRID_HEIGHT_PX,
  PX_PER_MINUTE,
  minutesToPx,
  snapMinute,
  type SnapMode,
} from "@/features/week-view/geometry";
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
  const boundaries = React.useMemo(
    () =>
      periodBoundariesFromTemplates(
        calendarsQuery.data ?? []
      ),
    [calendarsQuery.data]
  );

  const [snap, setSnap] = React.useState<SnapMode>("period");
  const [dialog, setDialog] = React.useState<DialogState>({ kind: "none" });
  const [newBlockSlot, setNewBlockSlot] = React.useState<{
    day: LocalDate;
    start: number;
    end: number;
  } | null>(null);
  const queryClient = useQueryClient();

  // Group events per day.
  const bundles = React.useMemo(() => {
    if (!eventsQuery.data || !tz) return [] as DayBundle[];
    const byDay = new Map<LocalDate, DayBundle>();
    for (const day of days) {
      byDay.set(day, { day, lanes: [], todos: [], deadlines: [] });
    }
    for (const ev of eventsQuery.data) {
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
      // layoutColumns sorts internally and returns placements by input index.
      const items = b.lanes.map((l) => {
        const s = eventStartMinutes(l.event, tz);
        return {
          start: s,
          end: s + Math.max(eventDurationMinutes(l.event), 1),
        };
      });
      const placed = layoutColumns(items);
      b.lanes = b.lanes.map((l, i) => ({
        ...l,
        leftPct: placed[i].leftPct,
        widthPct: placed[i].widthPct,
      }));
      // Render order: todos above lanes; sort stable by start.
      b.todos.sort((a, b) => eventStartMinutes(a, tz) - eventStartMinutes(b, tz));
      out.push(b);
    }
    return out;
  }, [eventsQuery.data, days, tz]);

  const nowMin = tz ? minutesOfDay(now, tz) : 0;

  // ---- move/resize commit (drag) --------------------------------------------

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
    mutationFn(event, startAt, endAt, dayKey)
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

      <div className="min-h-0 flex-1 overflow-auto">
        <div
          className="relative min-w-[900px]"
          style={{
            display: "grid",
            gridTemplateColumns: `${GUTTER_WIDTH}px repeat(7, minmax(0, 1fr))`,
          }}
        >
          {/* Time gutter */}
          <div
            className="relative border-r"
            style={{ height: GRID_HEIGHT_PX }}
          >
            {HOURS.map((h) => (
              <div
                key={h}
                className="absolute right-1 -translate-y-1/2 text-[9px] text-muted-foreground"
                style={{ top: minutesToPx(h * 60) }}
              >
                {String(h).padStart(2, "0")}:00
              </div>
            ))}
          </div>

          {isLoading && !eventsQuery.data ? (
            <div className="col-span-7 flex items-center justify-center text-muted-foreground">
              <Loader2 className="mr-2 h-5 w-5 animate-spin" />
              Loading week…
            </div>
          ) : !eventsQuery.data ? (
            <div className="col-span-7 flex items-center justify-center text-sm text-muted-foreground">
              Cannot load events (offline and no cached copy).
            </div>
          ) : (
            bundles.map((b, i) => (
              <DayColumn
                key={b.day}
                bundle={b}
                idx={i}
                tz={tz}
                today={b.day === todayKey}
                nowMinutes={b.day === todayKey ? nowMin : null}
                snap={snap}
                boundaries={boundaries}
                onMoveCommit={handleMoveCommit}
                onOpen={(ev) => setDialog({ kind: "details", event: ev })}
                onEmptyClick={(minutes) => {
                  const s = snapMinute(minutes, snap, boundaries);
                  setNewBlockSlot({ day: b.day, start: s, end: Math.min(s + 60, DAY_MINUTES) });
                }}
              />
            ))
          )}
        </div>
      </div>

      {/* Dialogs */}
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

function clockFromMin(minutes: number): string {
  const h = Math.floor(minutes / 60) % 24;
  const m = Math.round(minutes % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

async function mutationFn(
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

function DayColumn({
  bundle,
  idx,
  tz,
  today,
  nowMinutes,
  snap,
  boundaries,
  onMoveCommit,
  onOpen,
  onEmptyClick,
}: {
  bundle: DayBundle;
  idx: number;
  tz: string;
  today: boolean;
  nowMinutes: number | null;
  snap: SnapMode;
  boundaries: number[];
  onMoveCommit: (
    event: CalendarEvent,
    day: LocalDate,
    s: number,
    e: number
  ) => void;
  onOpen: (event: CalendarEvent) => void;
  onEmptyClick: (minutes: number) => void;
}) {
  const weekend = idx >= 5;
  const colRef = React.useRef<HTMLDivElement>(null);

  function handleClick(e: React.MouseEvent) {
    const el = colRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const minutes = (e.clientY - rect.top) / PX_PER_MINUTE;
    onEmptyClick(minutes);
  }

  return (
    <div
      ref={colRef}
      onClick={handleClick}
      className={`relative cursor-pointer border-l ${weekend ? "bg-weekend/40" : ""}`}
      style={{
        height: GRID_HEIGHT_PX,
        backgroundImage: `linear-gradient(to bottom, transparent 0, transparent ${minutesToPx(60) - 1}px, color-mix(in srgb, var(--border) 80%, transparent) ${minutesToPx(60) - 1}px, color-mix(in srgb, var(--border) 80%, transparent) ${minutesToPx(60)}px)`,
        backgroundSize: `100% ${minutesToPx(60)}px`,
        backgroundRepeat: "repeat-y",
      }}
    >
      {/* Hour grid lines are drawn by DayColumn backgrounds */}
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
          draggable={false}
          onMoveCommit={onMoveCommit}
          onOpen={onOpen}
        />
      ))}

      {/* Current time line */}
      {nowMinutes !== null && (
        <div
          className="pointer-events-none absolute inset-x-0 z-30"
          style={{ top: minutesToPx(nowMinutes) }}
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

// ---- New todo-block dialog -------------------------------------------------------

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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4" onClick={onOpenChange as never}>
      <div
        className="w-full max-w-sm rounded-lg border bg-background p-5 shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <h3 className="mb-3 text-base font-semibold">
          Schedule todo block
        </h3>
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
              placeholder="Block note (optional)"
              value={note}
              onChange={(e) => setNote(e.target.value)}
            />
            <div className="flex justify-end gap-2">
              <button
                type="button"
                className="rounded-md px-3 py-1.5 text-sm text-muted-foreground hover:bg-accent"
                onClick={() => onOpenChange(false)}
              >
                Cancel
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
