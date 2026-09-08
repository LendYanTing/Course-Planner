import { useQuery, type UseQueryOptions } from "@tanstack/react-query";
import { networkWithCacheFallback } from "@/lib/api/cache";

export interface ApiQueryOptions<T> {
  queryKey: unknown[];
  /** Canonical Dexie cache key (method + path + params). */
  cacheKey: string;
  fetcher: () => Promise<T>;
  enabled?: boolean;
  staleTime?: number;
}

/** useQuery whose data falls back to the persisted REST cache when offline. */
export function useApiQuery<T>(opts: ApiQueryOptions<T>) {
  return useQuery<T, Error>({
    queryKey: opts.queryKey,
    queryFn: () => networkWithCacheFallback(opts.cacheKey, opts.fetcher),
    enabled: opts.enabled,
    staleTime: opts.staleTime,
  } as UseQueryOptions<T, Error>);
}
