/**
 * Event color handling. User-supplied colors are arbitrary CSS colors; we
 * render them through color-mix so text stays readable and conflicts keep
 * their visual language (docs/ui-interaction.md §5: never rely on color alone).
 */

import type { CalendarEvent } from "@/generated/entities";
import { eventColor } from "@/lib/event-model";

export interface EventPalette {
  accent: string; // strong color: left bar, border, text accents
  bg: string; // translucent fill
  border: string;
  text: string;
}

const DEFAULT_COLOR: Record<string, string> = {
  course: "var(--cp-course)",
  recurring_schedule: "var(--cp-recurring)",
  todo_block: "var(--cp-todo)",
  deadline: "var(--cp-deadline)",
};

export function paletteFor(event: CalendarEvent): EventPalette {
  const explicit = eventColor(event);
  const accent = explicit ?? DEFAULT_COLOR[event.type] ?? "var(--muted-foreground)";
  return {
    accent,
    bg: `color-mix(in srgb, ${accent} 20%, transparent)`,
    border: `color-mix(in srgb, ${accent} 55%, transparent)`,
    text: "var(--foreground)",
  };
}

export function conflictTextureClass(state: string): string {
  if (state === "hard_conflict") return "bg-conflict-hash";
  if (state === "soft_conflict") return "bg-soft-conflict-hash";
  return "";
}
