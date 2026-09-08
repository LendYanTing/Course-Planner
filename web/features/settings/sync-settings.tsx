"use client";

import * as React from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { useSyncStore } from "@/features/sync/sync-store";
import { pushPendingOps, getLastCursor } from "@/features/sync/engine";
import { clearDerivedCache } from "@/db/db";
import { useQueryClient } from "@tanstack/react-query";
import { ConflictCenter } from "@/features/sync/conflict-center";
import { RefreshCw, TriangleAlert } from "lucide-react";
import { cn } from "@/lib/utils";

/**
 * Local-data / sync diagnostics: shows connectivity and the pending queue and
 * offers "sync now" plus a hard refresh that keeps pending operations
 * (docs/architecture.md §9).
 */
export function SyncSettingsCard() {
  const qc = useQueryClient();
  const sync = useSyncStore();
  const [conflictsOpen, setConflictsOpen] = React.useState(false);
  const [cursor, setCursor] = React.useState<number | null>(null);
  const [busy, setBusy] = React.useState(false);

  React.useEffect(() => {
    void getLastCursor().then(setCursor);
  }, []);

  async function hardRefresh() {
    setBusy(true);
    try {
      await clearDerivedCache(); // drop derived caches; pendingOps untouched
      await qc.invalidateQueries();
      toast.success("Cache cleared; authoritative data reloaded. Pending changes were kept and will replay.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card className="mt-4">
      <CardHeader className="p-4">
        <CardTitle className="text-base">Sync & local data</CardTitle>
        <CardDescription>
          Writes are queued locally first (Dexie), pushed in the background via
          /sync/push with idempotent operation ids.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-3 text-sm">
          <StatusDot online={sync.online} status={sync.status} />
          <span>
            {sync.online ? "Online" : "Offline"} · {sync.pendingCount} pending · cursor{" "}
            {cursor ?? "—"}
          </span>
          {sync.conflicts.length > 0 && (
            <Button size="sm" variant="outline" onClick={() => setConflictsOpen(true)}>
              <TriangleAlert className="mr-1 text-destructive" />
              {sync.conflicts.length} conflict(s) to resolve
            </Button>
          )}
        </div>
        {sync.lastError && (
          <p className="text-xs text-destructive">Last push error: {sync.lastError}</p>
        )}
        <div className="flex flex-wrap gap-2">
          <Button
            size="sm"
            disabled={!sync.online || sync.status === "syncing" || busy}
            onClick={() => void pushPendingOps()}
          >
            <RefreshCw className={cn(sync.status === "syncing" && "animate-spin")} />
            Sync now
          </Button>
          <Button size="sm" variant="outline" disabled={busy} onClick={() => void hardRefresh()}>
            Hard refresh (keep pending ops)
          </Button>
        </div>
      </CardContent>
      <ConflictCenter open={conflictsOpen} onOpenChange={setConflictsOpen} />
    </Card>
  );
}

function StatusDot({ online, status }: { online: boolean; status: string }) {
  const color = !online
    ? "var(--muted-foreground)"
    : status === "conflict"
      ? "var(--cp-hard-conflict)"
      : status === "syncing"
        ? "var(--cp-now)"
        : "var(--cp-todo)";
  return (
    <span
      className={cn("inline-block h-2.5 w-2.5 rounded-full", status === "syncing" && "animate-pulse")}
      style={{ background: color }}
    />
  );
}
