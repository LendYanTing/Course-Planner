/**
 * Interval-lane layout for same-column events (docs/ui-interaction.md §5):
 * horizontally packed non-overlapping placement per calendar day.
 */

export interface IntervalLike {
  start: number; // minutes from local midnight (0..1440)
  end: number; // exclusive end minutes (>= start)
}

export interface PlacedColumn {
  leftPct: number;
  widthPct: number;
  lane: number;
  laneCount: number;
}

interface ActiveItem {
  end: number;
  lane: number;
}

/**
 * Greedy lane packing: process items in (start, then longer-end-first) order;
 * for each item find the first free lane among currently active ones and keep
 * lane count = max concurrent. Returns placement per input index.
 */
export function layoutColumns<T extends IntervalLike>(
  items: T[]
): PlacedColumn[] {
  const order = items
    .map((it, i) => ({ it, i }))
    .sort((a, b) => a.it.start - b.it.start || b.it.end - a.it.end);

  const lanes: (ActiveItem | null)[] = [];
  const out: PlacedColumn[] = new Array(items.length);
  let laneCount = 0;

  for (const { it, i } of order) {
    // Free lanes whose occupant ended.
    for (let l = 0; l < lanes.length; l++) {
      const occ = lanes[l];
      if (occ && occ.end <= it.start) lanes[l] = null;
    }
    // Choose first free lane.
    let lane = lanes.findIndex((o) => o === null);
    if (lane === -1) {
      lane = lanes.length;
      lanes.push(null);
    }
    lanes[lane] = { end: it.end, lane };
    const active = lanes.filter((o) => o !== null).length;
    laneCount = Math.max(laneCount, active);
    out[i] = { lane, laneCount: 0, leftPct: 0, widthPct: 0 }; // filled below
  }

  // Second pass with final laneCount to compute percentages.
  for (let i = 0; i < items.length; i++) {
    const lane = out[i].lane;
    out[i].laneCount = laneCount;
    out[i].leftPct = (lane / laneCount) * 100;
    out[i].widthPct = 100 / laneCount;
  }
  return out;
}

/** Whether two minute-ranges overlap. */
export function overlaps(a: IntervalLike, b: IntervalLike): boolean {
  return a.start < b.end && b.start < a.end;
}
