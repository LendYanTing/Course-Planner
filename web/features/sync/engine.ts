/**
 * Sync engine runtime: listens to connectivity, replays pending operations via
 * /sync/push, records conflicts, and refreshes caches after a successful push.
 */

import { api } from "@/lib/api/http";
import type {
  SyncEntityType,
  SyncOpKind,
  SyncPushResult,
} from "@/generated/entities";
import {
  db,
  dropCachePrefix,
  setMeta,
  type PendingOp,
} from "@/db/db";
import {
  countPendingOps,
  dropPendingOp,
  listPendingOps,
  useSyncStore,
} from "@/features/sync/sync-store";

export const SYNC_CURSOR_KEY = "sync.serverCursor";
const MAX_BATCH = 200;

let started = false;

/** 注册 online/offline listeners and a periodic replays timer. */
export function startSyncEngine() {
  if (started) return;
  started = true;

  const updateOnline = () => {
    const online = navigator.onLine;
    useSyncStore.getState().setOnline(online);
    if (online) {
      void pushPendingOps();
    } else {
      useSyncStore.getState().setStatus("offline");
    }
  };
  window.addEventListener("online", updateOnline);
  window.addEventListener("offline", updateOnline);

  // Periodic replay while online (also covers slow reconnects).
  setInterval(() => {
    if (navigator.onLine) void pushPendingOps();
  }, 45_000);

  updateOnline();
}

export async function pushPendingOps(): Promise<void> {
  const sync = useSyncStore.getState();
  if (!sync.online) return;
  if (sync.status === "syncing") return;

  const pending = await listPendingOps();
  if (pending.length === 0) {
    sync.setStatus("idle");
    return;
  }

  sync.setStatus("syncing");
  const cursor = await getLastCursor();
  const batch: PendingOp[] = pending.slice(0, MAX_BATCH);
  try {
    const result = await api.post<SyncPushResult>("/sync/push", {
      baseCursor: cursor,
      operations: batch.map(toSyncOp),
    });
    await setMeta(SYNC_CURSOR_KEY, result.serverCursor);
    // Drop ops that the server accepted or merged.
    const okIds = new Set([...result.accepted, ...result.merged]);
    for (const op of batch) {
      if (okIds.has(op.operationId)) await dropPendingOp(op.operationId);
    }
    for (const conflict of result.conflicts) {
      await db.pendingOps
        .where("operationId")
        .equals(conflict.operationId)
        .delete();
      const op = batch.find((o) => o.operationId === conflict.operationId);
      sync.addConflict(conflict, op?.operation);
    }
    await sync.setPendingCount(await countPendingOps());
    useSyncStore.setState({
      lastPushAt: Date.now(),
      lastError: null,
      status: result.conflicts.length ? "conflict" : "idle",
    });
    if (okIds.size > 0) {
      // Server state changed: drop derived caches so views refetch truth.
      await invalidateAfterPush();
    }
  } catch (err) {
    useSyncStore.setState({
      status: "error",
      lastError: err instanceof Error ? err.message : "push failed",
    });
  }
}

async function invalidateAfterPush(): Promise<void> {
  for (const prefix of [
    "/calendars",
    "/courses",
    "/recurring-schedules",
    "/todos",
    "/todo-blocks",
    "/tags",
    "/todo-categories",
    "/calendar/events",
    "/free-slots",
  ]) {
    await dropCachePrefix(prefix);
  }
  // Dispatch a window event so TanStack Query caches are invalidated anywhere.
  window.dispatchEvent(new CustomEvent("cp:data-changed"));
}

export async function getLastCursor(): Promise<number> {
  const v = await db.meta.get(SYNC_CURSOR_KEY);
  return typeof v?.value === "number" ? (v.value as number) : 0;
}

export function toSyncOp(op: PendingOp): {
  operationId: string;
  entityType: string;
  entityId: string;
  operation: SyncOpKind;
  baseRevision: number;
  changes: Record<string, unknown>;
} {
  return {
    operationId: op.operationId,
    entityType: op.entityType,
    entityId: op.entityId,
    operation: op.operation,
    baseRevision: op.baseRevision,
    changes: op.changes,
  };
}

// ---- offline-write helper ----------------------------------------------------

export type WriteOutcome =
  | { ok: true; source: "server" }
  | { ok: true; source: "queued" }
  | { ok: false; error: unknown };

export interface OfflineWriteParams {
  entityType: SyncEntityType;
  entityId: string;
  operation: SyncOpKind;
  baseRevision: number;
  changes: Record<string, unknown>;
  context?: Record<string, unknown>;
  /** Online fast-path: try this first. Must throw a TypeError (network) to queue. */
  tryRest: () => Promise<unknown>;
}

/**
 * Hybrid write path: online mutations go straight to the validated REST API;
 * on network failure the operation is durably queued (Dexie) and the pusher
 * replays it via /sync/push when connectivity returns.
 */
export async function offlineWrite(params: OfflineWriteParams): Promise<WriteOutcome> {
  const online = typeof navigator === "undefined" ? true : navigator.onLine;
  if (online) {
    try {
      await params.tryRest();
      return { ok: true, source: "server" };
    } catch (err) {
      if (!isNetworkError(err)) return { ok: false, error: err };
      // fall through to queue
    }
  }
  await db.pendingOps.add({
    operationId: crypto.randomUUID(),
    entityType: params.entityType,
    entityId: params.entityId,
    operation: params.operation,
    baseRevision: params.baseRevision,
    changes: params.changes,
    createdAt: Date.now(),
    ...(params.context ? { context: params.context } : {}),
  });
  useSyncStore.getState().setPendingCount(await countPendingOps());
  // Replay soon after.
  if (navigator.onLine) {
    setTimeout(() => void pushPendingOps(), 500);
  }
  return { ok: true, source: "queued" };
}

function isNetworkError(err: unknown): boolean {
  return err instanceof TypeError; // fetch failed / network unreachable
}

export type { PendingOp };
