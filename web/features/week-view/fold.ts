/**
 * Foldable time segments (docs/ui-interaction.md §3).
 *
 * Folding is purely VISUAL compression: real times never change. Dead spans of
 * the day — 凌晨 / 午休 / 夜间 and short 课间 gaps between consecutive periods
 * — collapse into thin labelled strips; everything else keeps the linear
 * PX_PER_MINUTE scale. A band is only foldable when no event (course /
 * recurring / todo block / deadline) and not the current time fall inside it,
 * so real content is never hidden.
 */

import { DAY_MINUTES, PX_PER_MINUTE } from "@/features/week-view/geometry";

export const FOLD_HEIGHT_PX = 34;
export const GAP_FOLD_HEIGHT_PX = 14;

export interface FoldBand {
  id: string;
  label: string;
  from: number; // minute-of-day, inclusive
  to: number; // minute-of-day, exclusive
  /** Visual collapsed height in px; defaults to FOLD_HEIGHT_PX. */
  height?: number;
}

export interface DayScale {
  bands: FoldBand[];
  heightPx: number;
  /** Map real minute-of-day -> vertical pixel offset (compressed inside bands). */
  yOf: (minutes: number) => number;
  /** Inverse of yOf for clicks/drags. */
  minAt: (y: number) => number;
  /** True when a real minute is inside a folded band. */
  insideBand: (minutes: number) => boolean;
}

/** Linear scale when nothing is folded (keeps drag math identical). */
export const LINEAR_SCALE: DayScale = {
  bands: [],
  heightPx: DAY_MINUTES * PX_PER_MINUTE,
  yOf: (m) => Math.round(Math.max(0, Math.min(DAY_MINUTES, m)) * PX_PER_MINUTE),
  minAt: (y) => Math.max(0, Math.min(DAY_MINUTES, y / PX_PER_MINUTE)),
  insideBand: () => false,
};

function bandHeight(b: FoldBand): number {
  return b.height ?? FOLD_HEIGHT_PX;
}

/** Build the piecewise scale for a (sorted, non-overlapping) band list. */
export function buildScale(bands: FoldBand[]): DayScale {
  if (!bands.length) return LINEAR_SCALE;
  const sorted = [...bands].sort((a, b) => a.from - b.from);

  // Piecewise anchor points: between bands linear at PX_PER_MINUTE, inside a
  // band compressed to its collapsed height over the band's real span.
  const anchors: { m: number; y: number }[] = [{ m: 0, y: 0 }];
  let m = 0;
  let y = 0;
  for (const band of sorted) {
    if (band.from > m) y += (band.from - m) * PX_PER_MINUTE;
    anchors.push({ m: band.from, y });
    y += bandHeight(band);
    m = band.to;
    anchors.push({ m: band.to, y });
  }
  if (m < DAY_MINUTES) y += (DAY_MINUTES - m) * PX_PER_MINUTE;
  anchors.push({ m: DAY_MINUTES, y });
  const heightPx = y;

  function bandFor(minutes: number): FoldBand | null {
    for (const b of sorted) {
      if (minutes >= b.from && minutes < b.to) return b;
    }
    return null;
  }

  function yOf(minutes: number): number {
    const v = Math.max(0, Math.min(DAY_MINUTES, minutes));
    const band = bandFor(v);
    if (band) {
      const a = anchors.find((p) => p.m === band.from);
      const baseY = a ? a.y : 0;
      const ratio = (v - band.from) / Math.max(1, band.to - band.from);
      return Math.round(baseY + ratio * bandHeight(band));
    }
    // Linear segment: find anchor pair around v.
    let prev = anchors[0];
    for (const a of anchors) {
      if (a.m <= v) prev = a;
      else break;
    }
    const yAt = prev.y + (v - prev.m) * PX_PER_MINUTE;
    return Math.round(yAt);
  }

  function minAt(py: number): number {
    const v = Math.max(0, Math.min(heightPx, py));
    // If inside a band strip (compressed region), map proportionally.
    for (const band of sorted) {
      const a = anchors.find((p) => p.m === band.from);
      const baseY = a ? a.y : 0;
      if (v >= baseY && v < baseY + bandHeight(band)) {
        const ratio = (v - baseY) / bandHeight(band);
        return Math.round(band.from + ratio * (band.to - band.from));
      }
    }
    let prev = anchors[0];
    for (const a of anchors) {
      if (a.y <= v) prev = a;
      else break;
    }
    const mm = prev.m + (v - prev.y) / PX_PER_MINUTE;
    return Math.max(0, Math.min(DAY_MINUTES, mm));
  }

  return {
    bands: sorted,
    heightPx: Math.round(heightPx),
    yOf,
    minAt,
    insideBand: (minutes) => !!bandFor(minutes),
  };
}

function clockOf(min: number): string {
  const h = Math.floor(min / 60);
  const m = Math.round(min % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

/**
 * Propose fold bands from the period template of the active semester(s):
 * - 凌晨 0:00 up to the first period (≥ 4h of emptiness)
 * - 午休 the biggest midday gap between periods that contains 12:00–13:00
 * - 课间 every short gap between two consecutive periods (≥ 6 and < 150 min,
 *   excluding the band already chosen as 午休). 课间 gaps fold even when a
 *   merged course (连堂课) spans across them — that gap is a real break — but
 *   never when a todo block / deadline sits inside, so scheduled work is
 *   never hidden.
 * - 夜间 after the last period to 24:00 (≥ 3h of emptiness)
 * Long bands (凌晨/午休/夜间) are only folded when completely empty for the
 * whole week and not under the current time.
 */
export function proposeFoldBands(opts: {
  periodStarts: { no: number; start: number; end: number }[];
  /** Any event: long bands never hide these. */
  occupied: { from: number; to: number }[];
  /** todo blocks / deadlines: even 10-min gap bands must not hide these. */
  gapForbidden: { from: number; to: number }[];
  nowMin: number | null;
}): FoldBand[] {
  const { periodStarts, occupied, gapForbidden, nowMin } = opts;
  if (!periodStarts.length) return [];

  const sorted = [...periodStarts].sort((a, b) => a.start - b.start);
  const candidates: FoldBand[] = [];

  const first = sorted[0];
  if (first.start >= 4 * 60) {
    candidates.push({
      id: "night",
      label: `凌晨折叠 00:00–${clockOf(first.start)}`,
      from: 0,
      to: first.start,
    });
  }

  // Midday gap between consecutive periods containing the lunch window.
  let lunchGap: { from: number; to: number } | null = null;
  for (let i = 0; i < sorted.length - 1; i++) {
    const gap = { from: sorted[i].end, to: sorted[i + 1].start };
    if (
      gap.to - gap.from >= 60 &&
      gap.from < 13 * 60 &&
      gap.to > 11 * 60
    ) {
      if (!lunchGap || gap.to - gap.from > lunchGap.to - lunchGap.from) {
        lunchGap = gap;
      }
    }
  }
  if (lunchGap) {
    candidates.push({
      id: "lunch",
      label: `午休折叠 ${clockOf(lunchGap.from)}–${clockOf(lunchGap.to)}`,
      from: lunchGap.from,
      to: lunchGap.to,
    });
  }

  // 课间: short free gaps between consecutive periods (10-min breaks etc).
  const lunchFrom = lunchGap?.from ?? -1;
  const lunchTo = lunchGap?.to ?? -1;
  const forbidsBand = (from: number, to: number) =>
    gapForbidden.some((o) => o.from < to && o.to > from);
  for (let i = 0; i < sorted.length - 1; i++) {
    const gap = { from: sorted[i].end, to: sorted[i + 1].start };
    const len = gap.to - gap.from;
    if (len < 6 || len >= 150) continue;
    // Already covered by the 午休 band?
    if (lunchGap && gap.from === lunchFrom && gap.to === lunchTo) continue;
    if (forbidsBand(gap.from, gap.to)) continue;
    if (nowMin !== null && nowMin >= gap.from && nowMin < gap.to) continue;
    candidates.push({
      id: `gap-${gap.from}-${gap.to}`,
      label: `课间 ${clockOf(gap.from)}–${clockOf(gap.to)}`,
      from: gap.from,
      to: gap.to,
      height: GAP_FOLD_HEIGHT_PX,
    });
  }

  const last = sorted[sorted.length - 1];
  if (DAY_MINUTES - last.end >= 3 * 60) {
    candidates.push({
      id: "evening",
      label: `夜间折叠 ${clockOf(last.end)}–24:00`,
      from: last.end,
      to: DAY_MINUTES,
    });
  }

  // Long bands only fold when completely empty this week (and not now).
  return candidates
    .filter((band) => {
      if (band.id.startsWith("gap-")) return true; // already vetted above
      const hasEvent = occupied.some(
        (o) => o.from < band.to && o.to > band.from
      );
      if (hasEvent) return false;
      if (nowMin !== null && nowMin >= band.from && nowMin < band.to)
        return false;
      return true;
    })
    .sort((a, b) => a.from - b.from);
}

/** Clip [from,to) into sub-ranges that are not inside folded bands. */
export function clipToVisible(
  from: number,
  to: number,
  scale: DayScale
): { from: number; to: number }[] {
  if (!scale.bands.length) return [{ from, to }];
  const out: { from: number; to: number }[] = [];
  let cursor = from;
  for (const band of scale.bands) {
    if (band.to <= cursor || band.from >= to) continue;
    if (cursor < band.from) {
      out.push({ from: cursor, to: Math.min(band.from, to) });
    }
    cursor = Math.max(cursor, band.to);
    if (cursor >= to) break;
  }
  if (cursor < to) out.push({ from: cursor, to });
  return out;
}
