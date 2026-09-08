import { api } from "@/lib/api/http";
import type { Tag, TodoCategory, Uuid } from "@/generated/entities";

export async function listTags(): Promise<Tag[]> {
  return api.get<Tag[]>("/tags");
}

export async function createTag(payload: { name: string; color?: string | null }): Promise<Tag> {
  return api.post<Tag>("/tags", payload);
}

export async function updateTag(
  id: Uuid,
  patch: Partial<{ name: string; color: string | null }>
): Promise<Tag> {
  return api.patch<Tag>(`/tags/${id}`, patch);
}

export async function deleteTag(id: Uuid): Promise<void> {
  return api.del(`/tags/${id}`);
}

export async function listCategories(): Promise<TodoCategory[]> {
  return api.get<TodoCategory[]>("/todo-categories");
}

export async function createCategory(payload: { name: string; color?: string | null }): Promise<TodoCategory> {
  return api.post<TodoCategory>("/todo-categories", payload);
}

export async function updateCategory(
  id: Uuid,
  patch: Partial<{ name: string; color: string | null }>
): Promise<TodoCategory> {
  return api.patch<TodoCategory>(`/todo-categories/${id}`, patch);
}

export async function deleteCategory(id: Uuid): Promise<void> {
  return api.del(`/todo-categories/${id}`);
}
