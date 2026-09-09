"use client";

import * as React from "react";
import { CheckCircle2, CloudOff, RefreshCw, TriangleAlert } from "lucide-react";
import { cn } from "@/lib/utils";
import { useSyncStore } from "@/features/sync/sync-store";
import { ConflictCenter } from "@/features/sync/conflict-center";

export function SyncBadge() {
  const status = useSyncStore((s) => s.status);
  const online = useSyncStore((s) => s.online);
  const pendingCount = useSyncStore((s) => s.pendingCount);
  const conflicts = useSyncStore((s) => s.conflicts);
  const [open, setOpen] = React.useState(false);

  const icon = !online ? (
    <CloudOff className="h-4 w-4 text-muted-foreground" />
  ) : status === "syncing" ? (
    <RefreshCw className="h-4 w-4 animate-spin text-primary" />
  ) : conflicts.length > 0 ? (
    <TriangleAlert className="h-4 w-4 text-destructive" />
  ) : (
    <CheckCircle2 className="h-4 w-4 text-emerald-500" />
  );

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={cn(
          "relative flex h-8 items-center gap-1.5 rounded-md border px-2 text-xs text-muted-foreground transition-colors hover:bg-accent",
          !online && "border-dashed"
        )}
        title={
          conflicts.length
            ? `${conflicts.length} 个同步冲突，请处理`
            : pendingCount
              ? `${pendingCount} 个更改待同步`
              : online
                ? "已同步"
                : "离线"
        }
      >
        {icon}
        {pendingCount > 0 && (
          <span className="rounded-full bg-primary px-1.5 text-[10px] font-semibold text-primary-foreground">
            {pendingCount}
          </span>
        )}
      </button>
      <ConflictCenter open={open} onOpenChange={setOpen} />
    </>
  );
}
