"use client";

import * as React from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import type { WeekParity, WeekRule } from "@/generated/entities";

/** Editable list of {start,end,parity} week segments (docs/csv-import.md model). */
export function WeekRuleEditor({
  value,
  onChange,
  maxWeeks,
}: {
  value: WeekRule;
  onChange: (r: WeekRule) => void;
  maxWeeks?: number;
}) {
  function patch(i: number, part: Partial<WeekRule[number]>) {
    const next = value.map((seg, idx) => (idx === i ? { ...seg, ...part } : seg));
    onChange(next);
  }
  function remove(i: number) {
    onChange(value.filter((_, idx) => idx !== i));
  }
  return (
    <div className="flex flex-col gap-1.5">
      {value.map((seg, i) => (
        <div key={i} className="flex items-center gap-2 text-sm">
          <span className="text-xs text-muted-foreground">Week</span>
          <Input
            className="h-8 w-20"
            type="number"
            min={1}
            max={maxWeeks ?? 60}
            value={seg.start}
            onChange={(e) => patch(i, { start: clamp(Number(e.target.value), 1, maxWeeks ?? 60) })}
          />
          <span className="text-xs text-muted-foreground">–</span>
          <Input
            className="h-8 w-20"
            type="number"
            min={1}
            max={maxWeeks ?? 60}
            value={seg.end}
            onChange={(e) => patch(i, { end: Math.max(seg.start, clamp(Number(e.target.value), 1, maxWeeks ?? 60)) })}
          />
          <Select
            value={seg.parity}
            onValueChange={(v) => patch(i, { parity: v as WeekParity })}
          >
            <SelectTrigger className="h-8 w-24">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">all</SelectItem>
              <SelectItem value="odd">odd</SelectItem>
              <SelectItem value="even">even</SelectItem>
            </SelectContent>
          </Select>
          <Button variant="ghost" size="icon" className="h-8 w-8" onClick={() => remove(i)}>
            <Trash2 />
          </Button>
        </div>
      ))}
      <Button
        type="button"
        variant="outline"
        size="sm"
        className="w-fit"
        onClick={() =>
          onChange([...value, { start: 1, end: maxWeeks ?? 16, parity: "all" }])
        }
      >
        <Plus /> Add week range
      </Button>
    </div>
  );
}

function clamp(n: number, lo: number, hi: number): number {
  if (!Number.isFinite(n)) return lo;
  return Math.max(lo, Math.min(hi, n));
}
