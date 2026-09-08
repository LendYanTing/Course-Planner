/**
 * Local persistence (Dexie/IndexedDB).
 *
 * Layout per docs/project-tree.md "db/": the cloud server is the authoritative
 * source; the local DB keeps (a) a durable pending-operation queue for offline
 * writes, (b) an entity REST cache so previously loaded ranges/lists render
 * offline, (c) tiny meta state (sync cursor, sync status). Derived UI state is
 * kept out of here so hard refresh can drop caches without losing queued ops
 * (docs/architecture.md §9).
 */

import Dexie, { type Table } from "dexie";
import type { SyncEntityType, SyncOpKind } from "@/generated/entities";

export type EntityChange = Record<string, unknown>;

export interface PendingOp {
  id?: number;
  operationId: string; // uuid idempotency key (docs/sync-protocol.md §6)
  entityType: SyncEntityType;
  entityId: string;
  operation: SyncOpKind;
  baseRevision: number; // 0 for create
  changes: EntityChange;
  createdAt: number; // epoch ms
  /** parent/route context needed by REST replay (e.g. courseId, calendarId) */
  context?: Record<string, unknown>;
}

export interface RestCacheRow {
  key: string; // canonical query key (method + path + params)
  value: unknown;
  fetchedAt: number;
}

export interface MetaRow {
  key: string;
  value: unknown;
}

class CPDatabase extends Dexie {
  pendingOps!: Table<PendingOp, number>;
  restCache!: Table<RestCacheRow, string>;
  meta!: Table<MetaRow, string>;

  constructor() {
    super("course-planner-web");
    this.version(1).stores({
      meta: "key",
      pendingOps: "++id, createdAt, entityType, entityId, operation",
      restCache: "key",
    });
  }
}

export const db = new CPDatabase();

// ---- meta helpers ------------------------------------------------------------

export async function getMeta<T>(key: string): Promise<T | undefined> {
  const row = await db.meta.get(key);
  return row?.value as T | undefined;
}

export async function setMeta(key: string, value: unknown): Promise<void> {
  await db.meta.put({ key, value });
}

// ---- cache helpers -----------------------------------------------------------

export async function readRestCache<T>(key: string): Promise<T | undefined> {
  const row = await db.restCache.get(key);
  return row?.value as T | undefined;
}

export async function writeRestCache(key: string, value: unknown): Promise<void> {
  await db.restCache.put({ key, value, fetchedAt: Date.now() });
}

/** Drop the derived/cache tables. Never touches pendingOps or meta cursors. */
export async function clearDerivedCache(): Promise<void> {
  await db.restCache.clear();
}

export function cacheKey(method: string, path: string, query?: Record<string, unknown>): string {
  const q = query
    ? Object.entries(query)
        .filter(([, v]) => v !== undefined && v !== null)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([k, v]) => `${k}=${String(v)}`)
        .join("&")
    : "";
  return `${method} ${path}${q ? `?${q}` : ""}`;
}

/** Drop every cache row belonging to a path prefix (post-write invalidation). */
export async function dropCachePrefix(prefix: string): Promise<void> {
  await db.restCache
    .filter((row) => row.key.startsWith(prefix))
    .delete();
}
