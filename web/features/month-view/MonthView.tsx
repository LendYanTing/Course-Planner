"use client";

import * as React from "react";
import { useRouter } from "next/navigation";
import { ChevronLeft, ChevronRight, Loader2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { useSession } from "@/features/auth/session-store";
import { useServerNow } from "@/features/time/clock";
import { useDateNav } from "@/features/views/date-nav-store";
import { useRangeEvents } from "@/features/events/hooks";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  addDaysToKey,
  localDateKey,
  localDayStart,
  monthStartKey,
  toIsoUtc,
  weekdayIsoOfKey,
} from "@/lib/time/tz";
import { eventDayKey, eventTitleFallback } from "@/lib/event-model";
import { conflictTextureClass, paletteFor } from "@/lib/event-style";

const DAY_LABELS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

export function MonthView() {
  const tz = useSession((s) => s.user?.timezone ?? "");
  const now = useServerNow(60_000);
  const dateNav = useDateNav();
  const router = useRouter();

  React.useEffect(() => {
    if (tz) dateNav.ensure(tz);
  }, [tz, dateNav]);

  const anchor = dateNav.date ?? (tz ? localDateKey(now, tz) : "");
  const monthKey = tz && anchor ? monthStartKey(anchor) : "";

  // 6-week window starting on the Monday on/before the month start.
  const grid = React.useMemo(() => {
    if (!monthKey) return [];
    const firstWeekday = weekdayIsoOfKey(monthKey); // 1 = Monday
    const gridStart = addDaysToKey(monthKey, 1 - firstWeekday);
    return Array.from({ length: 42 }, (_, i) => addDaysToKey(gridStart, i));
  }, [monthKey]);

  const range = React.useMemo(() => {
    if (!tz || !grid.length) return null;
    return {
      start: toIsoUtc(localDayStart(grid[0], tz)),
      end: toIsoUtc(localDayStart(addDaysToKey(grid[0], grid.length), tz)),
    };
  }, [grid, tz]);

  const query = useRangeEvents(range, !!tz && !!monthKey);

  const byDay = React.useMemo(() => {
    const map = new Map<LocalDate, CalendarEvent[]>();
    if (query.data) {
      for (const ev of query.data) {
        const key = eventDayKey(ev, tz);
        const list = map.get(key) ?? [];
        list.push(ev);
        map.set(key, list);
      }
    }
    for (const list of map.values()) {
      list.sort((a, b) => a.startAt.localeCompare(b.startAt));
    }
    return map;
  }, [query.data, tz]);

  const todayKey = tz ? localDateKey(now, tz) : "";
  const year = monthKey ? Number(monthKey.slice(0, 4)) : 0;
  const monthNo = monthKey ? Number(monthKey.slice(5, 7)) : 0;

  const weeks = React.useMemo(() => {
    const out: LocalDate[][] = [];
    for (let i = 0; i < grid.length; i += 7) out.push(grid.slice(i, i + 7));
    return out;
  }, [grid]);

  function goMonth(delta: number) {
    if (!monthKey) return;
    const [y, m] = monthKey.split("-").map(Number);
    const total = y * 12 + (m - 1) + delta;
    const ny = Math.floor(total / 12);
    const nm = (total % 12 + 12) % 12 + 1;
    dateNav.setDate(`${ny}-${String(nm).padStart(2, "0")}-01`);
  }

  function goToday() {
    dateNav.goToday(tz);
  }

  function openDay(day: LocalDate) {
    dateNav.setDate(day);
    router.push("/week");
  }

  const loading = query.isLoading || query.isPending;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-12 shrink-0 items-center gap-2 border-b px-3">
        <Button variant="outline" size="icon" onClick={() => goMonth(-1)} aria-label="上个月">
          <ChevronLeft />
        </Button>
        <Button variant="outline" size="icon" onClick={() => goMonth(1)} aria-label="下个月">
          <ChevronRight />
        </Button>
        <Button variant="secondary" size="sm" onClick={goToday}>
          今天
        </Button>
        <span className="ml-1 text-sm font-semibold">
          {year ? `${year} 年 ${monthNo} 月` : ""}
        </span>
        <div className="flex-1" />
        <div className="flex items-center gap-3 text-[11px] text-muted-foreground">
          <LegendDot color="var(--cp-course)" label="课程" />
          <LegendDot color="var(--cp-recurring)" label="周期" />
          <LegendDot color="var(--cp-todo)" label="时间块" />
          <LegendDot color="var(--cp-deadline)" label="截止" />
        </div>
      </div>

      <div className="grid grid-cols-7 border-b text-center text-xs font-medium text-muted-foreground">
        {DAY_LABELS.map((d) => (
          <div key={d} className="border-l py-1.5 first:border-l-0">
            {d}
          </div>
        ))}
      </div>

      {loading && !query.data ? (
        <div className="flex flex-1 items-center justify-center text-muted-foreground">
          <Loader2 className="mr-2 h-5 w-5 animate-spin" /> Loading month…
        </div>
      ) : (
        <div className="flex min-h-0 flex-1 flex-col overflow-auto">
          {weeks.map((week) => (
            <div key={week[0]} className="grid min-h-24 flex-1 grid-cols-7 border-b last:border-b-0">
              {week.map((day, di) => {
                const inMonth = day.slice(0, 7) === monthKey.slice(0, 7);
                const weekend = di >= 5;
                const isToday = day === todayKey;
                const events = byDay.get(day) ?? [];
                return (
                  <button
                    type="button"
                    key={day}
                    onClick={() => openDay(day)}
                    className={cn(
                      "flex flex-col items-stretch gap-0.5 border-l p-1 text-left align-top first:border-l-0",
                      !inMonth && "bg-muted/30 text-muted-foreground",
                      weekend && "bg-weekend/40",
                      "hover:bg-accent/40"
                    )}
                  >
                    <span
                      className={cn(
                        "flex h-5 w-5 items-center justify-center self-start rounded-full text-[11px] font-medium",
                        isToday && "bg-primary font-bold text-primary-foreground"
                      )}
                    >
                      {Number(day.slice(8, 10))}
                    </span>
                    <MiniEvents events={events.slice(0, 3)} />
                    {events.length > 3 && (
                      <span className="px-0.5 text-[10px] text-muted-foreground">
                        +{events.length - 3} 更多
                      </span>
                    )}
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function MiniEvents({ events }: { events: CalendarEvent[] }) {
  return (
    <div className="flex w-full flex-col gap-0.5">
      {events.map((ev) => {
        const pal = paletteFor(ev);
        const deadline = ev.type === "deadline";
        const label = ev.type === "deadline" ? `⚠ ${eventTitleFallback(ev)}` : eventTitleFallback(ev);
        return (
          <span
            key={ev.id}
            className={cn(
              "flex items-center gap-1 overflow-hidden rounded px-0.5 py-px text-[10px] leading-tight",
              deadline ? "font-semibold text-white" : "",
              conflictTextureClass(ev.conflictState)
            )}
            style={
              deadline
                ? { background: pal.accent }
                : { background: pal.bg, borderLeft: `2px solid ${pal.accent}` }
            }
            title={`${ev.title} (${ev.type})`}
          >
            <span className="truncate">{label}</span>
          </span>
        );
      })}
    </div>
  );
}

function LegendDot({ color, label }: { color: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1">
      <span className="h-2 w-2 rounded-full" style={{ background: color }} />
      {label}
    </span>
  );
}
