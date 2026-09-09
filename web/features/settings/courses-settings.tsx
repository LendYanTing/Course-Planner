"use client";

import * as React from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { ChevronDown, ChevronRight, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { WeekRuleEditor } from "@/components/week-rule-editor";
import type { Course, CourseMeeting, WeekRule } from "@/generated/entities";
import { useCalendars } from "@/features/calendars/hooks";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey, dropCachePrefix } from "@/db/db";
import { listCourses, createCourse, updateCourse, deleteCourse, updateCourseMeeting, deleteCourseMeeting } from "@/features/courses/api";
import { listCourseMeetings } from "@/features/courses/api";
import { listPeriods } from "@/features/calendars/api";
import type { PeriodTemplate } from "@/generated/entities";
import { COLOR_PRESETS } from "@/lib/palette";

export function CoursesSettings() {
  const qc = useQueryClient();
  const calendars = useCalendars();
  const cals = calendars.data ?? [];
  const [userCalendarId, setUserCalendarId] = React.useState<string>("");
  // Default to the first semester once the list is available.
  const calendarId = userCalendarId || cals[0]?.id || "";

  const courses = useApiQuery<Course[]>({
    queryKey: ["courses", calendarId],
    cacheKey: calendarId ? cacheKey("GET", "/courses", { calendarId }) : "",
    fetcher: () => listCourses(calendarId),
    enabled: !!calendarId,
  });
  const periodsQuery = useApiQuery<PeriodTemplate[]>({
    queryKey: ["calendars", calendarId, "periods"],
    cacheKey: calendarId ? cacheKey("GET", `/calendars/${calendarId}/periods`) : "",
    fetcher: () => listPeriods(calendarId),
    enabled: !!calendarId,
  });
  const [creating, setCreating] = React.useState(false);

  async function invalidate() {
    await dropCachePrefix("/courses");
    await qc.invalidateQueries({ queryKey: ["courses"] });
    if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("cp:data-changed"));
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex items-center gap-2">
        <Label className="text-sm">Calendar</Label>
        <Select value={calendarId} onValueChange={setUserCalendarId}>
          <SelectTrigger className="w-64">
            <SelectValue placeholder="Choose semester" />
          </SelectTrigger>
          <SelectContent>
            {cals.map((c) => (
              <SelectItem key={c.id} value={c.id}>
                {c.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <span className="flex-1" />
        <Button size="sm" disabled={!calendarId} onClick={() => setCreating((c) => !c)}>
          <Plus /> New course
        </Button>
      </div>
      {creating && calendarId && (
        <CourseForm
          calendarId={calendarId}
          periods={periodsQuery.data ?? []}
          onDone={() => {
            setCreating(false);
            void invalidate();
          }}
        />
      )}
      {(courses.data ?? []).map((course) => (
        <CourseCard
          key={course.id}
          course={course}
          onChanged={invalidate}
        />
      ))}
    </div>
  );
}

const WEEKDAY_OPTIONS = [
  ["1", "Monday"], ["2", "Tuesday"], ["3", "Wednesday"], ["4", "Thursday"],
  ["5", "Friday"], ["6", "Saturday"], ["7", "Sunday"],
] as const;

function MeetingFields({
  weekday,
  setWeekday,
  startNo,
  setStartNo,
  endNo,
  setEndNo,
  weekRule,
  setWeekRule,
  maxWeeks,
}: {
  weekday: string;
  setWeekday: (v: string) => void;
  startNo: string;
  setStartNo: (v: string) => void;
  endNo: string;
  setEndNo: (v: string) => void;
  weekRule: WeekRule;
  setWeekRule: (r: WeekRule) => void;
  maxWeeks: number;
}) {
  return (
    <div className="flex flex-col gap-2 rounded border bg-background p-2.5">
      <div className="flex flex-wrap items-center gap-2">
        <Select value={weekday} onValueChange={setWeekday}>
          <SelectTrigger className="h-8 w-32">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {WEEKDAY_OPTIONS.map(([v, l]) => (
              <SelectItem key={v} value={v}>{l}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <span className="flex items-center gap-1 text-sm">
          Period
          <Input className="h-8 w-14" type="number" min={1} value={startNo} onChange={(e) => setStartNo(e.target.value)} />
          –
          <Input className="h-8 w-14" type="number" min={1} value={endNo} onChange={(e) => setEndNo(e.target.value)} />
        </span>
      </div>
      <WeekRuleEditor value={weekRule} onChange={setWeekRule} maxWeeks={maxWeeks} />
    </div>
  );
}

function CourseForm({
  calendarId,
  periods,
  onDone,
}: {
  calendarId: string;
  periods: PeriodTemplate[];
  onDone: () => void;
}) {
  const [name, setName] = React.useState("");
  const [teacher, setTeacher] = React.useState("");
  const [location, setLocation] = React.useState("");
  const [color, setColor] = React.useState("");
  const [notes, setNotes] = React.useState("");
  const [meetings, setMeetings] = React.useState<
    { weekday: string; startNo: string; endNo: string; weekRule: WeekRule }[]
  >([{ weekday: "1", startNo: "1", endNo: "1", weekRule: [{ start: 1, end: 16, parity: "all" }] }]);
  const [busy, setBusy] = React.useState(false);
  const maxWeeks = periods.length ? 60 : 16;

  async function submit() {
    setBusy(true);
    try {
      await createCourse({
        calendarId,
        name,
        teacher: teacher || null,
        location: location || null,
        color: color || null,
        notes: notes || null,
        meetings: meetings.map((m) => ({
          weekday: Number(m.weekday),
          periodStart: Number(m.startNo) || 1,
          periodEnd: Math.max(Number(m.endNo) || 1, Number(m.startNo) || 1),
          weekRule: m.weekRule,
        })),
      });
      toast.success("Course created");
      onDone();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Create failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-3 rounded-md border bg-muted/20 p-3">
      <div className="grid gap-3 sm:grid-cols-2">
        <Field label="Course name *">
          <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="高等数学" />
        </Field>
        <Field label="Teacher">
          <Input value={teacher} onChange={(e) => setTeacher(e.target.value)} />
        </Field>
        <Field label="Location">
          <Input value={location} onChange={(e) => setLocation(e.target.value)} placeholder="逸夫楼201" />
        </Field>
        <Field label="颜色">
          <div className="flex flex-wrap gap-1">
            {["", ...COLOR_PRESETS].map((c) => (
              <button
                key={c || "none"}
                type="button"
                onClick={() => setColor(c)}
                className={`h-6 w-6 rounded-full border ${color === c ? "ring-2 ring-ring" : ""} ${!c ? "text-[10px] text-muted-foreground" : ""}`}
                style={c ? { background: c } : undefined}
              >
                {!c ? "∅" : ""}
              </button>
            ))}
          </div>
        </Field>
      </div>
      <Field label="备注">
        <Textarea rows={1} value={notes} onChange={(e) => setNotes(e.target.value)} />
      </Field>
      <div>
        <Label className="mb-1.5 block text-xs">Meetings (sessions)</Label>
        <div className="flex flex-col gap-2">
          {meetings.map((m, i) => (
            <div key={i}>
              <div className="mb-1 flex items-center justify-between">
                <span className="text-xs font-medium text-muted-foreground">Session {i + 1}</span>
                {meetings.length > 1 && (
                  <Button size="sm" variant="ghost" onClick={() => setMeetings((cur) => cur.filter((_, j) => j !== i))}>
                    <Trash2 />
                  </Button>
                )}
              </div>
              <MeetingFields
                weekday={m.weekday}
                setWeekday={(v) => setMeetings((cur) => cur.map((x, j) => (j === i ? { ...x, weekday: v } : x)))}
                startNo={m.startNo}
                setStartNo={(v) => setMeetings((cur) => cur.map((x, j) => (j === i ? { ...x, startNo: v } : x)))}
                endNo={m.endNo}
                setEndNo={(v) => setMeetings((cur) => cur.map((x, j) => (j === i ? { ...x, endNo: v } : x)))}
                weekRule={m.weekRule}
                setWeekRule={(r) => setMeetings((cur) => cur.map((x, j) => (j === i ? { ...x, weekRule: r } : x)))}
                maxWeeks={maxWeeks}
              />
            </div>
          ))}
        </div>
        <Button
          size="sm" variant="outline" className="mt-2"
          onClick={() =>
            setMeetings((cur) => [...cur, { weekday: "1", startNo: "1", endNo: "1", weekRule: [{ start: 1, end: 16, parity: "all" }] }])
          }
        >
          <Plus /> Add session
        </Button>
      </div>
      <div className="flex justify-end gap-2">
        <Button variant="outline" onClick={onDone}>取消</Button>
        <Button disabled={busy || !name.trim() || !calendarId} onClick={() => void submit()}>
          Create course
        </Button>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1">
      <Label className="text-xs">{label}</Label>
      {children}
    </div>
  );
}

function CourseCard({ course, onChanged }: { course: Course; onChanged: () => void }) {
  const qc = useQueryClient();
  const [open, setOpen] = React.useState(false);
  const [name, setName] = React.useState(course.name);
  const [teacher, setTeacher] = React.useState(course.teacher ?? "");
  const [location, setLocation] = React.useState(course.location ?? "");
  const [notes, setNotes] = React.useState(course.notes ?? "");
  const [busy, setBusy] = React.useState(false);

  const meetings = useApiQuery<CourseMeeting[]>({
    queryKey: ["courses", course.id, "meetings"],
    cacheKey: cacheKey("GET", `/courses/${course.id}/meetings`),
    fetcher: () => listCourseMeetings(course.id),
    enabled: open,
  });

  async function saveMeta() {
    setBusy(true);
    try {
      await updateCourse(course.id, {
        name,
        teacher: teacher || null,
        location: location || null,
        notes: notes || null,
        baseRevision: course.revision,
      });
      toast.success("Course saved");
      await onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "保存 failed");
    } finally {
      setBusy(false);
    }
  }

  async function removeCourse() {
    setBusy(true);
    try {
      await deleteCourse(course.id);
      toast.success("Course deleted");
      await onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "删除 failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-md border">
      <div className="flex items-center gap-2 p-2">
        <Button variant="ghost" size="icon" className="h-7 w-7" onClick={() => setOpen((o) => !o)}>
          {open ? <ChevronDown /> : <ChevronRight />}
        </Button>
        <span className="h-3 w-3 rounded-full" style={{ background: course.color ?? "var(--cp-course)" }} />
        <button type="button" className="min-w-0 flex-1 text-left text-sm font-medium" onClick={() => setOpen((o) => !o)}>
          {course.name}
        </button>
        <span className="text-xs text-muted-foreground">{course.teacher ?? ""}</span>
        <Button size="sm" variant="destructive" disabled={busy} onClick={() => void removeCourse()}>
          <Trash2 />
        </Button>
      </div>
      {open && (
        <div className="flex flex-col gap-3 border-t p-3">
          <div className="grid gap-2 sm:grid-cols-3">
            <Field label="Name"><Input value={name} onChange={(e) => setName(e.target.value)} /></Field>
            <Field label="Teacher"><Input value={teacher} onChange={(e) => setTeacher(e.target.value)} /></Field>
            <Field label="Location"><Input value={location} onChange={(e) => setLocation(e.target.value)} /></Field>
          </div>
          <Field label="备注"><Textarea rows={1} value={notes} onChange={(e) => setNotes(e.target.value)} /></Field>
          <div>
            <Label className="mb-1.5 block text-xs">Sessions</Label>
            {(meetings.data ?? []).map((m) => (
              <MeetingCard key={m.id} courseId={course.id} meeting={m} onChanged={() => void qc.invalidateQueries({ queryKey: ["courses"] })} />
            ))}
          </div>
          <div className="flex justify-end">
            <Button size="sm" disabled={busy} onClick={() => void saveMeta()}>保存 course</Button>
          </div>
        </div>
      )}
    </div>
  );
}

function MeetingCard({ courseId, meeting, onChanged }: { courseId: string; meeting: CourseMeeting; onChanged: () => void }) {
  const qc = useQueryClient();
  const [weekday, setWeekday] = React.useState(String(meeting.weekday));
  const [startNo, setStartNo] = React.useState(String(meeting.periodStart));
  const [endNo, setEndNo] = React.useState(String(meeting.periodEnd));
  const [weekRule, setWeekRule] = React.useState<WeekRule>(meeting.weekRule);
  const [busy, setBusy] = React.useState(false);

  async function save() {
    setBusy(true);
    try {
      await updateCourseMeeting(courseId, meeting.id, {
        weekday: Number(weekday),
        periodStart: Number(startNo),
        periodEnd: Math.max(Number(endNo), Number(startNo)),
        weekRule,
        baseRevision: meeting.revision,
      });
      toast.success("Session saved");
      await onChanged();
      await qc.invalidateQueries({ queryKey: ["courses"] });
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "保存 failed");
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    setBusy(true);
    try {
      await deleteCourseMeeting(courseId, meeting.id);
      toast.success("Session deleted");
      await onChanged();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "删除 failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mb-2 flex flex-wrap items-start gap-2 rounded border bg-background p-2">
      <MeetingFields
        weekday={weekday}
        setWeekday={setWeekday}
        startNo={startNo}
        setStartNo={setStartNo}
        endNo={endNo}
        setEndNo={setEndNo}
        weekRule={weekRule}
        setWeekRule={setWeekRule}
        maxWeeks={60}
      />
      <div className="flex gap-2">
        <Button size="sm" variant="outline" disabled={busy} onClick={() => void save()}>保存</Button>
        <Button size="sm" variant="ghost" disabled={busy} onClick={() => void remove()}><Trash2 /></Button>
      </div>
    </div>
  );
}
