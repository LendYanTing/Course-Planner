/**
 * Course Planner web entity types.
 *
 * The shared contract is docs/openapi.yaml; several response bodies and
 * structured fields (weekRule, recurrence `rule`, series `operation`, sync
 * payloads) are left untyped there ("additionalProperties"). These types pin
 * them to the exact wire shape implemented by the Go server, cross-checked in
 * `web-docs/api-wire-reference.md` (per-file source citations). Any drift
 * between the server and this file is a bug in this file or the server, and
 * should be resolved by updating docs/openapi.yaml first (repo README change
 * order), then regenerating.
 */

// ---- Common ----------------------------------------------------------------

export type IsoInstant = string; // RFC3339 UTC, e.g. "2026-09-08T01:00:00Z"
export type LocalDate = string; // "YYYY-MM-DD" civil date in the user's timezone
export type LocalClock = string; // "HH:MM" 00:00-23:59
export type Uuid = string;

export interface ApiErrorBody {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

// ---- Auth / user ------------------------------------------------------------

export interface UserDto {
  id: Uuid;
  username: string;
  email: string | null;
  timezone: string; // IANA; immutable after registration
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
}

export interface SessionDto extends UserDto {
  accessToken: string;
  expiresIn: number; // seconds
  refreshToken: string;
}

// ---- Academic calendar + periods ---------------------------------------------

export interface AcademicCalendar {
  id: Uuid;
  name: string;
  firstDay: LocalDate;
  totalWeeks: number;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export interface PeriodTemplate {
  id: Uuid;
  calendarId: Uuid;
  periodNo: number;
  startLocal: LocalClock;
  endLocal: LocalClock;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

// ---- Courses ----------------------------------------------------------------

export type WeekParity = "all" | "odd" | "even";

/** Bare-array wire form of weekRule (responses always use this). */
export interface WeekSegment {
  start: number;
  end: number;
  parity: WeekParity;
}

export type WeekRule = WeekSegment[];

export interface Course {
  id: Uuid;
  calendarId: Uuid;
  name: string;
  teacher: string | null;
  location: string | null;
  color: string | null;
  notes: string | null;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export interface CourseMeeting {
  id: Uuid;
  courseId: Uuid;
  weekday: number; // ISO: 1 = Monday … 7 = Sunday
  periodStart: number;
  periodEnd: number;
  weekRule: WeekRule;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

// ---- Recurring schedules ------------------------------------------------------

export type RecurringRuleKind = "daily" | "weekly" | "by_academic_week";

/** Stored `rule` JSONB (server echoes exactly what was stored; optional keys omitted). */
export interface RecurringRule {
  kind: RecurringRuleKind;
  // daily & weekly
  dateStart?: LocalDate;
  dateEnd?: LocalDate;
  startLocal?: LocalClock;
  endLocal?: LocalClock;
  weekdays?: number[]; // weekly & by_academic_week, ISO 1..7
  // by_academic_week
  calendarId?: Uuid;
  weekRule?: WeekRule;
  periodStart?: number;
  periodEnd?: number;
}

export interface RecurringSchedule {
  id: Uuid;
  title: string;
  color: string | null;
  rule: RecurringRule;
  notes: string | null;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

// ---- Todos / blocks -----------------------------------------------------------

export type TodoType = "one_off" | "project";
export type TodoPriority = "low" | "normal" | "high" | "urgent";
export type TodoStatus = "todo" | "in_progress" | "completed" | "cancelled";
export type BlockStatus = "scheduled" | "in_progress" | "completed" | "skipped";

export interface Todo {
  id: Uuid;
  title: string;
  type: TodoType;
  description: string | null;
  categoryId: Uuid | null;
  tagIds: Uuid[];
  priority: TodoPriority;
  status: TodoStatus;
  estimatedMinutes: number | null;
  color: string | null;
  deadlineAt: IsoInstant | null;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export interface TodoBlock {
  id: Uuid;
  todoId: Uuid;
  startAt: IsoInstant;
  endAt: IsoInstant;
  blockNote: string | null;
  status: BlockStatus;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export interface TodoBlockConflict extends TodoBlock {
  /** Present on create/update responses: soft conflict vs a course occurrence. */
  conflictState?: "none" | "soft_conflict";
}

// ---- Tags / categories ---------------------------------------------------------

export interface NamedColorEntity {
  id: Uuid;
  name: string;
  color: string | null;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export type Tag = NamedColorEntity;
export type TodoCategory = NamedColorEntity;

// ---- Calendar event projection ---------------------------------------------------

export type CalendarEventType =
  | "course"
  | "recurring_schedule"
  | "todo_block"
  | "deadline";
export type ConflictState = "none" | "soft_conflict" | "hard_conflict";

export interface CalendarEvent {
  id: string;
  type: CalendarEventType;
  title: string;
  startAt: IsoInstant;
  endAt: IsoInstant | null; // null only for deadline events
  allDay?: boolean; // only present on deadline events, always false today
  source: { type: string; id: Uuid };
  conflictState: ConflictState;
  metadata: EventMetadata;
}

export interface CourseEventMetadata {
  courseId: Uuid;
  meetingId: Uuid;
  teacher: string | null;
  location: string | null;
  color: string | null;
  periodStart: number;
  periodEnd: number;
  overridden: boolean;
  week: number; // academic week in the calendar
  displayDate: LocalDate;
  [key: string]: unknown;
}

export interface RecurringEventMetadata {
  scheduleId: Uuid;
  overridden: boolean;
  color: string | null;
  notes: string | null;
  displayDate: LocalDate;
  [key: string]: unknown;
}

export interface TodoBlockEventMetadata {
  todoId: Uuid;
  blockId: Uuid;
  blockNote: string | null;
  status: BlockStatus;
  color: string | null; // parent todo color
  [key: string]: unknown;
}

export interface DeadlineEventMetadata {
  todoId: Uuid;
  priority: TodoPriority;
  deadlineAt: IsoInstant;
  [key: string]: unknown;
}

export type EventMetadata = { [key: string]: unknown };

// ---- Series editing ---------------------------------------------------------------

export type SeriesType = "course_meeting" | "recurring_schedule";
export type SeriesScope = "THIS" | "THIS_AND_FUTURE" | "ALL";
export type SeriesOperationType = "MOVE" | "UPDATE" | "CANCEL" | "DELETE";

export interface SeriesOperation {
  type: SeriesOperationType;
  startAt?: IsoInstant; // MOVE (THIS)
  endAt?: IsoInstant; // MOVE (THIS)
  startLocal?: LocalClock; // recurring tail/ALL time patch
  endLocal?: LocalClock;
  periodStart?: number; // course-like period patch
  periodEnd?: number;
  weekday?: number; // course_meeting patch
  weekRule?: WeekRule; // course_meeting tail replacement
  patch?: {
    title?: string;
    teacher?: string;
    location?: string;
    color?: string;
    notes?: string;
  };
  force?: boolean; // skip hard-conflict check (course only)
}

export interface SeriesApplyRequest {
  scope: SeriesScope;
  occurrenceDateLocal?: LocalDate;
  operation: SeriesOperation;
}

export interface OccurrenceOverride {
  id: Uuid;
  seriesType: SeriesType;
  seriesId: Uuid;
  occurrenceDateLocal: LocalDate;
  action: "move" | "update" | "cancel";
  replacementStartAt: IsoInstant | null;
  replacementEndAt: IsoInstant | null;
  metadata: Record<string, unknown> | null;
  revision: number;
  createdAt: IsoInstant;
  updatedAt: IsoInstant;
  deletedAt?: IsoInstant;
}

export interface SeriesApplyResult {
  kind: "override" | "split" | "series_update" | "series_delete";
  oldSeriesId: Uuid;
  newSeriesId: Uuid | null;
  override: OccurrenceOverride | null;
}

// ---- Free slots -------------------------------------------------------------------

export type SlotAlignment = "period" | "5_minutes" | "free";

export interface FreeSlot {
  startAt: IsoInstant;
  endAt: IsoInstant;
}

// ---- Sync ------------------------------------------------------------------------

export type SyncEntityType =
  | "academic_calendar"
  | "period_template"
  | "course"
  | "course_meeting"
  | "recurring_schedule"
  | "todo"
  | "todo_block"
  | "tag"
  | "todo_category"
  | "occurrence_override";
export type SyncOpKind = "create" | "update" | "delete";

export interface SyncState {
  serverCursor: number;
}

export interface SyncChange {
  syncSeq: number;
  entityType: SyncEntityType;
  entityId: Uuid;
  operation: SyncOpKind;
  revision: number;
  payload: Record<string, unknown> | null;
  createdAt: IsoInstant;
}

export interface SyncChangesData {
  changes: SyncChange[];
  nextCursor: number;
  hasMore: boolean;
}

export interface SyncOperation {
  operationId: Uuid;
  entityType: SyncEntityType;
  entityId: Uuid;
  operation: SyncOpKind;
  baseRevision: number; // 0 for create
  changes: Record<string, unknown>;
}

export interface SyncConflict {
  operationId: Uuid;
  entityType: SyncEntityType;
  entityId: Uuid;
  base?: Record<string, unknown>;
  local?: Record<string, unknown>;
  server?:
    | Record<string, unknown>
    | { deleted: true; revision: number }
    | { missing: true }
    | { error: string; message: string };
  conflictingFields?: string[];
}

export interface SyncPushResult {
  accepted: Uuid[];
  merged: Uuid[];
  conflicts: SyncConflict[];
  serverCursor: number;
}

// ---- CSV import -------------------------------------------------------------------

export interface ImportCourseRow {
  line: number;
  name: string;
  weekday: number;
  periodStart: number;
  periodEnd: number;
  teacher: string;
  location: string;
  weeks: string; // normalized human-readable description
}

export interface ImportPreview {
  previewId: Uuid;
  expiresAt: IsoInstant;
  calendarId: Uuid;
  courses: ImportCourseRow[];
  conflicts: string[] | null;
}

export interface ImportCommitResult {
  committed: boolean;
  courses: number;
}

// ---- Agent change set --------------------------------------------------------------

export interface ChangeSetEntry {
  operation: "create" | "update" | "delete";
  entityType: string;
  entityId?: Uuid;
  payload?: Record<string, unknown>;
}

export interface AgentPreviewChange {
  operation: "create" | "update" | "delete";
  entityType: string;
  entityId: Uuid;
  description: string;
  conflictState: "none" | "soft_conflict";
  snapshot?: Record<string, unknown> | { deleted: true };
}

export interface AgentPreview {
  confirmationId: Uuid;
  expiresAt: IsoInstant;
  summary: string[];
  changes: AgentPreviewChange[];
}

export interface AgentApplyResult {
  applied: boolean;
  changes: AgentPreviewChange[];
}

// ---- Request payloads (REST) ------------------------------------------------------

export interface CalendarCreatePayload {
  name: string;
  firstDay: LocalDate;
  totalWeeks: number;
}

export interface PeriodCreatePayload {
  periodNo: number;
  startLocal: LocalClock;
  endLocal: LocalClock;
}

export interface CourseCreatePayload {
  calendarId: Uuid;
  name: string;
  teacher?: string | null;
  location?: string | null;
  color?: string | null;
  notes?: string | null;
  meetings?: CourseMeetingCreatePayload[];
}

export interface CourseMeetingCreatePayload {
  weekday: number;
  periodStart: number;
  periodEnd: number;
  weekRule: WeekRule | { segments: WeekRule };
}

export interface RecurringScheduleCreatePayload {
  title: string;
  color?: string | null;
  notes?: string | null;
  rule: RecurringRule;
}

export interface TodoCreatePayload {
  title: string;
  type?: TodoType;
  description?: string | null;
  categoryId?: Uuid | null;
  tagIds?: Uuid[];
  priority?: TodoPriority;
  status?: TodoStatus;
  estimatedMinutes?: number | null;
  color?: string | null;
  deadlineAt?: IsoInstant | null;
}

export interface TodoBlockCreatePayload {
  startAt: IsoInstant;
  endAt: IsoInstant;
  blockNote?: string | null;
  status?: BlockStatus;
}

export interface TagCreatePayload {
  name: string;
  color?: string | null;
}
