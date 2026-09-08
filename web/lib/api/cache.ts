/**
 * Query cache helper: try the network, fall back to the Dexie REST cache so
 * previously loaded data stays readable offline (docs/architecture.md §2, §9).
 */
import { db, readRestCache, writeRestCache } from "@/db/db";

export async function networkWithCacheFallback<T>(
  key: string,
  fetcher: () => Promise<T>
): Promise<T> {
  try {
    const data = await fetcher();
    // Persist the snapshot for offline reads (fire and forget, never fatal).
    void writeRestCache(key, data).catch(() => {});
    return data;
  } catch (err) {
    const cached = await readRestCache<T>(key);
    if (cached !== undefined) return cached;
    throw err;
  }
}

/** Refresh a stored cache row in place when a newer snapshot arrives. */
export async function primeCache(key: string, value: unknown): Promise<void> {
  await db.restCache.put({ key, value, fetchedAt: Date.now() });
}
