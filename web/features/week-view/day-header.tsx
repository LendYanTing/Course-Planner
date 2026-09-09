"use client";

import { cn } from "@/lib/utils";
import type { LocalDate } from "@/generated/entities";
import { formatDateKeyShort } from "@/lib/time/tz";

export const GUTTER_WIDTH = 56; // px, matches the time gutter column

const DAY_LABELS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

/**
 * One row of weekday headers (kept outside the scroll area so it stays fixed).
 */
export function WeekDayHeader({
  days,
  todayKey,
}: {
  days: LocalDate[];
  todayKey: LocalDate;
}) {
  return (
    <div
      className="flex h-11 shrink-0 border-b bg-background"
      style={{ gridTemplateColumns: `${GUTTER_WIDTH}px repeat(7, minmax(0, 1fr))`, display: "grid" }}
    >
      <div />
      {days.map((d, i) => {
        const isToday = d === todayKey;
        const weekend = i >= 5;
        return (
          <div
            key={d}
            className={cn(
              "flex items-center justify-center gap-1.5 border-l text-xs",
              weekend && "text-muted-foreground"
            )}
          >
            <span className="hidden md:inline">{DAY_LABELS[i]}</span>
            <span
              className={cn(
                "flex h-6 w-6 items-center justify-center rounded-full text-sm",
                isToday
                  ? "bg-primary font-semibold text-primary-foreground"
                  : "font-medium"
              )}
            >
              {Number(d.slice(8, 10))}
            </span>
            <span className="hidden text-[10px] uppercase text-muted-foreground lg:inline">
              {formatDateKeyShort(d, "UTC").split(" ")[0]}
            </span>
          </div>
        );
      })}
    </div>
  );
}
