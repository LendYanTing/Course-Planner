"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ChevronDown, ChevronRight, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { cn } from "@/lib/utils";
import type { AcademicCalendar, PeriodTemplate } from "@/generated/entities";
import { useCalendars, usePeriods, mutateCalendarCreate, mutateCalendarUpdate, mutateCalendarDelete, mutatePeriodCreate, mutatePeriodUpdate, mutatePeriodDelete } from "@/features/calendars/hooks";

export function CalendarSettings() {
  const qc = useQueryClient();
  const calendars = useCalendars();
  const [creating, setCreating] = React.useState(false);

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-semibold">Academic calendars (semesters)</h3>
          <p className="text-xs text-muted-foreground">
            A semester defines its first day, total weeks and the period (课节) template.
          </p>
        </div>
        <Button size="sm" onClick={() => setCreating((c) => !c)}>
          <Plus /> New calendar
        </Button>
      </div>
      {creating && (
        <CalendarForm
          onDone={(c) => {
            setCreating(false);
            if (c) toast.success("Calendar created");
          }}
        />
      )}
      {(calendars.data ?? []).map((cal) => (
        <CalendarCard key={cal.id} calendar={cal} onChanged={() => void qc.invalidateQueries({ queryKey: ["calendars"] })} />
      ))}
    </div>
  );
}

function CalendarForm({
  calendar,
  onDone,
}: {
  calendar?: AcademicCalendar;
  onDone: (c: AcademicCalendar | null) => void;
}) {
  const qc = useQueryClient();
  const [name, setName] = React.useState(calendar?.name ?? "");
  const [firstDay, setFirstDay] = React.useState(calendar?.firstDay ?? "");
  const [totalWeeks, setTotalWeeks] = React.useState(String(calendar?.totalWeeks ?? 16));
  const [busy, setBusy] = React.useState(false);

  async function submit() {
    setBusy(true);
    try {
      const base = { name, firstDay, totalWeeks: Number(totalWeeks) || 16 };
      const result = calendar
        ? await mutateCalendarUpdate(calendar.id, { ...base, baseRevision: calendar.revision })
        : await mutateCalendarCreate(base);
      await qc.invalidateQueries({ queryKey: ["calendars"] });
      onDone(result);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="grid gap-3 rounded-md border bg-muted/20 p-3 sm:grid-cols-[1fr_auto_auto_auto]">
      <div className="flex flex-col gap-1">
        <Label className="text-xs">Name</Label>
        <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="2026 Autumn" />
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs">First day</Label>
        <Input type="date" value={firstDay} onChange={(e) => setFirstDay(e.target.value)} />
      </div>
      <div className="flex flex-col gap-1">
        <Label className="text-xs">Weeks</Label>
        <Input type="number" min={1} max={60} className="w-20" value={totalWeeks} onChange={(e) => setTotalWeeks(e.target.value)} />
      </div>
      <div className="flex items-end gap-2">
        <Button size="sm" disabled={busy || !name.trim() || !firstDay} onClick={() => void submit()}>
          {calendar ? "Save" : "Create"}
        </Button>
        {calendar && (
          <Button size="sm" variant="destructive" disabled={busy} onClick={async () => {
            setBusy(true);
            try {
              await mutateCalendarDelete(calendar.id);
              await qc.invalidateQueries({ queryKey: ["calendars"] });
              onDone(null);
            } catch (e) {
              toast.error(e instanceof Error ? e.message : "Delete failed");
            } finally {
              setBusy(false);
            }
          }}>
            <Trash2 />
          </Button>
        )}
      </div>
    </div>
  );
}

function CalendarCard({
  calendar,
  onChanged,
}: {
  calendar: AcademicCalendar;
  onChanged: () => void;
}) {
  const qc = useQueryClient();
  const [open, setOpen] = React.useState(false);
  const [editing, setEditing] = React.useState(false);
  const periods = usePeriods(open || editing ? calendar.id : undefined);
  const list = periods.data ?? [];

  return (
    <div className="rounded-md border">
      <div className="flex items-center gap-2 p-2">
        <Button variant="ghost" size="icon" className="h-7 w-7" onClick={() => setOpen((o) => !o)}>
          {open ? <ChevronDown /> : <ChevronRight />}
        </Button>
        <button type="button" className="min-w-0 flex-1 text-left" onClick={() => setOpen((o) => !o)}>
          <div className="flex flex-wrap items-center gap-2 text-sm font-medium">
            {calendar.name}
            <span className="text-xs text-muted-foreground">
              starts {calendar.firstDay} · {calendar.totalWeeks} weeks
            </span>
          </div>
        </button>
        <Button size="sm" variant="ghost" onClick={() => { setEditing((e) => !e); setOpen(true); }}>
          {editing ? "Done" : "Edit"}
        </Button>
      </div>
      {editing && <div className="border-t p-3"><CalendarForm calendar={calendar} onDone={() => setEditing(false)} /></div>}
      {open && (
        <div className="flex flex-col gap-2 border-t p-3">
          {list.map((p) => (
            <PeriodRow
              key={p.id}
              calendarId={calendar.id}
              period={p}
              onChanged={() => { void qc.invalidateQueries({ queryKey: ["calendars", calendar.id, "periods"] }); onChanged(); }}
            />
          ))}
          <PeriodForm
            calendarId={calendar.id}
            nextNo={list.length ? Math.max(...list.map((p) => p.periodNo)) + 1 : 1}
            onDone={() => void qc.invalidateQueries({ queryKey: ["calendars", calendar.id, "periods"] })}
          />
        </div>
      )}
    </div>
  );
}

function PeriodRow({
  calendarId,
  period,
  onChanged,
}: {
  calendarId: string;
  period: PeriodTemplate;
  onChanged: () => void;
}) {
  const [no, setNo] = React.useState(String(period.periodNo));
  const [s, setS] = React.useState(period.startLocal);
  const [e, setE] = React.useState(period.endLocal);
  const [busy, setBusy] = React.useState(false);

  async function save() {
    setBusy(true);
    try {
      await mutatePeriodUpdate(calendarId, period.id, {
        periodNo: Number(no),
        startLocal: s,
        endLocal: e,
        baseRevision: period.revision,
      });
      toast.success("Period saved");
      onChanged();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    try {
      await mutatePeriodDelete(calendarId, period.id);
      onChanged();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Delete failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex items-center gap-2 text-sm">
      <Label className="w-28 text-xs text-muted-foreground">Period {no}</Label>
      <span className="flex items-center gap-1">
        <input
          type="number" min={1} max={30} value={no}
          onChange={(e) => setNo(e.target.value)}
          className="h-7 w-16 rounded border border-input bg-transparent px-1 text-sm"
        />
      </span>
      <input type="time" value={s} onChange={(e) => setS(e.target.value)} className="h-7 rounded border border-input bg-transparent px-1 text-sm" />
      <span className="text-muted-foreground">–</span>
      <input type="time" value={e} onChange={(e) => setE(e.target.value)} className="h-7 rounded border border-input bg-transparent px-1 text-sm" />
      <span className="flex-1" />
      <Button size="sm" variant="outline" disabled={busy} onClick={() => void save()}>Save</Button>
      <Button size="sm" variant="ghost" disabled={busy} onClick={() => void remove()}><Trash2 /></Button>
    </div>
  );
}

function PeriodForm({
  calendarId,
  nextNo,
  onDone,
}: {
  calendarId: string;
  nextNo: number;
  onDone: () => void;
}) {
  const [no, setNo] = React.useState(String(nextNo));
  const [s, setS] = React.useState("08:00");
  const [e, setE] = React.useState("08:45");
  const [busy, setBusy] = React.useState(false);
  const [visible, setVisible] = React.useState(false);

  async function submit() {
    setBusy(true);
    try {
      await mutatePeriodCreate(calendarId, { periodNo: Number(no), startLocal: s, endLocal: e });
      onDone();
      setNo(String(nextNo + 1));
      toast.success("Period added");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  if (!visible) {
    return (
      <Button size="sm" variant="outline" className="w-fit" onClick={() => setVisible(true)}>
        <Plus /> Add period
      </Button>
    );
  }
  return (
    <div className="flex items-center gap-2 text-sm">
      <span className="text-xs text-muted-foreground">Period</span>
      <input type="number" min={1} max={30} value={no} onChange={(e) => setNo(e.target.value)} className="h-7 w-16 rounded border border-input bg-transparent px-1" />
      <input type="time" value={s} onChange={(e) => setS(e.target.value)} className="h-7 rounded border border-input bg-transparent px-1" />
      <span className="text-muted-foreground">–</span>
      <input type="time" value={e} onChange={(e) => setE(e.target.value)} className="h-7 rounded border border-input bg-transparent px-1" />
      <Button size="sm" disabled={busy} onClick={() => void submit()}>Add</Button>
      <Button size="sm" variant="ghost" onClick={() => setVisible(false)}>Cancel</Button>
    </div>
  );
}

export { cn };
