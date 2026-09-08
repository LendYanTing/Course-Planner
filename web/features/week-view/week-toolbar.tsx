"use client";

import { ChevronLeft, ChevronRight, Plus } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { SNAP_MODES, type SnapMode } from "@/features/week-view/geometry";

export function WeekToolbar({
  rangeLabel,
  onToday,
  onPrev,
  onNext,
  snap,
  onSnapChange,
  foldMode,
  onFoldChange,
  onNewBlock,
}: {
  rangeLabel: string;
  onToday: () => void;
  onPrev: () => void;
  onNext: () => void;
  snap: SnapMode;
  onSnapChange: (m: SnapMode) => void;
  foldMode: "auto" | "none";
  onFoldChange: (m: "auto" | "none") => void;
  onNewBlock: () => void;
}) {
  return (
    <div className="flex h-12 shrink-0 items-center gap-2 border-b px-3">
      <Button variant="outline" size="icon" onClick={onPrev} aria-label="Previous week">
        <ChevronLeft />
      </Button>
      <Button variant="outline" size="icon" onClick={onNext} aria-label="Next week">
        <ChevronRight />
      </Button>
      <Button variant="secondary" size="sm" onClick={onToday}>
        Today
      </Button>
      <span className="ml-1 text-sm font-medium">{rangeLabel}</span>
      <div className="flex-1" />
      <div className="hidden items-center gap-2 sm:flex">
        <Select value={snap} onValueChange={(v) => onSnapChange(v as SnapMode)}>
          <SelectTrigger className="h-8 w-[150px] text-xs">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {SNAP_MODES.map((m) => (
              <SelectItem key={m.value} value={m.value}>
                {m.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={foldMode} onValueChange={(v) => onFoldChange(v as "auto" | "none")}>
          <SelectTrigger className="h-8 w-[130px] text-xs">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="auto">Fold: auto</SelectItem>
            <SelectItem value="none">Fold: none</SelectItem>
          </SelectContent>
        </Select>
      </div>
      <Button size="sm" onClick={onNewBlock}>
        <Plus /> New block
      </Button>
    </div>
  );
}
