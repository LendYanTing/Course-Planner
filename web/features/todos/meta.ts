export const PRIORITY_META: Record<
  string,
  { label: string; dot: string; order: number }
> = {
  low: { label: "低", dot: "var(--muted-foreground)", order: 0 },
  normal: { label: "中", dot: "#3b82f6", order: 1 },
  high: { label: "高", dot: "#f97316", order: 2 },
  urgent: { label: "紧急", dot: "#ef4444", order: 3 },
};

export const STATUS_META: Record<string, { label: string }> = {
  todo: { label: "待办" },
  in_progress: { label: "进行中" },
  completed: { label: "已完成" },
  cancelled: { label: "已取消" },
};

export const BLOCK_STATUS_META: Record<string, { label: string }> = {
  scheduled: { label: "已排期" },
  in_progress: { label: "进行中" },
  completed: { label: "已完成" },
  skipped: { label: "已跳过" },
};

export const TODO_TYPE_META: Record<string, { label: string; hint: string }> = {
  one_off: { label: "一次性", hint: "没有排期字段的单个任务。" },
  project: {
    label: "项目",
    hint: "带有截止时间、预计时长与可排期时间块。",
  },
};
