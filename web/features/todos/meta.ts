export const PRIORITY_META: Record<
  string,
  { label: string; dot: string; order: number }
> = {
  low: { label: "Low", dot: "var(--muted-foreground)", order: 0 },
  normal: { label: "Normal", dot: "#3b82f6", order: 1 },
  high: { label: "High", dot: "#f97316", order: 2 },
  urgent: { label: "Urgent", dot: "#ef4444", order: 3 },
};

export const STATUS_META: Record<string, { label: string }> = {
  todo: { label: "Todo" },
  in_progress: { label: "In progress" },
  completed: { label: "Completed" },
  cancelled: { label: "Cancelled" },
};

export const BLOCK_STATUS_META: Record<string, { label: string }> = {
  scheduled: { label: "Scheduled" },
  in_progress: { label: "In progress" },
  completed: { label: "Completed" },
  skipped: { label: "Skipped" },
};

export const TODO_TYPE_META: Record<string, { label: string; hint: string }> = {
  one_off: { label: "One-off", hint: "A single task without planning fields." },
  project: {
    label: "Project",
    hint: "Adds deadline, estimated duration and schedulable blocks.",
  },
};
