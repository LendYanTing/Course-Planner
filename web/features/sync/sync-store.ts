"use client";

/**
 * Sync engine status store + pending-op queue API.
 *
 * The write pipeline (docs/web-agent.md "Offline", docs/sync-protocol.md §5):
 *   user action
 *     -> enqueue pending operation (Dexie)
 *     -> optimistic UI (query-cache update done by the caller)
 *     -> background push via /sync/push (operationId idempotent)
 * When online the REST call path is preferred for validation-rich writes and
 * its success drops any identical queued operation; offline writes stay queued
 * and are replayed by the pusher on reconnect.
 */

import { create } from "zustand";
import { db, type PendingOp } from "@/db/db";
import type { SyncConflict, SyncOpKind } from "@/generated/entities";

export type SyncStateStatus =
  | "idle"
  | "syncing"
  | "offline"
  | "conflict"
  | "error";

export interface SyncConflictRecord {
  conflict: SyncConflict;
  createdAt: number;
  /** Operation kind the client attempted (push responses omit it). */
  operation?: SyncOpKind;
}

interface SyncStoreState {
  status: SyncStateStatus;
  online: boolean;
  pendingCount: number;
  conflicts: SyncConflictRecord[];
  lastPushAt: number | null;
  lastError: string | null;
  setOnline: (online: boolean) => void;
  setStatus: (status: SyncStateStatus) => void;
  setPendingCount: (n: number) => void;
  setLastError: (e: string | null) => void;
  addConflict: (conflict: SyncConflict, operation?: SyncOpKind) => void;
  dismissConflict: (operationId: string) => void;
}

export const useSyncStore = create<SyncStoreState>((set) => ({
  status: "idle",
  online: typeof navigator === "undefined" ? true : navigator.onLine,
  pendingCount: 0,
  conflicts: [],
  lastPushAt: null,
  lastError: null,
  setOnline: (online) => set({ online }),
  setStatus: (status) => set({ status }),
  setPendingCount: (pendingCount) => set({ pendingCount }),
  setLastError: (lastError) => set({ lastError }),
  addConflict: (conflict: SyncConflict, operation?: SyncOpKind) =>
    set((s) => ({
      conflicts: [
        { conflict, operation, createdAt: Date.now() },
        ...s.conflicts.filter((c) => c.conflict.operationId !== conflict.operationId),
      ].slice(0, 50),
    })),
  dismissConflict: (operationId) =>
    set((s) => ({
      conflicts: s.conflicts.filter((c) => c.conflict.operationId !== operationId),
    })),
}));

// ---- queue -----------------------------------------------------------------

export async function countPendingOps(): Promise<number> {
  return db.pendingOps.count();
}

export async function enqueuePendingOp(op: PendingOp): Promise<void> {
  await db.pendingOps.add(op);
  useSyncStore.getState().setPendingCount(await countPendingOps());
}

/** Remove a queued op by operationId (after accepted/merged push). */
export async function dropPendingOp(operationId: string): Promise<void> {
  await db.pendingOps.where("operationId").equals(operationId).delete();
  useSyncStore.getState().setPendingCount(await countPendingOps());
}

export async function listPendingOps(): Promise<PendingOp[]> {
  return db.pendingOps.orderBy("createdAt").toArray();
}

/** All operations for one entity (used by conflict resolution). */
export async function pendingOpsForEntity(
  entityType: string,
  entityId: string
): Promise<PendingOp[]> {
  return db.pendingOps
    .filter((o) => o.entityType === entityType && o.entityId === entityId)
    .sortBy("createdAt");
}
