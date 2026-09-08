"use client";

/**
 * Server-clock offset (docs/datetime.md §8). The UI must not trust the device
 * clock for the "current time" line: we store offset = serverNow - deviceNow
 * and derive estimatedServerNow() = deviceNow + offset.
 */

import { create } from "zustand";
import { useEffect, useRef, useState } from "react";
import { api } from "@/lib/api/http";

interface ClockState {
  offsetMs: number | null;
  lastSyncedAt: number | null;
  sync: () => Promise<void>;
}

export const useClock = create<ClockState>((set) => ({
  offsetMs: null,
  lastSyncedAt: null,
  sync: async () => {
    try {
      const data = await api.get<{ serverTimeUtc: string }>("/meta/time");
      const serverNow = Date.parse(data.serverTimeUtc);
      if (Number.isFinite(serverNow)) {
        set({ offsetMs: serverNow - Date.now(), lastSyncedAt: Date.now() });
      }
    } catch {
      // Keep the last known offset; offline is fine.
    }
  },
}));

/** Best estimate of the current server UTC instant. */
export function estimatedServerNow(): Date {
  const offset = useClock.getState().offsetMs;
  if (offset === null) return new Date();
  return new Date(Date.now() + offset);
}

/** Reactive "now" that refreshes every `intervalMs` (default 1 minute). */
export function useServerNow(intervalMs = 60_000): Date {
  const { offsetMs } = useClock();
  const [now, setNow] = useState<Date>(() => estimatedServerNow());
  void offsetMs; // re-render when the offset is (re)established
  useIntervalEffect(() => {
    setNow(estimatedServerNow());
  }, intervalMs);
  return now;
}

function useIntervalEffect(cb: () => void, ms: number) {
  const saved = useRef(cb);
  saved.current = cb;
  useEffect(() => {
    const id = setInterval(() => saved.current(), ms);
    return () => clearInterval(id);
  }, [ms]);
}
