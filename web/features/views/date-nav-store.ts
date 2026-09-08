"use client";

/**
 * Shared navigation anchor between week/month/todos views. The anchor is a
 * civil date key in the user's fixed timezone; each view derives its own grid.
 */

import { create } from "zustand";
import type { LocalDate } from "@/generated/entities";
import { addDaysToKey, localDateKey, weekStartKey } from "@/lib/time/tz";

interface DateNavState {
  /** Anchor civil date (YYYY-MM-DD in the user timezone). */
  date: LocalDate | null;
  initializedForTz: string | null;
  ensure: (tz: string) => void;
  goToday: (tz: string) => void;
  setDate: (d: LocalDate) => void;
  /** Shift anchor by whole days (week nav uses ±7, month nav ±daysInMonth). */
  shiftDays: (delta: number, tz: string) => void;
}

export const useDateNav = create<DateNavState>((set, get) => ({
  date: null,
  initializedForTz: null,
  ensure: (tz) => {
    const s = get();
    if (s.initializedForTz === tz && s.date) return;
    set({ date: localDateKey(new Date(), tz), initializedForTz: tz });
  },
  goToday: (tz) => {
    set({ date: localDateKey(new Date(), tz), initializedForTz: tz });
  },
  setDate: (d) => set({ date: d }),
  shiftDays: (delta, tz) => {
    const s = get();
    s.ensure(tz);
    set({ date: addDaysToKey(s.date ?? localDateKey(new Date(), tz), delta) });
  },
}));

/** Monday of the anchor's week. */
export function anchorWeekStart(date: LocalDate | null, tz: string): LocalDate {
  return weekStartKey(date ?? localDateKey(new Date(), tz));
}
