"use client";

import * as React from "react";
import { CalendarClock, Pencil, TriangleAlert } from "lucide-react";
import { cn } from "@/lib/utils";
import type { CalendarEvent, LocalDate } from "@/generated/entities";
import {
  eventDurationMinutes,
  eventStartMinutes,
  eventSubtitle,
  isDeadline,
} from "@/lib/event-model";
import { paletteFor, conflictTextureClass } from "@/lib/event-style";
import { DAY_MINUTES, snapMinute, type SnapMode } from "@/features/week-view/geometry";
import type { DayScale } from "@/features/week-view/fold";

type DragMode = "move" | "resize-start" | "resize-end";

export interface EventNodeProps {
  event: CalendarEvent;
  dayKey: LocalDate;
  /** placement: lane (partitioned width) or full column width overlay */
  placement: { leftPct: number; widthPct: number };
  tz: string;
  snap: SnapMode;
  boundaries: number[];
  scale: DayScale;
  draggable: boolean;
  onMoveCommit: (
    event: CalendarEvent,
    dayKey: LocalDate,
    startMinutes: number,
    endMinutes: number
  ) => void;
  onOpen: (event: CalendarEvent) => void;
}

export function EventNode({
  event,
  dayKey,
  placement,
  tz,
  snap,
  boundaries,
  scale,
  draggable,
  onMoveCommit,
  onOpen,
}: EventNodeProps) {
  const isDead = isDeadline(event);
  const baseStart = Math.min(eventStartMinutes(event, tz), DAY_MINUTES);
  const duration = eventDurationMinutes(event);
  const baseEnd = isDead ? baseStart : Math.min(baseStart + duration, DAY_MINUTES);

  const [preview, setPreview] = React.useState<{ s: number; e: number } | null>(
    null
  );
  const dragRef = React.useRef<{
    mode: DragMode;
    pointerId: number;
    anchorTop: number;
    relStart: number;
    baseStart: number;
    baseEnd: number;
    moved: boolean;
  } | null>(null);
  const suppressClickUntil = React.useRef(0);

  const s = preview?.s ?? baseStart;
  const e = preview?.e ?? baseEnd;
  const topPx = scale.yOf(s);
  const heightPx = isDead ? undefined : Math.max(scale.yOf(e) - topPx, 6);

  function beginDrag(mode: DragMode, pe: React.PointerEvent<HTMLElement>) {
    if (!draggable || isDead) return;
    pe.preventDefault();
    pe.stopPropagation();
    const el = pe.currentTarget as HTMLElement;
    el.setPointerCapture(pe.pointerId);
    const anchor = (el.offsetParent as HTMLElement | null) ?? el;
    const anchorTop = anchor.getBoundingClientRect().top;
    dragRef.current = {
      mode,
      pointerId: pe.pointerId,
      anchorTop,
      relStart: pe.clientY - anchorTop,
      baseStart: s,
      baseEnd: e,
      moved: false,
    };
  }

  function onPointerMove(pe: React.PointerEvent<HTMLDivElement>) {
    const d = dragRef.current;
    if (!d || d.pointerId !== pe.pointerId) return;
    const relY = pe.clientY - d.anchorTop;
    const deltaMin = scale.minAt(relY) - scale.minAt(d.relStart);
    d.moved = d.moved || Math.abs(relY - d.relStart) > 2;
    const dur = d.baseEnd - d.baseStart;
    let ns: number;
    let ne: number;
    if (d.mode === "move") {
      ns = snapMinute(d.baseStart + deltaMin, snap, boundaries);
      ne = ns + dur;
      if (ne > DAY_MINUTES) {
        ne = DAY_MINUTES;
        ns = Math.max(0, ne - dur);
      }
      if (ns < 0) {
        ns = 0;
        ne = Math.min(dur, DAY_MINUTES);
      }
    } else if (d.mode === "resize-start") {
      ns = snapMinute(d.baseStart + deltaMin, snap, boundaries);
      ns = Math.max(0, Math.min(ns, d.baseEnd - 15));
      ne = d.baseEnd;
    } else {
      ns = d.baseStart;
      ne = snapMinute(d.baseEnd + deltaMin, snap, boundaries);
      ne = Math.max(ns + 15, Math.min(DAY_MINUTES, ne));
    }
    setPreview({ s: ns, e: ne });
  }

  function endDrag(pe: React.PointerEvent<HTMLDivElement>) {
    const d = dragRef.current;
    if (!d || d.pointerId !== pe.pointerId) return;
    dragRef.current = null;
    const moved = d.moved;
    const p = preview;
    setPreview(null);
    if (moved) suppressClickUntil.current = Date.now() + 350;
    if (moved && p && (p.s !== baseStart || p.e !== baseEnd)) {
      onMoveCommit(event, dayKey, p.s, p.e);
    }
  }

  const style = paletteFor(event);
  const texture = conflictTextureClass(event.conflictState);
  const sub = eventSubtitle(event);
  const periodTag = coursePeriodLabel(event);

  const content = (
    <>
      {!isDead && (
        <span
          className="absolute inset-y-0 left-0 w-1 rounded-l-[4px]"
          style={{ background: style.accent }}
        />
      )}
      <div className="flex min-w-0 items-start gap-1 px-1.5">
        <span className="truncate text-[11px] font-semibold leading-tight">
          {event.title || "(untitled)"}
        </span>
        {event.conflictState !== "none" && !isDead && (
          <TriangleAlert
            className="mt-0.5 h-3 w-3 shrink-0"
            style={{ color: "var(--cp-hard-conflict)" }}
            aria-label="conflict"
          />
        )}
        {event.metadata?.overridden === true && (
          <Pencil className="mt-0.5 h-3 w-3 shrink-0 text-muted-foreground" />
        )}
      </div>
      {(periodTag || sub) && !isDead && (
        <div className="truncate px-1.5 text-[10px] leading-tight text-muted-foreground">
          {periodTag && (
            <span className="font-medium" style={{ color: style.accent }}>
              {periodTag}
              {sub ? " · " : ""}
            </span>
          )}
          {sub}
        </div>
      )}
    </>
  );

  if (isDead) {
    return (
      <button
        type="button"
        onPointerDown={(e) => e.stopPropagation()}
        onClick={(e) => {
          e.stopPropagation();
          onOpen(event);
        }}
        className="absolute z-40 -translate-y-1/2"
        style={{ top: topPx, left: "4px", right: "4px" }}
      >
        <span
          className="inline-flex items-center gap-1 rounded-full border px-1.5 py-px text-[10px] font-semibold text-white shadow"
          style={{ background: style.accent, borderColor: style.accent }}
        >
          <CalendarClock className="h-2.5 w-2.5" />
          <span className="truncate">Deadline · {event.title || ""}</span>
        </span>
      </button>
    );
  }

  return (
    <div
      role="button"
      tabIndex={0}
      className={cn(
        "group absolute z-10 overflow-hidden rounded-[4px] border shadow-sm select-none",
        texture,
        draggable && "cursor-grab active:cursor-grabbing"
      )}
      style={{
        top: topPx,
        left: `${placement.leftPct}%`,
        width: `${placement.widthPct}%`,
        height: heightPx,
        background: style.bg,
        borderColor: style.border,
        color: style.text,
        ...(preview ? { zIndex: 60, opacity: 0.85 } : {}),
      }}
      onPointerDown={(e) => beginDrag("move", e)}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={() => {
        dragRef.current = null;
        setPreview(null);
      }}
      onClick={(e) => {
        e.stopPropagation();
        if (Date.now() < suppressClickUntil.current) {
          e.preventDefault();
          return;
        }
        onOpen(event);
      }}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") onOpen(event);
      }}
    >
      {content}
      {draggable && (
        <>
          <span
            className="absolute inset-x-0 top-0 z-10 h-1.5 cursor-n-resize rounded-t-[4px] hover:bg-black/10"
            onPointerDown={(e) => {
              e.stopPropagation();
              beginDrag("resize-start", e);
            }}
          />
          <span
            className="absolute inset-x-0 bottom-0 z-10 h-1.5 cursor-s-resize rounded-b-[4px] hover:bg-black/10"
            onPointerDown={(e) => {
              e.stopPropagation();
              beginDrag("resize-end", e);
            }}
          />
        </>
      )}
    </div>
  );
}

/** “第1节” / “第1–3节” from the event projection metadata. */
export function coursePeriodLabel(event: CalendarEvent): string | null {
  const ps = event.metadata?.periodStart;
  const pe = event.metadata?.periodEnd;
  if (typeof ps !== "number" || typeof pe !== "number") return null;
  return ps === pe ? `第${ps}节` : `第${ps}–${pe}节`;
}
