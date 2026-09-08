/** Preset color swatches used by color pickers across the app. */

export const COLOR_PRESETS = [
  "#ef4444", // red
  "#f97316", // orange
  "#f59e0b", // amber
  "#84cc16", // lime
  "#22c55e", // green
  "#14b8a6", // teal
  "#06b6d4", // cyan
  "#3b82f6", // blue
  "#6366f1", // indigo
  "#8b5cf6", // violet
  "#d946ef", // fuchsia
  "#ec4899", // pink
  "#78716c", // stone
  "#6b7280", // gray
];

export function isPresetColor(c: string | null | undefined): c is string {
  return !!c && COLOR_PRESETS.includes(c.toLowerCase());
}
