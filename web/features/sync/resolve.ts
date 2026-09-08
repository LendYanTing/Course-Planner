/**
 * Conflict resolution (docs/sync-protocol.md §12): the first release offers
 * "keep local" (re-apply the change through the validated REST API, overwriting
 * the server value) and "keep cloud" (drop the local operation and refetch).
 */

import { api } from "@/lib/api/http";
import type { SyncConflict } from "@/generated/entities";
import { useSyncStore, type SyncConflictRecord } from "@/features/sync/sync-store";

function parentId(
  record: SyncConflictRecord,
  field: string
): string | undefined {
  const c = record.conflict;
  const server = c.server;
  if (server && !("missing" in server) && !("deleted" in server) && !("error" in server)) {
    const v = (server as Record<string, unknown>)[field];
    if (typeof v === "string") return v;
  }
  const l = c.local;
  if (l && typeof l[field] === "string") return l[field] as string;
  return undefined;
}

function restPathFor(record: SyncConflictRecord): string | null {
  const c = record.conflict;
  const base = (op: string, ...rest: string[]) =>
    `/${op}/${c.entityId}${rest.length ? `/${rest.join("/")}` : ""}`;
  switch (c.entityType) {
    case "todo":
      return base("todos");
    case "todo_block":
      return base("todo-blocks");
    case "course":
      return base("courses");
    case "recurring_schedule":
      return base("recurring-schedules");
    case "academic_calendar":
      return base("calendars");
    case "tag":
      return base("tags");
    case "todo_category":
      return base("todo-categories");
    case "course_meeting": {
      const courseId = parentId(record, "courseId");
      return courseId ? `/courses/${courseId}/meetings/${c.entityId}` : null;
    }
    case "period_template": {
      const calendarId = parentId(record, "calendarId");
      return calendarId ? `/calendars/${calendarId}/periods/${c.entityId}` : null;
    }
    default:
      return null;
  }
}

/** Re-apply the local change through REST (overwrites the server value). */
export async function resolveKeepLocal(
  record: SyncConflictRecord
): Promise<string | null> {
  const c = record.conflict;
  const path = restPathFor(record);
  if (!path) return `Cannot resolve ${c.entityType} (missing parent id)`;
  const isDelete = record.operation === "delete";
  const local = c.local ?? {};
  try {
    if (isDelete) {
      await api.del(path);
    } else if (record.operation === "create") {
      // Re-create through the REST create endpoint (path minus trailing id).
      await api.post(path.replace(/\/[^/]+$/, ""), local);
    } else {
      await api.patch(path, local);
    }
    dismiss(record);
    return null;
  } catch (err) {
    return err instanceof Error ? err.message : "Resolution failed";
  }
}

/** Accept the cloud value: drop the queued change and refetch. */
export async function resolveKeepServer(
  record: SyncConflictRecord
): Promise<void> {
  dismiss(record);
  window.dispatchEvent(new CustomEvent("cp:data-changed"));
}

export function dismiss(record: SyncConflictRecord): void {
  useSyncStore.getState().dismissConflict(record.conflict.operationId);
}

export function conflictEntityLabel(entityType: string): string {
  const map: Record<string, string> = {
    todo: "Todo",
    todo_block: "Todo block",
    course: "Course",
    course_meeting: "Course meeting",
    recurring_schedule: "Recurring schedule",
    academic_calendar: "Calendar",
    period_template: "Period",
    tag: "Tag",
    todo_category: "Category",
    occurrence_override: "Override",
  };
  return map[entityType] ?? entityType;
}

export function describeConflict(c: SyncConflict, operation?: string): string {
  const fields = c.conflictingFields?.length
    ? c.conflictingFields.join(", ")
    : operation ?? "changed";
  const opLabel: Record<string, string> = {
    create: "created",
    update: "edited",
    delete: "deleted",
  };
  const op = operation ? opLabel[operation] ?? operation : "changed";
  return `${conflictEntityLabel(c.entityType)} ${op} (${fields})`;
}
