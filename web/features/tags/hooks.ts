import { useQueryClient } from "@tanstack/react-query";
import { cacheKey, dropCachePrefix } from "@/db/db";
import type { Tag, TodoCategory } from "@/generated/entities";
import { useApiQuery } from "@/lib/api/hooks";
import { listTags, listCategories } from "@/features/tags/api";

export function useTags() {
  return useApiQuery<Tag[]>({
    queryKey: ["tags"],
    cacheKey: cacheKey("GET", "/tags"),
    fetcher: () => listTags(),
  });
}

export function useCategories() {
  return useApiQuery<TodoCategory[]>({
    queryKey: ["categories"],
    cacheKey: cacheKey("GET", "/todo-categories"),
    fetcher: () => listCategories(),
  });
}

export async function invalidateTagsCategories(
  qc: ReturnType<typeof useQueryClient>
) {
  await dropCachePrefix("/tags");
  await dropCachePrefix("/todo-categories");
  await qc.invalidateQueries({ queryKey: ["tags"] });
  await qc.invalidateQueries({ queryKey: ["categories"] });
}
