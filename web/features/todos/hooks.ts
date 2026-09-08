import { useQueryClient } from "@tanstack/react-query";
import { cacheKey, dropCachePrefix } from "@/db/db";
import type { Todo, Uuid } from "@/generated/entities";
import { useApiQuery } from "@/lib/api/hooks";
import {
  listTodos,
  type TodoListQuery,
} from "@/features/todos/api";

export const TODO_PREFIX = "/todos";

export function useTodos(filters: TodoListQuery = {}) {
  return useApiQuery<Todo[]>({
    queryKey: ["todos", filters],
    cacheKey: cacheKey("GET", "/todos", filters as Record<string, string>),
    fetcher: () => listTodos(filters),
    staleTime: 15_000,
  });
}

/** Invalidate every todo/blocks query after a mutation. */
export async function invalidateTodos(qc: ReturnType<typeof useQueryClient>) {
  await dropCachePrefix("/todos");
  await qc.invalidateQueries({ queryKey: ["todos"] });
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent("cp:data-changed"));
  }
}

export type { Uuid };
