"use client";

import * as React from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Badge } from "@/components/ui/badge";
import { useSyncStore } from "@/features/sync/sync-store";
import {
  conflictEntityLabel,
  describeConflict,
  resolveKeepLocal,
  resolveKeepServer,
} from "@/features/sync/resolve";
import { Separator } from "@/components/ui/separator";

/**
 * One window listing all pending sync conflicts. No repeated popups
 * (docs/agent-behavior.md: a single confirmation surface).
 */
export function ConflictCenter({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const conflicts = useSyncStore((s) => s.conflicts);
  const [busy, setBusy] = React.useState<string | null>(null);

  async function act(
    operationId: string,
    kind: "local" | "server"
  ) {
    const record = conflicts.find((c) => c.conflict.operationId === operationId);
    if (!record) return;
    setBusy(operationId);
    try {
      if (kind === "local") {
        const err = await resolveKeepLocal(record);
        if (err) {
          toast.error(err);
        } else {
          toast.success("Local change re-applied");
        }
      } else {
        await resolveKeepServer(record);
        toast.success("Cloud value kept");
      }
    } finally {
      setBusy(null);
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[80dvh] overflow-y-auto sm:max-w-xl">
        <DialogHeader>
          <DialogTitle>Sync conflicts</DialogTitle>
          <DialogDescription>
            {conflicts.length === 0
              ? "No conflicts right now."
              : "Your offline changes could not be auto-merged. Choose what to keep per item."}
          </DialogDescription>
        </DialogHeader>
        {conflicts.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Everything is in sync. ✨
          </p>
        ) : (
          <div className="flex flex-col gap-3">
            {conflicts.map((record) => {
              const c = record.conflict;
              return (
                <div
                  key={c.operationId}
                  className="rounded-md border bg-muted/30 p-3 text-sm"
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex items-center gap-2">
                      <Badge variant="destructive">conflict</Badge>
                      <span className="font-medium">
                        {conflictEntityLabel(c.entityType)}
                      </span>
                    </div>
                    <span className="text-xs text-muted-foreground">
                      {new Date(record.createdAt).toLocaleTimeString()}
                    </span>
                  </div>
                  <p className="mt-1.5 text-muted-foreground">
                    {describeConflict(c, record.operation)}
                  </p>
                  <div className="mt-2 flex gap-2">
                    <Button
                      size="sm"
                      disabled={busy === c.operationId}
                      onClick={() => void act(c.operationId, "local")}
                    >
                      Keep local
                    </Button>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy === c.operationId}
                      onClick={() => void act(c.operationId, "server")}
                    >
                      Keep cloud
                    </Button>
                  </div>
                </div>
              );
            })}
          </div>
        )}
        <Separator />
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            关闭
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
