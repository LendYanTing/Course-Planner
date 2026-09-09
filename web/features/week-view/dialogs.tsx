"use client";

/**
 * Event action dialogs for the week view. Series-affecting operations always
 * ask for an explicit scope (THIS / THIS_AND_FUTURE / ALL) in one window
 * (docs/domain-model.md §13, docs/ui-interaction.md §10).
 */

import * as React from "react";
import { useMutation } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  RadioGroup,
  RadioGroupItem,
} from "@/components/ui/radio-group";
import type {
  CalendarEvent,
  LocalDate,
  SeriesScope,
  SeriesType,
} from "@/generated/entities";
import { dropCachePrefix } from "@/db/db";
import { civilToInstant, localDateKey, toIsoUtc } from "@/lib/time/tz";
import { eventDayKey, eventSubtitle, isDeadline } from "@/lib/event-model";
import { updateTodoBlock, deleteTodoBlock } from "@/features/todos/api";
import { applySeriesChange } from "@/features/series/api";
import { useSession } from "@/features/auth/session-store";
import { formatLocalClock } from "@/lib/time/tz";

function minutesToClock(minutes: number): string {
  const h = Math.floor(minutes / 60) % 24;
  const m = minutes % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

async function invalidateEvents() {
  await dropCachePrefix("/calendar/events");
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("cp:data-changed"));
  }
}

// ---- generic shell ----------------------------------------------------------

function DialogShell({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
}: {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  title: string;
  description?: string;
  children: React.ReactNode;
  footer?: React.ReactNode;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{title}</DialogTitle>
          {description && <DialogDescription>{description}</DialogDescription>}
        </DialogHeader>
        <div className="flex flex-col gap-4">{children}</div>
        {footer && <DialogFooter>{footer}</DialogFooter>}
      </DialogContent>
    </Dialog>
  );
}

// ---- todo block editor --------------------------------------------------------

export function BlockEditorDialog({
  event,
  open,
  onOpenChange,
}: {
  event: CalendarEvent;
  open: boolean;
  onOpenChange: (o: boolean) => void;
}) {
  const tz = useTimezone();
  const day = eventDayKey(event, tz);
  const start = event.startAt ? minutesOfInstant(event.startAt, tz) : 9 * 60;
  const end = event.endAt ? minutesOfInstant(event.endAt, tz) : start + 60;
  // This dialog is mounted fresh for every open (caller keys it), so initial
  // state already reflects the current event.
  const [startClock, setStartClock] = React.useState(minutesToClock(start));
  const [endClock, setEndClock] = React.useState(minutesToClock(end));
  const [note, setNote] = React.useState<string>(
    (event.metadata?.blockNote as string) ?? ""
  );

  const save = useMutation({
    mutationFn: () =>
      updateTodoBlock(event.source.id, {
        startAt: instantFor(day, startClock, tz),
        endAt: instantFor(day, endClock, tz),
        blockNote: note || null,
      }),
    onSuccess: async () => {
      await invalidateEvents();
      toast.success("时间块已更新");
      onOpenChange(false);
    },
    onError: (err) => toast.error(msg(err)),
  });

  const del = useMutation({
    mutationFn: () => deleteTodoBlock(event.source.id),
    onSuccess: async () => {
      await invalidateEvents();
      toast.success("时间块已删除");
      onOpenChange(false);
    },
    onError: (err) => toast.error(msg(err)),
  });

  const busy = save.isPending || del.isPending;
  return (
    <DialogShell
      open={open}
      onOpenChange={onOpenChange}
      title="编辑时间块"
      description={`${event.title} · ${day}`}
    >
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label>Start (HH:MM)</Label>
          <Input
            type="time"
            value={startClock}
            onChange={(e) => setStartClock(e.target.value)}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label>End (HH:MM)</Label>
          <Input
            type="time"
            value={endClock}
            onChange={(e) => setEndClock(e.target.value)}
          />
        </div>
      </div>
      <div className="flex flex-col gap-1.5">
        <Label htmlFor="block-note">时间块备注 (what will I do?)</Label>
        <Textarea
          id="block-note"
          value={note}
          placeholder="e.g. 查资料和整理文献"
          onChange={(e) => setNote(e.target.value)}
        />
      </div>
      <div className="flex items-center justify-between gap-2">
        <Button
          variant="destructive"
          size="sm"
          disabled={busy}
          onClick={() => del.mutate()}
        >
          删除
        </Button>
        <div className="flex gap-2">
          <Button variant="outline" onClick={() => onOpenChange(false)} disabled={busy}>
            取消
          </Button>
          <Button disabled={busy} onClick={() => save.mutate()}>
            {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            保存
          </Button>
        </div>
      </div>
    </DialogShell>
  );
}

// ---- occurrence time change (scope THIS) --------------------------------------

export function OccurrenceTimeDialog({
  event,
  open,
  onOpenChange,
}: {
  event: CalendarEvent;
  open: boolean;
  onOpenChange: (o: boolean) => void;
}) {
  const tz = useTimezone();
  const day = eventDayKey(event, tz);
  const startClockDefault = minutesToClock(
    event.startAt ? minutesOfInstant(event.startAt, tz) : 9 * 60
  );
  const endClockDefault = minutesToClock(
    event.endAt ? minutesOfInstant(event.endAt, tz) : 10 * 60
  );
  const [startClock, setStartClock] = React.useState(startClockDefault);
  const [endClock, setEndClock] = React.useState(endClockDefault);

  const save = useMutation({
    mutationFn: () =>
      applySeriesChange(seriesTypeOf(event), event.source.id, {
        scope: "THIS",
        occurrenceDateLocal: day,
        operation: {
          type: "MOVE",
          startAt: instantFor(day, startClock, tz),
          endAt: instantFor(day, endClock, tz),
        },
      }),
    onSuccess: async () => {
      await invalidateEvents();
      toast.success("已移动该次上课");
      onOpenChange(false);
    },
    onError: (err) => toast.error(msg(err)),
  });

  return (
    <DialogShell
      open={open}
      onOpenChange={onOpenChange}
      title="调整该次上课时间"
      description={`${event.title} · ${day} · scope: 仅这一次`}
    >
      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-1.5">
          <Label>Start (HH:MM)</Label>
          <Input
            type="time"
            value={startClock}
            onChange={(e) => setStartClock(e.target.value)}
          />
        </div>
        <div className="flex flex-col gap-1.5">
          <Label>End (HH:MM)</Label>
          <Input
            type="time"
            value={endClock}
            onChange={(e) => setEndClock(e.target.value)}
          />
        </div>
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => onOpenChange(false)} disabled={save.isPending}>
          取消
        </Button>
        <Button onClick={() => save.mutate()} disabled={save.isPending || !startClock || !endClock}>
          {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          应用到该日期
        </Button>
      </div>
    </DialogShell>
  );
}

// ---- delete occurrence / series ------------------------------------------------

const SCOPE_OPTIONS: { value: SeriesScope; label: string; hint: string }[] = [
  { value: "THIS", label: "仅这一次", hint: "Creates a one-off cancellation for this date." },
  { value: "THIS_AND_FUTURE", label: "这一次及以后", hint: "Splits the series: this and later occurrences are cancelled." },
  { value: "ALL", label: "整个系列", hint: "Deletes every occurrence of the series." },
];

export function OccurrenceDeleteDialog({
  event,
  open,
  onOpenChange,
}: {
  event: CalendarEvent;
  open: boolean;
  onOpenChange: (o: boolean) => void;
}) {
  const tz = useTimezone();
  const day = eventDayKey(event, tz);
  const [scope, setScope] = React.useState<SeriesScope>("THIS");

  const del = useMutation({
    mutationFn: () =>
      applySeriesChange(seriesTypeOf(event), event.source.id, {
        scope,
        occurrenceDateLocal: day,
        operation: { type: scope === "THIS" ? "CANCEL" : "DELETE" },
      }),
    onSuccess: async () => {
      await invalidateEvents();
      toast.success("该次上课已移除");
      onOpenChange(false);
    },
    onError: (err) => toast.error(msg(err)),
  });

  const seriesLabel =
    event.source.type === "course_meeting" ? "course meeting" : "schedule";

  return (
    <DialogShell
      open={open}
      onOpenChange={onOpenChange}
      title={`移除该次上课： “${event.title}”`}
      description={`${seriesLabel} · occurrence on ${day}`}
    >
      <RadioGroup value={scope} onValueChange={(v) => setScope(v as SeriesScope)}>
        {SCOPE_OPTIONS.map((o) => (
          <label
            key={o.value}
            className="flex cursor-pointer items-start gap-2 rounded-md border p-2.5 text-sm hover:bg-accent data-[checked=true]:border-primary"
          >
            <RadioGroupItem value={o.value} className="mt-0.5" />
            <span>
              <span className="font-medium">{o.label}</span>
              <span className="block text-xs text-muted-foreground">{o.hint}</span>
            </span>
          </label>
        ))}
      </RadioGroup>
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => onOpenChange(false)} disabled={del.isPending}>
          取消
        </Button>
        <Button
          variant="destructive"
          onClick={() => del.mutate()}
          disabled={del.isPending}
        >
          {del.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {scope === "ALL" ? "删除 series" : "Remove"}
        </Button>
      </div>
    </DialogShell>
  );
}

// ---- details dialog ---------------------------------------------------------------

export function EventDetailsDialog({
  event,
  open,
  onOpenChange,
  onEditBlock,
  onChangeTime,
  onDelete,
}: {
  event: CalendarEvent;
  open: boolean;
  onOpenChange: (o: boolean) => void;
  onEditBlock: () => void;
  onChangeTime: () => void;
  onDelete: () => void;
}) {
  const tz = useTimezone();
  const day = eventDayKey(event, tz);
  const typeBadge =
    event.type === "course"
      ? "course"
      : event.type === "recurring_schedule"
        ? "recurring"
        : event.type === "deadline"
          ? "deadline"
          : "todo";
  const sub = eventSubtitle(event);
  const range = event.endAt
    ? `${formatLocalClock(parseDate(event.startAt), tz)} – ${formatLocalClock(parseDate(event.endAt), tz)}`
    : isDeadline(event)
      ? `by ${formatLocalClock(parseDate(event.startAt), tz)}`
      : formatLocalClock(parseDate(event.startAt), tz);

  const series = event.source.type === "course_meeting" || event.source.type === "recurring_schedule";
  const isBlock = event.source.type === "todo_block";

  return (
    <DialogShell
      open={open}
      onOpenChange={onOpenChange}
      title={event.title || "(untitled)"}
      description={`${day} · ${range}`}
    >
      <div className="flex flex-wrap items-center gap-2">
        <Badge variant={typeBadge as never}>{event.type}</Badge>
        {event.conflictState !== "none" && (
          <Badge variant={event.conflictState === "hard_conflict" ? "destructive" : "outline"}>
            {event.conflictState === "hard_conflict" ? "hard conflict" : "soft conflict"}
          </Badge>
        )}
      </div>
      {sub && <p className="text-sm text-muted-foreground">{sub}</p>}
      <div className="flex flex-wrap gap-2">
        {isBlock && (
          <Button size="sm" onClick={onEditBlock}>
            编辑时间块
          </Button>
        )}
        {series && (
          <Button size="sm" variant="outline" onClick={onChangeTime}>
            调整时间（仅本次）
          </Button>
        )}
        {series && (
          <Button size="sm" variant="destructive" onClick={onDelete}>
            移除该次上课
          </Button>
        )}
        <Button size="sm" variant="ghost" onClick={() => onOpenChange(false)}>
          关闭
        </Button>
      </div>
    </DialogShell>
  );
}

// ---- helpers ----------------------------------------------------------------------

export function parseDate(s: string): Date {
  return new Date(s);
}

function seriesTypeOf(event: CalendarEvent): SeriesType {
  return event.source.type === "course_meeting" ? "course_meeting" : "recurring_schedule";
}

function minutesOfInstant(iso: string, tz: string): number {
  const d = new Date(iso);
  const midnight = civilToInstant(localDateKey(d, tz), tz).getTime();
  return Math.round((d.getTime() - midnight) / 60000);
}

export function instantFor(day: LocalDate, clock: string, tz: string): string {
  const [h, m] = clock.split(":").map(Number);
  return toIsoUtc(civilToInstant(day, tz, { hour: h, minute: m }));
}

function useTimezone(): string {
  return useSession((s) => s.user?.timezone ?? "Asia/Shanghai");
}

function msg(err: unknown): string {
  return err instanceof Error ? err.message : "Request failed";
}
