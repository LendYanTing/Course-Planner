"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  RadioGroup,
  RadioGroupItem,
} from "@/components/ui/radio-group";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { WeekRuleEditor } from "@/components/week-rule-editor";
import type { RecurringRule, RecurringSchedule, WeekRule } from "@/generated/entities";
import { useCalendars, usePeriods } from "@/features/calendars/hooks";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey, dropCachePrefix } from "@/db/db";
import { listRecurringSchedules, createRecurringSchedule, updateRecurringSchedule, deleteRecurringSchedule } from "@/features/schedules/api";

const WEEKDAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export function SchedulesSettings() {
  const qc = useQueryClient();
  const query = useApiQuery<RecurringSchedule[]>({
    queryKey: ["recurring-schedules"],
    cacheKey: cacheKey("GET", "/recurring-schedules"),
    fetcher: () => listRecurringSchedules(),
  });
  const [editing, setEditing] = React.useState<RecurringSchedule | "new" | null>(null);

  async function invalidate() {
    await dropCachePrefix("/recurring-schedules");
    await qc.invalidateQueries({ queryKey: ["recurring-schedules"] });
    if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("cp:data-changed"));
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-semibold">Recurring schedules</h3>
          <p className="text-xs text-muted-foreground">
            Fixed activities that repeat (daily, weekly, by academic week). No todos, no deadlines.
          </p>
        </div>
        <Button size="sm" onClick={() => setEditing("new")}>
          <Plus /> New schedule
        </Button>
      </div>
      {(query.data ?? []).map((s) => (
        <div key={s.id} className="flex items-center gap-2 rounded-md border p-2.5">
          <span className="h-3 w-3 rounded-full" style={{ background: s.color ?? "var(--cp-recurring)" }} />
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium">{s.title}</p>
            <p className="truncate text-xs text-muted-foreground">{ruleSummary(s.rule)}</p>
          </div>
          <Button size="sm" variant="outline" onClick={() => setEditing(s)}>Edit</Button>
          <Button
            size="sm" variant="ghost"
            onClick={async () => {
              try {
                await deleteRecurringSchedule(s.id);
                toast.success("Schedule deleted");
                await invalidate();
              } catch (e) {
                toast.error(e instanceof Error ? e.message : "Delete failed");
              }
            }}
          >
            <Trash2 />
          </Button>
        </div>
      ))}
      {editing && (
        <ScheduleDialog
          schedule={editing === "new" ? null : editing}
          onClose={() => setEditing(null)}
          onSaved={invalidate}
        />
      )}
    </div>
  );
}

export function ruleSummary(r: RecurringRule): string {
  const kindLabel: Record<string, string> = {
    daily: "Daily",
    weekly: "Weekly",
    by_academic_week: "By academic week",
  };
  const time =
    r.startLocal && r.endLocal
      ? `${r.startLocal}–${r.endLocal}`
      : r.periodStart && r.periodEnd
        ? `periods ${r.periodStart}–${r.periodEnd}`
        : "";
  if (r.kind === "daily" || r.kind === "weekly") {
    return `${kindLabel[r.kind]} ${r.dateStart ?? ""} → ${r.dateEnd ?? ""} · ${time}`;
  }
  const wd = (r.weekdays ?? []).map((d) => WEEKDAY_SHORT[d - 1]).join(",");
  return `${kindLabel[r.kind]} ${wd} · ${time}`;
}

function ScheduleDialog({
  schedule,
  onClose,
  onSaved,
}: {
  schedule: RecurringSchedule | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const cals = useCalendars();
  const [title, setTitle] = React.useState(schedule?.title ?? "");
  const [notes, setNotes] = React.useState(schedule?.notes ?? "");
  const [kind, setKind] = React.useState<RecurringRule["kind"]>(schedule?.rule.kind ?? "weekly");
  const [dateStart, setDateStart] = React.useState(schedule?.rule.dateStart ?? "");
  const [dateEnd, setDateEnd] = React.useState(schedule?.rule.dateEnd ?? "");
  const [startLocal, setStartLocal] = React.useState(schedule?.rule.startLocal ?? "19:00");
  const [endLocal, setEndLocal] = React.useState(schedule?.rule.endLocal ?? "20:00");
  const [weekdays, setWeekdays] = React.useState<number[]>(schedule?.rule.weekdays ?? []);
  const [calendarId, setCalendarId] = React.useState(schedule?.rule.calendarId ?? cals.data?.[0]?.id ?? "");
  const [timeSource, setTimeSource] = React.useState<"periods" | "clock">(
    schedule?.rule.periodStart ? "periods" : "clock"
  );
  const [periodStart, setPeriodStart] = React.useState(String(schedule?.rule.periodStart ?? 1));
  const [periodEnd, setPeriodEnd] = React.useState(String(schedule?.rule.periodEnd ?? 1));
  const [weekRule, setWeekRule] = React.useState<WeekRule>(
    schedule?.rule.weekRule ?? [{ start: 1, end: 16, parity: "all" }]
  );
  const [busy, setBusy] = React.useState(false);

  const calId = schedule?.rule.kind === "by_academic_week" && schedule.rule.calendarId ? schedule.rule.calendarId : calendarId;
  const periods = usePeriods(calId || undefined);
  const periodCount = (periods.data ?? []).length;

  function toggleDay(d: number) {
    setWeekdays((cur) => (cur.includes(d) ? cur.filter((x) => x !== d) : [...cur, d].sort()));
  }

  async function save() {
    setBusy(true);
    try {
      const rule: RecurringRule =
        kind === "by_academic_week"
          ? {
              kind,
              calendarId: calId,
              weekdays,
              weekRule,
              ...(timeSource === "periods"
                ? { periodStart: Number(periodStart) || 1, periodEnd: Math.max(Number(periodEnd) || 1, Number(periodStart) || 1) }
                : { startLocal, endLocal }),
            }
          : {
              kind,
              dateStart,
              dateEnd,
              startLocal,
              endLocal,
              ...(kind === "weekly" ? { weekdays } : {}),
            };
      if (schedule) {
        await updateRecurringSchedule(schedule.id, {
          title,
          notes: notes || null,
          rule,
          baseRevision: schedule.revision,
        });
      } else {
        await createRecurringSchedule({ title, notes: notes || null, rule });
      }
      toast.success(schedule ? "Schedule saved" : "Schedule created");
      onClose();
      await onSaved();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  const isWeekKind = kind === "weekly" || kind === "by_academic_week";

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-h-[85dvh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{schedule ? "Edit schedule" : "New recurring schedule"}</DialogTitle>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          <div className="flex flex-col gap-1.5">
            <Label>Title</Label>
            <Input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="晚自习 / Gym / 日语课" />
          </div>

          <RadioGroup value={kind} onValueChange={(v) => setKind(v as RecurringRule["kind"])}>
            {(
              [
                ["daily", "Daily"],
                ["weekly", "Weekly (by weekday)"],
                ["by_academic_week", "By academic week"],
              ] as [RecurringRule["kind"], string][]
            ).map(([k, label]) => (
              <label key={k} className="flex items-center gap-2 text-sm">
                <RadioGroupItem value={k} />
                {label}
              </label>
            ))}
          </RadioGroup>

          {kind !== "by_academic_week" && (
            <div className="grid grid-cols-2 gap-3">
              <div className="flex flex-col gap-1.5">
                <Label>From date</Label>
                <Input type="date" value={dateStart} onChange={(e) => setDateStart(e.target.value)} />
              </div>
              <div className="flex flex-col gap-1.5">
                <Label>To date</Label>
                <Input type="date" value={dateEnd} onChange={(e) => setDateEnd(e.target.value)} />
              </div>
            </div>
          )}

          {isWeekKind && (
            <div>
              <Label className="mb-1.5 block text-xs">Weekdays</Label>
              <div className="flex flex-wrap gap-2">
                {WEEKDAY_SHORT.map((label, i) => {
                  const d = i + 1;
                  return (
                    <label
                      key={d}
                      className={`flex cursor-pointer items-center gap-1 rounded-md border px-2 py-1 text-xs ${weekdays.includes(d) ? "border-primary bg-primary/10" : ""}`}
                    >
                      <Checkbox checked={weekdays.includes(d)} onCheckedChange={() => toggleDay(d)} className="h-3.5 w-3.5" />
                      {label}
                    </label>
                  );
                })}
              </div>
            </div>
          )}

          {kind === "by_academic_week" && (
            <>
              <div className="flex flex-col gap-1.5">
                <Label>Calendar</Label>
                <Select value={calId} onValueChange={setCalendarId}>
                  <SelectTrigger>
                    <SelectValue placeholder="Semester" />
                  </SelectTrigger>
                  <SelectContent>
                    {(cals.data ?? []).map((c) => (
                      <SelectItem key={c.id} value={c.id}>{c.name}</SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div>
                <Label className="mb-1.5 block text-xs">Time source</Label>
                <RadioGroup value={timeSource} onValueChange={(v) => setTimeSource(v as "periods" | "clock")} className="flex gap-4">
                  <label className="flex items-center gap-2 text-sm"><RadioGroupItem value="periods" /> Periods (课节)</label>
                  <label className="flex items-center gap-2 text-sm"><RadioGroupItem value="clock" /> Exact clock</label>
                </RadioGroup>
              </div>
              {timeSource === "periods" ? (
                <div className="flex items-center gap-2">
                  <span className="text-sm">Period</span>
                  <Input className="w-16" type="number" min={1} value={periodStart} onChange={(e) => setPeriodStart(e.target.value)} />
                  <span>–</span>
                  <Input className="w-16" type="number" min={1} value={periodEnd} onChange={(e) => setPeriodEnd(e.target.value)} />
                  <span className="text-xs text-muted-foreground">{periodCount} periods in template</span>
                </div>
              ) : (
                <div className="flex items-center gap-2">
                  <Input type="time" value={startLocal} onChange={(e) => setStartLocal(e.target.value)} />
                  <span>–</span>
                  <Input type="time" value={endLocal} onChange={(e) => setEndLocal(e.target.value)} />
                </div>
              )}
              <div className="flex flex-col gap-1.5">
                <Label className="text-xs">Weeks (academic week rule)</Label>
                <WeekRuleEditor value={weekRule} onChange={setWeekRule} maxWeeks={60} />
              </div>
            </>
          )}

          {kind !== "by_academic_week" && (
            <div className="flex items-center gap-2">
              <Input type="time" value={startLocal} onChange={(e) => setStartLocal(e.target.value)} />
              <span className="text-muted-foreground">–</span>
              <Input type="time" value={endLocal} onChange={(e) => setEndLocal(e.target.value)} />
            </div>
          )}

          <div className="flex flex-col gap-1.5">
            <Label>Notes (optional)</Label>
            <Textarea rows={1} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={busy}>Cancel</Button>
          <Button disabled={busy || !title.trim()} onClick={() => void save()}>
            {busy && <Loader2 className="h-4 w-4 animate-spin" />}
            {schedule ? "Save" : "Create"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
