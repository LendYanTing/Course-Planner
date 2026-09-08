import { api } from "@/lib/api/http";
import type {
  Todo,
  TodoBlock,
  TodoBlockConflict,
  TodoBlockCreatePayload,
  TodoCreatePayload,
  Uuid,
} from "@/generated/entities";

export interface TodoListQuery {
  status?: string;
  categoryId?: Uuid;
  type?: string;
  tagIds?: string;
}

export async function listTodos(query: TodoListQuery = {}): Promise<Todo[]> {
  return api.get<Todo[]>("/todos", {
    query: query as Record<string, string>,
  });
}

export async function createTodo(payload: TodoCreatePayload): Promise<Todo> {
  return api.post<Todo>("/todos", payload);
}

export async function getTodo(id: Uuid): Promise<Todo> {
  return api.get<Todo>(`/todos/${id}`);
}

export async function updateTodo(
  id: Uuid,
  patch: Partial<TodoCreatePayload> & { baseRevision?: number }
): Promise<Todo> {
  return api.patch<Todo>(`/todos/${id}`, patch);
}

export async function deleteTodo(id: Uuid): Promise<void> {
  return api.del(`/todos/${id}`);
}

// ---- blocks -------------------------------------------------------------------

export async function listTodoBlocks(todoId: Uuid): Promise<TodoBlock[]> {
  return api.get<TodoBlock[]>(`/todos/${todoId}/blocks`);
}

export async function createTodoBlock(
  todoId: Uuid,
  payload: TodoBlockCreatePayload
): Promise<TodoBlockConflict> {
  return api.post<TodoBlockConflict>(`/todos/${todoId}/blocks`, payload);
}

export async function updateTodoBlock(
  blockId: Uuid,
  patch: Partial<{
    startAt: string;
    endAt: string;
    blockNote: string | null;
    status: string;
    baseRevision: number;
  }>
): Promise<TodoBlockConflict> {
  return api.patch<TodoBlockConflict>(`/todo-blocks/${blockId}`, patch);
}

export async function deleteTodoBlock(blockId: Uuid): Promise<void> {
  return api.del(`/todo-blocks/${blockId}`);
}
