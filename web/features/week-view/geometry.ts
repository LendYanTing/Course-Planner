/**
 * Geometry + visual conventions for the week view (docs/ui-interaction.md).
 * The grid is a continuous 24h time axis measured in minutes; CSS position is
 * purely computed (top/height), never calendar "cells".
 */

export const PX_PER_MINUTE = 1.5; // 90px per hour
export const DAY_MINUTES = 24 * 60;
export const GRID_HEIGHT_PX = Math.round(DAY_MINUTES * PX_PER_MINUTE);

/** Vertical pixel offset of a local-minute value within a day column. */
export function minutesToPx(minutes: number): number {
  return Math.round(minutes * PX_PER_MINUTE);
}

/** Alias used by day-segment shading (docs/ui-interaction.md §3). */
export type DaySegment = "night" | "morning" | "afternoon" | "evening";

export const DAY_SEGMENTS: { from: number; to: number; segment: DaySegment }[] = [
  { from: 0, to: 360, segment: "night" },
  { from: 360, to: 720, segment: "morning" },
  { from: 720, to: 1080, segment: "afternoon" },
  { from: 1080, to: 1440, segment: "evening" },
];

export const SNAP_MODES = [
  { value: "period", label: "Snap: periods" },
  { value: "5_minutes", label: "Snap: 5 min" },
  { value: "free", label: "Snap: free" },
] as const;

export type SnapMode = (typeof SNAP_MODES)[number]["value"];

/**
 * Snap a minute-of-day value to the active mode:
 * - period: nearest period-template boundary (00:00/24:00 implied)
 * - 5_minutes: 5-minute grid
 * - free: unchanged
 */
export function snapMinute(value: number, mode: SnapMode, boundaries: number[]): number {
  if (mode === "free") return Math.max(0, Math.min(DAY_MINUTES, value));
  if (mode === "5_minutes") {
    return Math.max(0, Math.min(DAY_MINUTES, Math.round(value / 5) * 5));
  }
  // period
  if (!boundaries.length) {
    return Math.max(0, Math.min(DAY_MINUTES, Math.round(value / 5) * 5));
  }
  let best = boundaries[0];
  let bestDist = Infinity;
  for (const b of boundaries) {
    const d = Math.abs(b - value);
    if (d < bestDist) {
      bestDist = d;
      best = b;
    }
  }
  return Math.max(0, Math.min(DAY_MINUTES, best));
}
