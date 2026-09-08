"use client";

/**
 * Week-view navigation state (local week anchor). Computed with the user's
 * fixed timezone; never the device timezone.
 */

import { create } from "zustand";
import type { LocalDate } from "@/generated/entities";
import { weekStartKey } from "@/lib/time/tz";

interface WeekState {
  weekStart: LocalDate | null;
  initializedForTz: string | null;
  /** Ensure the anchor exists for `tz` (today's week on first visit). */
  ensure: (tz: string) => void;
  goToday: (tz: string) => void;
  shiftWeek: (delta: 1 | -1, tz: string) => void;
  setWeek: (weekStart: LocalDate) => void;
}

export const useWeekStore = create<WeekState>((set, get) => ({
  weekStart: null,
  initializedForTz: null,
  ensure: (tz) => {
    const s = get();
    if (s.initializedForTz === tz && s.weekStart) return;
    // Today in the user timezone (date-fns-free civil-date computation via Intl).
    const now = new Date();
    const key = civilKeyFromParts(tz, now);
    set({ weekStart: weekStartKey(key), initializedForTz: tz });
  },
  goToday: (tz) => {
    const now = new Date();
    const key = civilKeyFromParts(tz, now);
    set({ weekStart: weekStartKey(key), initializedForTz: tz });
  },
  shiftWeek: (delta, tz) => {
    const s = get();
    s.ensure(tz);
    const cur = s.weekStart ?? weekStartKey(civilKeyFromParts(tz, new Date()));
    set({ weekStart: shiftKey(cur, delta * 7) });
  },
  setWeek: (weekStart) => set({ weekStart }),
}));

import { addDaysToKey, localDateKey } from "@/lib/time/tz";

export function civilKeyFromParts(tz: string, at: Date): LocalDate {
  return localDateKey(at, tz);
}

export function shiftKey(dateKey: string, days: number): string {
  return addDaysToKey(dateKey, days);
}
