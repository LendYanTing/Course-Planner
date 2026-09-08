"use client";

import * as React from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { CalendarClock, Loader2, Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Badge } from "@/components/ui/badge";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { cn } from "@/lib/utils";
import type { Tag, Todo, TodoBlock, TodoCategory } from "@/generated/entities";
import { useApiQuery } from "@/lib/api/hooks";
import { cacheKey, dropCachePrefix } from "@/db/db";
import {
  createTodo,
  updateTodo,
  deleteTodo,
  listTodoBlocks,
  createTodoBlock,
  updateTodoBlock,
  deleteTodoBlock,
  type TodoListQuery,
} from "@/features/todos/api";
import { createTag, createCategory } from "@/features/tags/api";
import { useTimezone } from "@/features/todos/use-timezone";
import { PRIORITY_META, STATUS_META, BLOCK_STATUS_META, TODO_TYPE_META } from "@/features/todos/meta";
import { toLocalInputValue, fromLocalInputValue } from "@/lib/time/datetime-input";
import { invalidateTagsCategories } from "@/features/tags/hooks";
import { invalidateTodos } from "@/features/todos/hooks";
import { COLOR_PRESETS } from "@/lib/palette";

export interface TodoEditorProps {
  /** null => create mode */
  todo: Todo | null;
  tags: Tag[];
  categories: TodoCategory[];
  onSaved: (todo: Todo | null) => void;
}

export function TodoEditor({ todo, tags, categories, onSaved }: TodoEditorProps) {
  const qc = useQueryClient();
  const tz = useTimezone();
  const isNew = !todo;

  const [title, setTitle] = React.useState(todo?.title ?? "");
  const [description, setDescription] = React.useState(todo?.description ?? "");
  const [type, setType] = React.useState<Todo["type"]>(todo?.type ?? "one_off");
  const [categoryId, setCategoryId] = React.useState<string>(todo?.categoryId ?? "");
  const [tagIds, setTagIds] = React.useState<string[]>(todo?.tagIds ?? []);
  const [priority, setPriority] = React.useState(todo?.priority ?? "normal");
  const [status, setStatus] = React.useState(todo?.status ?? "todo");
  const [color, setColor] = React.useState(todo?.color ?? "");
  const [estimated, setEstimated] = React.useState(
    todo?.estimatedMinutes != null ? String(todo.estimatedMinutes) : ""
  );
  const [deadline, setDeadline] = React.useState(
    todo?.deadlineAt ? toLocalInputValue(todo.deadlineAt, tz) : ""
  );
  const [newTagName, setNewTagName] = React.useState("");
  const [newCategoryName, setNewCategoryName] = React.useState("");

  const save = useMutation({
    mutationFn: async () => {
      const payload = {
        title: title.trim() || "(untitled)",
        description: description.trim() ? description : null,
        type,
        categoryId: categoryId || null,
        tagIds,
        priority: priority as Todo["priority"],
        status: status as Todo["status"],
        color: color || null,
        estimatedMinutes: estimated === "" ? null : Number(estimated),
        deadlineAt: deadline ? fromLocalInputValue(deadline, tz) : null,
      };
      if (isNew) {
        const created = await createTodo(payload);
        return created;
      }
      return await updateTodo(todo.id, { ...payload, baseRevision: todo.revision });
    },
    onSuccess: async (created) => {
      await invalidateTodos(qc);
      toast.success(isNew ? "Todo created" : "Todo saved");
      onSaved(created);
    },
    onError: (err) => toast.error(err instanceof Error ? err.message : "Save failed"),
  });

  const del = useMutation({
    mutationFn: () => deleteTodo(todo!.id),
    onSuccess: async () => {
      await invalidateTodos(qc);
      toast.success("Todo deleted");
      onSaved(null);
    },
    onError: (err) => toast.error(err instanceof Error ? err.message : "Delete failed"),
  });

  function toggleTag(id: string) {
    setTagIds((cur) => (cur.includes(id) ? cur.filter((x) => x !== id) : [...cur, id]));
  }

  async function addTagNow() {
    const name = newTagName.trim();
    if (!name) return;
    try {
      const t = await createTag({ name });
      await invalidateTagsCategories(qc);
      setTagIds((cur) => [...cur, t.id]);
      setNewTagName("");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Tag create failed");
    }
  }

  async function addCategoryNow() {
    const name = newCategoryName.trim();
    if (!name) return;
    try {
      const c = await createCategory({ name });
      await invalidateTagsCategories(qc);
      setCategoryId(c.id);
      setNewCategoryName("");
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Category create failed");
    }
  }

  const busy = save.isPending || del.isPending;
  const selectedTodo = todo;

  return (
    <div className="flex min-h-0 flex-1 flex-col overflow-y-auto p-4">
      <div className="flex items-center justify-between gap-2">
        <h2 className="text-base font-semibold">
          {isNew ? "New todo" : "Edit todo"}
        </h2>
        {!isNew && (
          <Button
            size="sm"
            variant="destructive"
            disabled={busy}
            onClick={() => del.mutate()}
          >
            <Trash2 /> Delete
          </Button>
        )}
      </div>

      <div className="mt-3 flex flex-col gap-3">
        <div className="flex flex-col gap-1.5">
          <Label>Title</Label>
          <Input
            autoFocus={isNew}
            value={title}
            onChange={(e) => setTitle(e.target.value)}
            placeholder="What needs to be done?"
          />
        </div>

        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <Field label="Type">
            <Select
              value={type}
              onValueChange={(v) => setType(v as Todo["type"])}
            >
              <TriggerField />
              <SelectContent>
                {Object.entries(TODO_TYPE_META).map(([k, m]) => (
                  <SelectItem key={k} value={k}>
                    {m.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <Field label="Priority">
            <Select value={priority} onValueChange={(v) => setPriority(v as Todo["priority"])}>
              <TriggerField />
              <SelectContent>
                {Object.entries(PRIORITY_META).map(([k, m]) => (
                  <SelectItem key={k} value={k}>
                    {m.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          {!isNew && (
            <Field label="Status">
              <Select value={status} onValueChange={(v) => setStatus(v as Todo["status"])}>
                <TriggerField />
                <SelectContent>
                  {Object.entries(STATUS_META).map(([k, m]) => (
                    <SelectItem key={k} value={k}>
                      {m.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          )}
        </div>

        <div className="flex flex-col gap-1.5">
          <Label>Description</Label>
          <Textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={2}
          />
        </div>

        {type === "project" && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Deadline (your timezone)">
              <Input
                type="datetime-local"
                value={deadline}
                onChange={(e) => setDeadline(e.target.value)}
              />
            </Field>
            <Field label="Estimated duration (minutes)">
              <Input
                type="number"
                min={0}
                value={estimated}
                onChange={(e) => setEstimated(e.target.value)}
                placeholder="e.g. 120"
              />
            </Field>
          </div>
        )}

        <Field label="Color">
          <ColorRow value={color} onChange={setColor} />
        </Field>

        <Field label="Category">
          <div className="flex gap-2">
            <Select value={categoryId || "__none__"} onValueChange={(v) => setCategoryId(v === "__none__" ? "" : v)}>
              <TriggerField className="flex-1" />
              <SelectContent>
                <SelectItem value="__none__">None</SelectItem>
                {categories.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Input
              className="w-36"
              placeholder="+ new category"
              value={newCategoryName}
              onChange={(e) => setNewCategoryName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void addCategoryNow();
              }}
            />
            {newCategoryName && (
              <Button variant="outline" size="icon" onClick={() => void addCategoryNow()}>
                <Plus />
              </Button>
            )}
          </div>
        </Field>

        <Field label="Tags">
          <div className="flex flex-wrap items-center gap-1.5">
            {tags.map((t) => (
              <button
                key={t.id}
                type="button"
                onClick={() => toggleTag(t.id)}
                className={cn(
                  "rounded-full border px-2 py-0.5 text-xs",
                  tagIds.includes(t.id)
                    ? "border-primary bg-primary/10 text-primary"
                    : "text-muted-foreground hover:bg-accent"
                )}
              >
                {t.name}
              </button>
            ))}
            <span className="flex items-center gap-1">
              <Input
                className="h-7 w-32 text-xs"
                placeholder="+ tag"
                value={newTagName}
                onChange={(e) => setNewTagName(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") void addTagNow();
                }}
              />
            </span>
          </div>
        </Field>

        {type === "project" && !isNew && (
          <TodoBlocks todoId={todo.id} tz={tz} onChanged={() => void invalidateTodos(qc)} />
        )}
        {type === "one_off" && !isNew && (
          <p className="text-xs text-muted-foreground">
            Tip: switch to “project” to schedule time blocks on the week view.
          </p>
        )}
      </div>

      <div className="mt-4 flex justify-end gap-2">
        <Button
          variant="outline"
          disabled={busy}
          onClick={() => onSaved(todo)}
        >
          {isNew ? "Discard" : "Close"}
        </Button>
        <Button
          disabled={busy || !title.trim()}
          onClick={() => save.mutate()}
        >
          {save.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
          {isNew ? "Create todo" : "Save"}
        </Button>
      </div>
      <span className="hidden">{selectedTodo?.id}</span>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <Label className="text-xs">{label}</Label>
      {children}
    </div>
  );
}

function TriggerField({ className }: { className?: string }) {
  return <SelectTrigger className={className}><SelectValue /></SelectTrigger>;
}

function ColorRow({ value, onChange }: { value: string; onChange: (c: string) => void }) {
  return (
    <div className="flex flex-wrap items-center gap-1.5">
      <button
        type="button"
        onClick={() => onChange("")}
        className={cn(
          "h-6 w-6 rounded-full border text-[10px]",
          !value ? "border-primary ring-2 ring-ring" : "text-muted-foreground"
        )}
        title="No color"
      >
        ∅
      </button>
      {COLOR_PRESETS.map((c) => (
        <button
          key={c}
          type="button"
          onClick={() => onChange(c)}
          className={cn(
            "h-6 w-6 rounded-full border",
            value === c && "ring-2 ring-ring ring-offset-1"
          )}
          style={{ background: c }}
        />
      ))}
    </div>
  );
}

// ---- Todo blocks manager -------------------------------------------------------

function TodoBlocks({
  todoId,
  tz,
  onChanged,
}: {
  todoId: string;
  tz: string;
  onChanged: () => void;
}) {
  const qc = useQueryClient();
  const query = useApiQuery<TodoBlock[]>({
    queryKey: ["todos", todoId, "blocks"],
    cacheKey: cacheKey("GET", `/todos/${todoId}/blocks`),
    fetcher: () => listTodoBlocks(todoId),
  });
  const blocks = query.data ?? [];
  const [editing, setEditing] = React.useState<TodoBlock | "new" | null>(null);

  async function invalidate() {
    await dropCachePrefix("/todos");
    await qc.invalidateQueries({ queryKey: ["todos", todoId, "blocks"] });
    onChanged();
  }

  return (
    <div className="rounded-md border p-3">
      <div className="mb-2 flex items-center justify-between">
        <Label className="text-xs uppercase tracking-wide text-muted-foreground">
          Scheduled blocks
        </Label>
        <Button size="sm" variant="outline" onClick={() => setEditing("new")}>
          <Plus /> Add block
        </Button>
      </div>
      {blocks.length === 0 && (
        <p className="text-xs text-muted-foreground">
          No time blocks yet — drag on the week view to schedule this project.
        </p>
      )}
      <div className="flex flex-col gap-1.5">
        {blocks.map((b) => (
          <div
            key={b.id}
            className="flex items-center justify-between gap-2 rounded border px-2 py-1.5 text-xs"
          >
            <div className="min-w-0">
              <div className="flex items-center gap-2 font-medium">
                <CalendarClock className="h-3 w-3 text-todo" />
                <span>
                  {b.startAt ? prettyLocal(b.startAt, tz) : ""} –{" "}
                  {b.endAt ? prettyLocal(b.endAt, tz) : ""}
                </span>
                <Badge variant="outline">{BLOCK_STATUS_META[b.status]?.label ?? b.status}</Badge>
              </div>
              {b.blockNote && (
                <div className="truncate text-muted-foreground">{b.blockNote}</div>
              )}
            </div>
            <Button size="sm" variant="ghost" onClick={() => setEditing(b)}>
              Edit
            </Button>
          </div>
        ))}
      </div>
      {editing && (
        <BlockDialog
          block={editing === "new" ? null : editing}
          todoId={todoId}
          tz={tz}
          onClose={() => setEditing(null)}
          onSaved={invalidate}
        />
      )}
    </div>
  );
}

function prettyLocal(iso: string, tz: string): string {
  const v = toLocalInputValue(iso, tz);
  const [d, t] = v.split("T");
  const [, mo, day] = d.split("-");
  return `${mo}/${day} ${t}`;
}

// ---- Block create/edit dialog ---------------------------------------------------

export function BlockDialog({
  block,
  todoId,
  tz,
  onClose,
  onSaved,
}: {
  block: TodoBlock | null;
  todoId: string;
  tz: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [start, setStart] = React.useState(
    block ? toLocalInputValue(block.startAt, tz) : ""
  );
  const [end, setEnd] = React.useState(
    block ? toLocalInputValue(block.endAt, tz) : ""
  );
  const [note, setNote] = React.useState(block?.blockNote ?? "");
  const [status, setStatus] = React.useState(block?.status ?? "scheduled");
  const [busy, setBusy] = React.useState(false);

  async function save() {
    setBusy(true);
    try {
      if (block) {
        await updateTodoBlock(block.id, {
          startAt: fromLocalInputValue(start, tz),
          endAt: fromLocalInputValue(end, tz),
          blockNote: note || null,
          status,
          baseRevision: block.revision,
        });
      } else {
        await createTodoBlock(todoId, {
          startAt: fromLocalInputValue(start, tz),
          endAt: fromLocalInputValue(end, tz),
          blockNote: note || null,
        });
      }
      toast.success(block ? "Block saved" : "Block added");
      onClose();
      await onSaved();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Save failed");
    } finally {
      setBusy(false);
    }
  }

  async function remove() {
    if (!block) return;
    setBusy(true);
    try {
      await deleteTodoBlock(block.id);
      toast.success("Block deleted");
      onClose();
      await onSaved();
    } catch (e) {
      toast.error(e instanceof Error ? e.message : "Delete failed");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{block ? "Edit block" : "Add time block"}</DialogTitle>
        </DialogHeader>
        <div className="grid grid-cols-2 gap-3">
          <Field label="Start">
            <Input type="datetime-local" value={start} onChange={(e) => setStart(e.target.value)} />
          </Field>
          <Field label="End">
            <Input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} />
          </Field>
        </div>
        <Field label="Block note (this slot works on…)">
          <Textarea value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
        </Field>
        {block && (
          <Field label="Status">
            <Select
              value={status}
              onValueChange={(v) => setStatus(v as TodoBlock["status"])}
            >
              <TriggerField />
              <SelectContent>
                {Object.entries(BLOCK_STATUS_META).map(([k, m]) => (
                  <SelectItem key={k} value={k}>
                    {m.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
        )}
        <DialogFooter className="flex items-center justify-between">
          {block ? (
            <Button variant="destructive" size="sm" disabled={busy} onClick={() => void remove()}>
              Delete
            </Button>
          ) : (
            <span />
          )}
          <div className="flex gap-2">
            <Button variant="outline" onClick={onClose} disabled={busy}>
              Cancel
            </Button>
            <Button disabled={busy || !start || !end} onClick={() => void save()}>
              {busy && <Loader2 className="h-4 w-4 animate-spin" />} Save
            </Button>
          </div>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

export type { TodoListQuery };
