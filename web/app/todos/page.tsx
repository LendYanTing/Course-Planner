"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { CalendarClock, CheckCircle2, Circle, Plus } from "lucide-react";
import { AuthedPage } from "@/components/authed-page";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Checkbox } from "@/components/ui/checkbox";
import { cn } from "@/lib/utils";
import type { Todo } from "@/generated/entities";
import { useTodos, invalidateTodos } from "@/features/todos/hooks";
import { useTags, useCategories } from "@/features/tags/hooks";
import { TodoEditor } from "@/features/todos/todo-editor";
import { createTodo, updateTodo } from "@/features/todos/api";
import { PRIORITY_META, STATUS_META } from "@/features/todos/meta";
import { useTimezone } from "@/features/todos/use-timezone";
import { toLocalInputValue } from "@/lib/time/datetime-input";
import { useServerNow } from "@/features/time/clock";

type Filter = "all" | "open" | "completed";

export default function TodosPage() {
  const qc = useQueryClient();
  const tz = useTimezone();
  const now = useServerNow(60_000);
  const todosQuery = useTodos();
  const tagsQuery = useTags();
  const categoriesQuery = useCategories();

  const [filter, setFilter] = React.useState<Filter>("open");
  const [selectedId, setSelectedId] = React.useState<string | null>(null);
  const [creating, setCreating] = React.useState(false);
  const [quickTitle, setQuickTitle] = React.useState("");

  const todos = todosQuery.data ?? [];
  const tags = tagsQuery.data ?? [];
  const categories = categoriesQuery.data ?? [];

  const selected = todos.find((t) => t.id === selectedId) ?? null;

  const quickAdd = useMutation({
    mutationFn: (title: string) => createTodo({ title }),
    onSuccess: async (created) => {
      setQuickTitle("");
      await invalidateTodos(qc);
      setSelectedId(created.id);
      setCreating(false);
      toast.success("Todo created");
    },
    onError: (err) => toast.error(err instanceof Error ? err.message : "Failed"),
  });

  const filtered = React.useMemo(() => {
    const sorted = [...todos].sort((a, b) => {
      const pa = PRIORITY_META[a.priority]?.order ?? 0;
      const pb = PRIORITY_META[b.priority]?.order ?? 0;
      if (pa !== pb) return pb - pa;
      return (b.deadlineAt ?? "").localeCompare(a.deadlineAt ?? "") || a.createdAt.localeCompare(b.createdAt);
    });
    if (filter === "all") return sorted;
    if (filter === "completed") return sorted.filter((t) => t.status === "completed");
    return sorted.filter((t) => t.status === "todo" || t.status === "in_progress");
  }, [todos, filter]);

  async function toggleStatus(t: Todo) {
    const next = t.status === "completed" ? "todo" : "completed";
    try {
      await updateTodo(t.id, { status: next, baseRevision: t.revision });
      await invalidateTodos(qc);
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Update failed");
    }
  }

  const counts = React.useMemo(
    () => ({
      all: todos.length,
      open: todos.filter((t) => t.status === "todo" || t.status === "in_progress").length,
      completed: todos.filter((t) => t.status === "completed").length,
    }),
    [todos]
  );

  return (
    <AuthedPage>
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="flex h-12 shrink-0 items-center gap-2 border-b px-4">
          <h1 className="text-sm font-semibold">Todos</h1>
          <div className="ml-4 flex items-center gap-1">
            {(
              [
                ["open", `Open (${counts.open})`],
                ["all", `All (${counts.all})`],
                ["completed", `Done (${counts.completed})`],
              ] as [Filter, string][]
            ).map(([f, label]) => (
              <button
                key={f}
                type="button"
                onClick={() => setFilter(f)}
                className={cn(
                  "rounded-md px-2.5 py-1 text-xs",
                  filter === f ? "bg-accent font-medium text-foreground" : "text-muted-foreground"
                )}
              >
                {label}
              </button>
            ))}
          </div>
          <div className="flex-1" />
          <Button size="sm" onClick={() => { setCreating(true); setSelectedId(null); }}>
            <Plus /> New todo
          </Button>
        </div>

        <div className="grid min-h-0 flex-1 grid-cols-1 md:grid-cols-[minmax(0,1fr)_380px]">
          {/* List */}
          <div className="flex min-h-0 flex-col overflow-y-auto border-r">
            <div className="flex gap-2 border-b p-3">
              <Input
                placeholder="Quick add…"
                value={quickTitle}
                onChange={(e) => setQuickTitle(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" && quickTitle.trim()) quickAdd.mutate(quickTitle.trim());
                }}
              />
              <Button
                variant="outline"
                size="icon"
                disabled={!quickTitle.trim() || quickAdd.isPending}
                onClick={() => quickAdd.mutate(quickTitle.trim())}
              >
                <Plus />
              </Button>
            </div>
            {filtered.length === 0 ? (
              <p className="p-6 text-sm text-muted-foreground">
                {todosQuery.isLoading ? "Loading…" : "Nothing here. Add a todo above."}
              </p>
            ) : (
              filtered.map((t) => (
                <button
                  key={t.id}
                  type="button"
                  onClick={() => { setSelectedId(t.id); setCreating(false); }}
                  className={cn(
                    "flex items-center gap-2 border-b px-3 py-2 text-left hover:bg-accent/50",
                    selectedId === t.id && "bg-accent"
                  )}
                >
                  <span
                    onClick={(e) => {
                      e.stopPropagation();
                      void toggleStatus(t);
                    }}
                    onKeyDown={(e) => {
                      if (e.key === "Enter") { e.stopPropagation(); void toggleStatus(t); }
                    }}
                    role="checkbox"
                    aria-checked={t.status === "completed"}
                    tabIndex={0}
                  >
                    <Checkbox
                      checked={t.status === "completed"}
                      className={cn(t.status === "completed" && "bg-todo")}
                    />
                  </span>
                  <div className="min-w-0 flex-1">
                    <p
                      className={cn(
                        "truncate text-sm",
                        t.status === "completed" && "text-muted-foreground line-through"
                      )}
                    >
                      {t.title}
                    </p>
                    <div className="mt-0.5 flex flex-wrap items-center gap-1.5">
                      <Badge variant="outline">{t.type}</Badge>
                      <span
                        className="h-2 w-2 rounded-full"
                        style={{ background: PRIORITY_META[t.priority]?.dot ?? "var(--muted-foreground)" }}
                        title={`Priority: ${t.priority}`}
                      />
                      {t.deadlineAt && (
                        <span
                          className={cn(
                            "inline-flex items-center gap-0.5 text-[11px]",
                            new Date(t.deadlineAt).getTime() < now.getTime() && t.status !== "completed"
                              ? "font-semibold text-destructive"
                              : "text-muted-foreground"
                          )}
                        >
                          <CalendarClock className="h-3 w-3" />
                          {toLocalInputValue(t.deadlineAt, tz).slice(0, 10)}
                        </span>
                      )}
                      {t.tagIds.length > 0 && (
                        <span className="text-[11px] text-muted-foreground">
                          {t.tagIds.length} tag{t.tagIds.length > 1 ? "s" : ""}
                        </span>
                      )}
                      <span className="text-[11px] text-muted-foreground">
                        {STATUS_META[t.status]?.label ?? t.status}
                      </span>
                    </div>
                  </div>
                </button>
              ))
            )}
          </div>

          {/* Editor */}
          <div className="flex min-h-0 flex-col border-t md:border-t-0">
            {creating || selected ? (
              <TodoEditor
                key={selected?.id ?? "new"}
                todo={creating ? null : selected}
                tags={tags}
                categories={categories}
                onSaved={(saved) => {
                  setCreating(false);
                  setSelectedId(saved?.id ?? null);
                }}
              />
            ) : (
              <div className="flex flex-1 items-center justify-center p-6 text-center text-sm text-muted-foreground">
                <div>
                  <CheckCircle2 className="mx-auto mb-2 h-8 w-8 text-muted-foreground/50" />
                  Select a todo to edit it, or press “New todo”.
                  <div className="mt-2 flex justify-center gap-3">
                    <span className="inline-flex items-center gap-1"><Circle className="h-2.5 w-2.5 text-todo" /> projects get time blocks</span>
                  </div>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </AuthedPage>
  );
}
