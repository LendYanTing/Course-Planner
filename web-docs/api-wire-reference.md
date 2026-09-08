# API Wire Reference — exact wire contract from server implementation

Base path: `/api/v1` (source: `server/internal/app/routes.go:69`).
Every endpoint below requires `Authorization: Bearer <access-token>` except `/auth/*`, `/meta/time`, `/healthz`.
All absolute datetimes are RFC3339 UTC; instant strings with an offset are accepted and normalized to UTC, zoneless datetimes are rejected (source: `server/internal/common/timeutil/timeutil.go:44-53`).
All IDs are UUID strings (uuid v4). JSON bodies > 4 MiB are rejected; empty bodies are rejected unless noted (`server/internal/platform/httpx/httpx.go:17-98`).

## Envelope

- Success single / list: `{"data": <value>}`. There is NO `pagination` key on list endpoints (docs/api.md §2 shows one — not implemented; only `/sync/changes` carries `nextCursor`/`hasMore` inside its data).
- Create (POST) responses: HTTP 201; other reads/updates: 200; DELETE: 204 no body.
- Error: `{"error": {"code": string, "message": string, "details"?: object}}` — `details` is omitted when nil (`server/internal/platform/httpx/httpx.go:26-64`). Client must branch on `error.code` only.

Sources: `server/internal/platform/httpx/httpx.go:26-64`, `server/internal/app/routes.go:49-200`.

---

## 0. Conventions for structured/typed fields

- Nullable string/int fields (`teacher`, `color`, `notes`, `description`, `categoryId`, `blockNote`, `estimatedMinutes`, …) are keys that serialize to JSON `null` when the pointer is nil — keys are always present in snapshots (the snapshot is a `map[string]any`, never `omitempty` except on tombstones metadata). Exception: rule sub-object fields use `omitempty` (see §8).
- `weekRule` JSON: an ARRAY of segments, each `{"start": int, "end": int, "parity": "all"|"odd"|"even"}` (`server/internal/common/weekrule/weekrule.go:25-29`). On requests both a bare array and a `{"segments": [...]}` wrapper are accepted; responses are always a bare array (`weekrule.go:36-51`). Parity meaning: weeks within `[start,end]` inclusive where week 1 = first week (from calendar `firstDay`), `odd` = every odd week, `even` = every even week. Server normalizes empty parity `""` to `"all"`.
- Timestamps in snapshots are strings formatted with `time.RFC3339` (no fractional seconds), e.g. `2026-09-07T00:00:00Z`. Only the agent `/changes/preview` `expiresAt` is a raw `time.Time` marshaled by `encoding/json` (RFC3339, may carry fractional seconds) — see §14.
- Weekday numbering: ISO, Monday = 1 … Sunday = 7 everywhere (`server/internal/common/timeutil/timeutil.go:169-184`, `server/migrations/0001_init.sql:113`).
- Academic week of a local date w.r.t. calendar: week 1 starts at `firstDay`; week `w` Monday = `firstDay + (w-1)*7 days` (`server/internal/calendar/service.go:202-228`); date→week helper used by the server (series splits) is `diffDays(firstDay, date)/7 + 1` (`server/internal/series/service.go:716-725`). There is no API that computes "the current semester week" from today.

---

## 1. Common date/time and rule parsing semantics (shared)

Source: `server/internal/common/timeutil/timeutil.go`, `server/internal/common/weekrule/weekrule.go`.

- `ParseInstant`: regex `^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$`, then `time.RFC3339`; returns UTC.
- Civil date strings: `YYYY-MM-DD`; wall-clock: `HH:MM` (00:00–23:59). Never interpreted in server-local zone.
- "No cross-midnight" rule (`CheckSameLocalDay`, timeutil.go:211-221): `end` must be strictly after `start` AND both must fall on the same civil date in the USER's timezone, else `CROSS_MIDNIGHT_NOT_ALLOWED`.
- Week-rule validation: at least one segment; each `start >= 1`, `end >= start`, range length ≤ 200, `parity ∈ {all,odd,even}` ("" → all). Expansion clamps/dedupes against `totalWeeks`.
- CSV week-syntax parser (docs/csv-import.md): tokens like `1-16`, `2、5、8`, `1-5、7-11单、12-16双`; separators `、` `，` `,` and spaces; trailing `单`=odd, `双`=even (`weekrule.go:190-244`).

---

## 2. Auth

Source: `server/internal/auth/handlers.go`, `server/internal/auth/password.go`, `server/internal/auth/tokens.go`, `server/internal/user/user.go`.

### POST /auth/register → 201
```json
// request
{ "username": "string (3-32, [A-Za-z0-9_-])",
  "email": "string|null (optional, <=254, must contain '@')",
  "password": "string (8-512)",
  "timezone": "IANA zone, locked forever; INVALID_TIMEZONE (400) when bad" }
```
Response `data` = user DTO (below) + session fields:
```json
{ "id": "uuid", "username": "string", "email": "string|null", "timezone": "string",
  "createdAt": "RFC3339", "updatedAt": "RFC3339",
  "accessToken": "JWT", "expiresIn": "int seconds", "refreshToken": "string" }
```
Also sets HttpOnly cookie `cp_refresh_token`, Path `/api/v1/auth`, HttpOnly, Secure per config, SameSite=Lax.

Duplicate username → 409 with code `VALIDATION_ERROR` and `details.fields.username`.

### POST /auth/login → 200
```json
{ "username": "string", "password": "string" }
```
Response identical to register's. Bad credentials → 401 `UNAUTHORIZED`.

### POST /auth/refresh → 200
Body optional: `{"refreshToken": "string"}` (or empty body; token read from cookie `cp_refresh_token`). Rotation: presented token is revoked; response is a fresh session (same shape as register/login, new cookie).

### POST /auth/logout → 204
Body optional `{"refreshToken": "string"}` or cookie; revokes token, clears cookie at Path `/api/v1`.

### GET /me → 200
`data` = user DTO (id/username/email/timezone/createdAt/updatedAt). No timezone-change API exists.

---

## 3. Meta

`GET /meta/time` → 200 `{"data": {"serverTimeUtc": "RFC3339"}}` (source: `server/internal/app/routes.go:77-81`).

---

## 4. Academic Calendars  (`/calendars`, `/calendars/{calendarId}`)

Sources: `server/internal/calendar/handlers.go:17-86`, `service.go:26-94`, `repo.go:18-176`.

### POST /calendars → 201
```json
{ "name": "string 1-100", "firstDay": "YYYY-MM-DD", "totalWeeks": "int 1-60" }
```
### GET /calendars → 200 (ordered by firstDay, then createdAt)
### GET /calendars/{calendarId} → 200
### PATCH /calendars/{calendarId} → 200
```json
{ "name"?: "string 1-100", "firstDay"?: "YYYY-MM-DD", "totalWeeks"?: "int 1-60",
  "baseRevision"?: "int >= 1 (optimistic lock; omitted = last-write-wins)" }
```
Missing/non-UUID id or foreign owner → 404 `NOT_FOUND`. Revision mismatch → 409 `STALE_REVISION` (`details: {entityType, currentRevision, baseRevision}`). Empty body allowed — but every successful PATCH always runs `UPDATE ... revision = revision + 1` and journals a change, so even a "no-op" PATCH bumps the revision (same for courses, meetings, todos, blocks, schedules).
### DELETE /calendars/{calendarId} → 204 — cascade tombstones every period, course, meeting (+ their overrides) of the calendar, each journaled.

Calendar snapshot (all responses):
```json
{ "id": "uuid", "name": "string", "firstDay": "YYYY-MM-DD", "totalWeeks": "int",
  "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339",
  "deletedAt"?: "RFC3339 (only on tombstones in sync payloads)" }
```

## 5. Period Templates  (`/calendars/{calendarId}/periods`, `.../periods/{periodId}`)

Sources: `server/internal/calendar/handlers.go:90-151`, `service.go:98-191`, `repo.go:293-389`.

### POST /calendars/{calendarId}/periods → 201
```json
{ "periodNo": "int 1-30 (unique per calendar)", "startLocal": "HH:MM", "endLocal": "HH:MM" }
```
Rules: `endLocal > startLocal`; both `< 24:00` ⇒ no cross-midnight by construction. Bad shape → 422 `VALIDATION_ERROR`.
### GET /calendars/{calendarId}/periods → 200 (ordered by periodNo)
### PATCH /calendars/{calendarId}/periods/{periodId} → 200
```json
{ "periodNo"?: "int 1-30", "startLocal"?: "HH:MM", "endLocal"?: "HH:MM",
  "baseRevision"?: "int" }
```
### DELETE /calendars/{calendarId}/periods/{periodId} → 204

Period snapshot: `{id, calendarId, periodNo, startLocal, endLocal, revision, createdAt, updatedAt, deletedAt?}`.

---

## 6. Courses  (`/courses`, `/courses/{courseId}`)

Sources: `server/internal/course/handlers.go:17-123`, `service.go:42-140`, `repo.go:34-51,93-215`.

### POST /courses → 201
```json
{ "calendarId": "uuid (must exist, owned by user)",
  "name": "string 1-100",
  "teacher"?: "string|null", "location"?: "string|null", "color"?: "string|null", "notes"?: "string|null",
  "meetings"?: [ { "weekday": "int 1-7", "periodStart": "int", "periodEnd": "int",
                   "weekRule": "array|{segments:[...]} of {start,end,parity}" } ] }
```
Validation (422 VALIDATION_ERROR): weekday 1-7; `periodStart >= 1`, `periodEnd >= periodStart`; both period numbers must exist in the calendar's template; every segment `end <= calendar.totalWeeks`; weekRule non-empty. Course-vs-course hard conflicts → 409 `COURSE_CONFLICT` (message contains clashing meeting id or name). Also intra-request batch conflicts are rejected.
Response = course snapshot + (when at least one meeting was created) `"meetings": [ meeting snapshot ]`.
### GET /courses?calendarId=uuid → 200 list of course snapshots; without query param: all courses of the user (ordered by created_at; with param ordered by name). No meetings embedded.
### GET /courses/{courseId} → 200
Course snapshot + ALWAYS `"meetings": [ ... ]` (possibly `[]`) — meetings ordered weekday, periodStart.
### PATCH /courses/{courseId} → 200
```json
{ "name"?: "string 1-100", "teacher"?: "string|null", "location"?: "string|null",
  "color"?: "string|null", "notes"?: "string|null", "baseRevision"?: "int" }
```
### DELETE /courses/{courseId} → 204 — tombstones the course, its meetings and their overrides (journaled per entity).

Course snapshot:
```json
{ "id": "uuid", "calendarId": "uuid", "name": "string",
  "teacher": "string|null", "location": "string|null", "color": "string|null", "notes": "string|null",
  "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339", "deletedAt"?: "RFC3339" }
```

## 7. Course Meetings  (`/courses/{courseId}/meetings`, `.../meetings/{meetingId}`)

Sources: `server/internal/course/handlers.go:127-204`, `service.go:144-253`, `repo.go:53-85,219-365`.

### POST /courses/{courseId}/meetings → 201
```json
{ "weekday": "int 1-7", "periodStart": "int", "periodEnd": "int",
  "weekRule": "[{start,end,parity}] | {segments:[...]}" }
```
Hard-conflict check against all other meetings of the same calendar → 409 `COURSE_CONFLICT`.
### GET /courses/{courseId}/meetings → 200 (ordered weekday, periodStart)
### PATCH /courses/{courseId}/meetings/{meetingId} → 200
```json
{ "weekday"?: "int 1-7", "periodStart"?: "int", "periodEnd"?: "int",
  "weekRule"?: "[{start,end,parity}]", "baseRevision"?: "int" }
```
### DELETE /courses/{courseId}/meetings/{meetingId} → 204 (also tombstones its overrides)

Meeting snapshot:
```json
{ "id": "uuid", "courseId": "uuid", "weekday": "int", "periodStart": "int", "periodEnd": "int",
  "weekRule": [ { "start": "int", "end": "int", "parity": "all|odd|even" } ],
  "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339", "deletedAt"?: "RFC3339" }
```

---

## 8. Recurring Schedules  (`/recurring-schedules`, `/recurring-schedules/{scheduleId}`)

Sources: `server/internal/schedule/handlers.go:15-98`, `schedule.go:25-173,325-450` (service + repo in same file).

### POST /recurring-schedules → 201
```json
{ "title": "string 1-100", "color"?: "string|null", "notes"?: "string|null", "rule": { ... } }
```
### GET /recurring-schedules → 200 (ordered createdAt)
### GET /recurring-schedules/{scheduleId} → 200
### PATCH /recurring-schedules/{scheduleId} → 200
```json
{ "title"?: "string 1-100", "color"?: "string|null", "notes"?: "string|null",
  "rule"?: { ... }, "baseRevision"?: "int" }
```
### DELETE /recurring-schedules/{scheduleId} → 204 (also tombstones its overrides)

### `rule` JSONB encoding — exact keys (source `server/internal/schedule/schedule.go:39-50`; omitempty applied)
```json
{ "kind": "daily | weekly | by_academic_week",   // required
  "dateStart"?: "YYYY-MM-DD",                    // required for daily & weekly
  "dateEnd"?: "YYYY-MM-DD",                      // required for daily & weekly
  "startLocal"?: "HH:MM", "endLocal"?: "HH:MM",  // daily/weekly: required; by_academic_week: alt to periods
  "weekdays"?: [ "int 1-7" ],                    // weekly & by_academic_week (>=1, no dupes)
  "calendarId"?: "uuid",                         // by_academic_week only
  "weekRule"?: [ {"start","end","parity"} ],     // by_academic_week only (array)
  "periodStart"?: "int", "periodEnd"?: "int" }   // by_academic_week alt to explicit times
```
Semantics per kind (`schedule.go:52-140` for validation, 528-592 for expansion):
- `daily`: every civil date in `[dateStart,dateEnd]` at `startLocal..endLocal` (local → UTC in the user tz).
- `weekly`: same date range, only on listed ISO weekdays.
- `by_academic_week`: for each weekday × each week matched by `weekRule` (clamped to `calendar.totalWeeks`), date computed from `calendarId`'s `firstDay`; time from `periodStart..periodEnd` (calendar template) or `startLocal..endLocal`. Mixing periods and explicit times is invalid; `periodEnd >= periodStart`; period numbers must exist in the template; segment `end` must be ≤ calendar weeks.
- Validation errors are 422 `VALIDATION_ERROR`; note `endLocal <= startLocal` in the daily/weekly base rule yields `CROSS_MIDNIGHT_NOT_ALLOWED` (422).
- Expansion max: date range is capped at 366 days per rule.

Recurring schedule snapshot:
```json
{ "id": "uuid", "title": "string", "color": "string|null", "rule": { ...above... },
  "notes": "string|null", "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339",
  "deletedAt"?: "RFC3339" }
```
Response `rule` echoes the exact stored JSON (empty optional keys omitted).

---

## 9. Todos  (`/todos`, `/todos/{todoId}`)

Sources: `server/internal/todo/handlers.go:36-131`, `service.go:47-107`, `todo.go:22-101,166-298,501-519`.

### POST /todos → 201
```json
{ "title": "string 1-200 (required)",
  "type"?: "one_off | project",            // default one_off
  "description"?: "string|null", "categoryId"?: "uuid|null",
  "tagIds"?: [ "uuid" ],                   // default []
  "priority"?: "low | normal | high | urgent",   // default normal
  "status"?: "todo | in_progress | completed | cancelled", // default todo
  "estimatedMinutes"?: "int|null", "color"?: "string|null",
  "deadlineAt"?: "RFC3339|null" }
```
Invalid enums → 422 VALIDATION_ERROR.
### GET /todos → 200; query filters (all optional, combinable): `status`, `categoryId`, `type`, `tagIds` (comma-separated). Ordered `created_at DESC`.
### GET /todos/{todoId} → 200
### PATCH /todos/{todoId} → 200 — body is a JSON object parsed as raw map; recognized keys:
`title`, `type`, `description` (string|null), `categoryId` (uuid|null), `tagIds` (array|null), `priority`, `status`, `color` (string|null), `estimatedMinutes` (int|null), `deadlineAt` (RFC3339|null — `null` clears), `baseRevision`. Unknown keys ignored; missing/`null` on scalar keys are treated as "not provided" (so `null` does NOT clear scalars such as `title`; use explicit value). Empty body allowed.
### DELETE /todos/{todoId} → 204 (tombstones todo + its blocks)

Todo snapshot (DTO; `tagIds` is always `[]` when empty; `deadlineAt` key always present, `null` when unset):
```json
{ "id": "uuid", "title": "string", "type": "one_off|project",
  "description": "string|null", "categoryId": "uuid|null", "tagIds": ["uuid"],
  "priority": "low|normal|high|urgent", "status": "todo|in_progress|completed|cancelled",
  "estimatedMinutes": "int|null", "color": "string|null",
  "deadlineAt": "RFC3339|null", "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339",
  "deletedAt"?: "RFC3339" }
```

## 10. Todo Blocks  (`/todos/{todoId}/blocks`, `/todo-blocks/{blockId}`)

Sources: `server/internal/todo/handlers.go:135-209`, `service.go:111-204`, `todo.go:103-135,317-425,521-523`.

### POST /todos/{todoId}/blocks → 201
```json
{ "startAt": "RFC3339", "endAt": "RFC3339", "blockNote"?: "string|null",
  "status"?: "scheduled | in_progress | completed | skipped" }   // default scheduled
```
Validation: same local day in the user's timezone (else `CROSS_MIDNIGHT_NOT_ALLOWED`), `end > start`; invalid status → 422.
Response = block snapshot + extra key `"conflictState": "none" | "soft_conflict"` (soft conflict = overlaps any course occurrence in the user tz, computed server-side).
### GET /todos/{todoId}/blocks → 200 (ordered startAt; no conflictState in list items)
### PATCH /todo-blocks/{blockId} → 200 — raw-map body; keys: `startAt` (RFC3339), `endAt` (RFC3339), `blockNote` (string|null), `status`, `baseRevision`. `null` for startAt/endAt is ignored (cannot be cleared). Response includes `conflictState`.
### DELETE /todo-blocks/{blockId} → 204

Block snapshot:
```json
{ "id": "uuid", "todoId": "uuid", "startAt": "RFC3339", "endAt": "RFC3339",
  "blockNote": "string|null", "status": "scheduled|in_progress|completed|skipped",
  "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339", "deletedAt"?: "RFC3339" }
```

---

## 11. Series Editing  (`POST /series/{seriesType}/{seriesId}/apply`)

Sources: `server/internal/series/handlers.go:18-118`, `service.go:31-118,94-118,120-711`, `server/internal/override/override.go:18-27`.

- `{seriesType}` ∈ `course_meeting` | `recurring_schedule` (path; anything else → 422).
- Body (all keys used):
```json
{ "scope": "THIS | THIS_AND_FUTURE | ALL",     // required
  "occurrenceDateLocal"?: "YYYY-MM-DD",        // required for THIS / THIS_AND_FUTURE
  "operation": {                                // required object
    "type": "MOVE | UPDATE | CANCEL | DELETE", // required
    "startAt"?: "RFC3339", "endAt"?: "RFC3339",// MOVE + THIS only (replacement window)
    "startLocal"?: "HH:MM", "endLocal"?: "HH:MM", // recurring split/ALL time patches
    "periodStart"?: "int", "periodEnd"?: "int", // course-like period patches (split/ALL)
    "weekday"?: "int 1-7",                      // course_meeting patch (split/ALL)
    "weekRule"?: "[{start,end,parity}]",        // course_meeting tail replacement (split/ALL)
    "patch"?: { "title"?: "string", "teacher"?: "string", "location"?: "string",
                "color"?: "string", "notes"?: "string" },   // metadata patch (UPDATE, THIS); only string values are honored, other keys dropped
    "force"?: "bool" }                          // skip hard-conflict check (course only)
}
```
Semantics (see service.go comments):
- **THIS** → creates/updates an occurrence override row keyed `(seriesId, occurrenceDateLocal)`:
  - MOVE: requires startAt/endAt (same local day), hard-conflict checked vs other course meetings unless `force`; override `action: "move"`.
  - UPDATE: requires non-empty patch → override `action: "update"` (metadata only, no time change).
  - CANCEL / DELETE: identical → override `action: "cancel"`.
- **THIS_AND_FUTURE** → split: old series truncated to before the occurrence week/date; a NEW series (new uuid) takes over from the occurrence onward; future overrides (date >= occurrenceDateLocal) are repointed to the tail. CANCEL/DELETE truncates with no tail (old series deleted when nothing remains).
  - course_meeting tail patch: `weekday`, `periodStart/periodEnd`, optional full `weekRule` replacement; periods validated against the calendar; hard conflicts vs other meetings unless `force`.
  - recurring tail patch: `startLocal/endLocal` or `periodStart/periodEnd`, `patch.title/color/notes`.
- **ALL** → edits/deletes the whole series definition (course_meeting: `weekday`/`periods`/`weekRule`; recurring: `startLocal/endLocal`/`periods` or `patch.title/color/notes`); CANCEL and DELETE both delete the whole series (`series_delete`).
- Occurrence-membership checks: course_meeting — the date must fall in a week ≤ totalWeeks, weekRule must match the week, and weekday must equal meeting weekday, else 422 (`"no occurrence of this series on that date"`). recurring_schedule daily/weekly — date within [dateStart,dateEnd] and (weekly) weekday in list; by_academic_week — weekday in list only (week-rule coverage of the date is NOT checked).
- ⚠ recurring_schedule + scope ALL still runs the occurrence-membership check against `occurrenceDateLocal`; with an empty date every ALL request is rejected 422 ("date is outside the schedule range" / date parse error). For recurring ALL, pass an `occurrenceDateLocal` that lies inside the rule (it is then ignored by the ALL logic). course_meeting ALL does not need the date.

Response 200:
```json
{ "data": { "kind": "override | split | series_update | series_delete",
            "oldSeriesId": "uuid", "newSeriesId": "uuid|null",
            "override": { /* occurrence_override snapshot, null when kind != override */ } } }
```
Override snapshot:
```json
{ "id": "uuid", "seriesType": "course_meeting|recurring_schedule", "seriesId": "uuid",
  "occurrenceDateLocal": "YYYY-MM-DD", "action": "move|update|cancel",
  "replacementStartAt": "RFC3339|null", "replacementEndAt": "RFC3339|null",
  "metadata": "object|null", "revision": "int", "createdAt": "RFC3339", "updatedAt": "RFC3339",
  "deletedAt"?: "RFC3339" }
```

---

## 12. Calendar Events  (`GET /calendar/events`)

Sources: `server/internal/event/handlers.go:16-64`, `server/internal/event/event.go:23-245`.

Query params (all optional):
```
start=<UTC RFC3339>          required
end=<UTC RFC3339>            required, after start, span <= 62 days (else 422)
includeCourses=true|false            default true   (any value except exactly "false" => true)
includeRecurringSchedules=...        default true
includeTodoBlocks=...                default true
includeDeadlines=...                 default true
```
Response 200 `{"data": [Event,...]}` sorted by startAt then id (stable). Event object:
```json
{ "id": "string",                       // "course:<meetingId>:<dateLocal>" | "recurring:<scheduleId>:<dateLocal>"
                                        // | "todo_block:<blockId>" | "deadline:<todoId>"
  "type": "course | recurring_schedule | todo_block | deadline",
  "title": "string",                    // course default fallback "课程"; recurring "" fallback
  "startAt": "RFC3339",
  "endAt": "RFC3339 | null",   // key always present; null ONLY on deadline events, which additionally emit "allDay": false (other event kinds never carry "allDay")
  "source": { "type": "course_meeting | recurring_schedule | todo_block | todo",
              "id": "uuid of the source row" },
  "conflictState": "none | soft_conflict | hard_conflict",
  "metadata": { } }                     // keys depend on type (below)
```
Metadata contents (event.go:138-234):
- course: `courseId, meetingId, teacher(string|null), location(string|null), color(string|null), periodStart(int), periodEnd(int), overridden(bool), week(int — academic week), displayDate("YYYY-MM-DD")`.
- recurring_schedule: `scheduleId, overridden(bool), color(string|null), notes(string|null), displayDate`.
- todo_block: `todoId, blockId, blockNote(string|null), status(block status string), color(string|null from parent todo)`.
- deadline: `todoId, priority(todo priority string), deadlineAt(RFC3339)`.

Conflict computation (event.go:114-236): hard_conflict between two course events of DIFFERENT meetings overlapping in UTC; same meeting never conflicts with itself. recurring_schedule and todo_block events overlapping any course event get `soft_conflict`. Deadline events are always `none`.
Note: course events for a deleted parent todo's blocks are skipped; course occurrences are always expanded server-side even when `includeCourses=false` (they feed the soft/hard logic) but then not emitted.

---

## 13. Free Slots  (`GET /free-slots`)

Sources: `server/internal/freeslot/handlers.go:16-64`, `freeslot.go:60-150`.

Query params: `start` (required RFC3339), `end` (required, after start), `durationMinutes` (int ≥ 1; default 60), `alignment` (`period` | `5_minutes` | `free`; default `period` when absent), `considerCourses`/`considerRecurringSchedules`/`considerTodoBlocks` (default all true; anything except exactly "false" → true). Invalid alignment/duration → 422.

Response 200 `{"data": [ {"startAt": RFC3339, "endAt": RFC3339}, ... ]}` sorted by start.

Semantics:
- Busy = union (merged) of course occurrences ∪ recurring-schedule occurrences ∪ todo blocks. All todo blocks count as busy regardless of block status (`todo/repo.go BlocksInRange` has no status filter), and soft-conflicting sources are busy by default (agent must not fabricate overlaps).
- Alignment: `free` returns raw gaps. `period` and `5_minutes` are currently IDENTICAL — the slot start is snapped UP to the next 5-minute boundary of the user's local clock; the slot END is the raw end of the free gap (not truncated to durationMinutes, not snapped to a period grid — no period-template logic exists). A slot is only emitted if the aligned remainder ≥ durationMinutes.
- No max-range cap on this endpoint (events caps at 62 days).

---

## 14. Tags / Categories

Sources: `server/internal/tag/tag.go`, `tag/handlers.go`; `server/internal/category/category.go`, `category/handlers.go`.

Routes: `GET|POST /tags`, `PATCH|DELETE /tags/{id}`; `GET|POST /todo-categories`, `PATCH|DELETE /todo-categories/{id}`.

```json
// POST body
{ "name": "string 1-50", "color"?: "string|null" }
// PATCH body
{ "name"?: "string 1-50", "color"?: "string|null" }
```
Responses (create 201, patch 200): snapshot `{id, name, color(string|null), revision, createdAt, updatedAt, deletedAt?}`. DELETE → 204.
⚠ No `baseRevision` / optimistic locking on these REST endpoints (update always bumps revision; a concurrent overwrite is silently last-write-wins). Name uniqueness per user enforced in DB (unique partial index); the REST service returns the raw DB error on duplicates → 500 `INTERNAL_ERROR` (no graceful 409).
Category delete leaves `todo.categoryId` dangling — client must treat a missing category as null (category.go:145-146).

---

## 15. CSV Course Import

Sources: `server/internal/importcsv/handlers.go:14-56`, `service.go:41-188`, `parse.go:18-163`.

### POST /import/courses/preview?calendarId=<uuid> — raw body
- `Content-Type: text/csv` or `text/plain` (or empty); anything else → 400. `calendarId` query required.
- Raw UTF-8 CSV (BOM tolerated); body ≤ 4 MiB. Header aliases map to canonical columns: `课程名称/课程名/name/课名`, `星期/周几/weekday/day`, `开始节数/起始节次/开始节次/periodStart`, `结束节数/结束节次/periodEnd`, `老师/教师/teacher`, `地点/教室/location`, `周数/周次/weeks/week`. Unknown column or empty file → 422 `CSV_PARSE_ERROR`.
- Row rules (422 `CSV_VALIDATION_ERROR` with `details.errors` = rows `{line, field, code, message}`): name non-empty & ≤ 100 (`EMPTY_NAME`/`NAME_TOO_LONG`), weekday 1-7 (`BAD_WEEKDAY`), start ≥ 1 and ≤ end (`BAD_PERIOD_RANGE`), week syntax (`BAD_WEEK_RULE`), weeks within 1..totalWeeks (`WEEK_OUT_OF_RANGE`), period numbers defined in the calendar (`PERIOD_NOT_DEFINED` field Chinese header names). Week column may use the CSV syntax in §0; the parsed rule is returned human-readable via `Describe()` with 单/双.
- Hard conflicts (intra-batch and vs existing calendar meetings) → 422 with code `COURSE_CONFLICT` and `details.conflicts` = string list ("line N conflicts with ...").

Success 200:
```json
{ "data": { "previewId": "uuid", "expiresAt": "RFC3339", "calendarId": "uuid",
            "courses": [ { "line": "int", "name": "string", "weekday": "int", "periodStart": "int",
                           "periodEnd": "int", "teacher": "string", "location": "string",
                           "weeks": "string (normalized, e.g. \"1-5、7-11单\")" } ],
            "conflicts": [ "string" ] | null } }
```
### POST /import/courses/commit → 200
```json
{ "previewId": "uuid" }   // NOTE: field is "previewId" — the same value returned as previewId by preview
```
Response: `{"data": {"committed": true, "courses": <int count>}}`.
Unknown/foreign preview → 404; already committed/expired → 410 `CONFIRMATION_EXPIRED`. Conflicts re-checked inside the commit transaction (409 `COURSE_CONFLICT`). Each committed row creates a course + one meeting (weekday/periods/weekRule); a course is created per row even when teacher/location empty (stored as NULL).

---

## 16. Sync

Sources: `server/internal/sync/handlers.go:21-76`, `journal.go:22-186`, `push.go:35-301`.

### GET /sync/state → 200
`{"data": {"serverCursor": "int (0 for a fresh user)"}}`
### GET /sync/changes?after=<int>&limit=<int> → 200
- `after` required (≥ 0 else 422), `limit` optional 1–1000, default 500. Entries with sync_seq > after, ascending.
```json
{ "data": { "changes": [ { "syncSeq": "int", "entityType": "string", "entityId": "uuid",
                           "operation": "create | update | delete", "revision": "int",
                           "payload": { /* full entity snapshot at that revision — same keys as the entity's REST snapshot;
                                          delete payloads additionally contain "deletedAt": RFC3339 */ },
                           "createdAt": "RFC3339" } ],
            "nextCursor": "int (last syncSeq returned; equals `after` when empty)",
            "hasMore": "bool" } }
```
`entityType` strings (journal.go:24-34): `academic_calendar`, `period_template`, `course`, `course_meeting`, `recurring_schedule`, `todo`, `todo_block`, `tag`, `todo_category`, `occurrence_override`.
### POST /sync/push → 200
```json
{ "baseCursor": "int", "operations": [ { "operationId": "uuid (idempotency key)",
      "entityType": "string", "entityId": "uuid", "operation": "create | update | delete",
      "baseRevision": "int (0 for create)", "changes": { ... } } ] }
```
≤ 1000 operations (else 422). Each operation processed in its own transaction; operationId must be a fresh UUID or replay (same operationId returns the stored outcome — a replay of an accepted create does not re-create).
Response:
```json
{ "data": { "accepted": [ "operationId", ... ], "merged": [ "operationId", ... ],
            "conflicts": [ { "operationId": "uuid", "entityType": "string", "entityId": "uuid",
                             "base"?: { },        // pre-image at client's baseRevision (3-way)
                             "local"?: { },       // client changes
                             "server"?: { },      // current server snapshot; or {"deleted":true,"revision":N} / {"missing":true} / {"error": code, "message": ...}
                             "conflictingFields"?: [ "field", ... ] } ],
            "serverCursor": "int" } }
```
Create/update/delete semantics (push.go:184-301):
- create: entity must be missing; client-supplied entityId used. If live and `changes` equal the snapshot (ignoring revision/timestamps) → replay `accepted`; else conflict (diff of client fields).
- update: if server revision == baseRevision → direct apply → `accepted`. Otherwise 3-way merge vs the journaled snapshot at baseRevision: fields the client changed that the server did not touch are patched (`merged`); fields both sides changed → `conflict` listing `conflictingFields`; nothing to do → `merged`. Nested values compare by canonical JSON (any nested change conflicts the whole field).
- delete: on missing/tombstoned entity → idempotent `accepted`; else tombstone.
- Validation-style failures during execution are recorded as deterministic conflicts (`conflicts[].server = {error: code, message}`).

Supported push `entityType` (adapters registered in `server/internal/app/app.go:127-135`): `todo`, `todo_block`, `tag`, `todo_category`, `academic_calendar`, `period_template`, `course`, `course_meeting`, `recurring_schedule`. NOTE: `occurrence_override` is journaled server-side but has NO push adapter — pushing it returns 422 "unsupported entity type".

Fields accepted per create/update push (subset per adapter; unknown keys ignored or error per field decoder):
- academic_calendar create: `name` (or `title` accepted alias) + `firstDay` + `totalWeeks`; update: `name`, `firstDay`, `totalWeeks` (calendar/syncadapter.go:122-157).
- period_template create: `calendarId`, `periodNo`, `startLocal`, `endLocal`; update: `periodNo`, `startLocal`, `endLocal` (calendar/syncadapter.go:221-281).
- course create: `calendarId`, `name`, `teacher?`, `location?`, `color?`, `notes?`; update: same optional. NO hard-conflict check on push create (course/syncadapter.go:46-98).
- course_meeting create: `courseId`, `weekday`, `periodStart`, `periodEnd`, `weekRule`; update same. Period-in-template and calendar-week bounds are NOT checked on push (only 1-7 / order / non-empty rule) (course/syncadapter.go:144-242).
- recurring_schedule create: `title`, `rule`, `color?`, `notes?`; update: `title`, `color`, `notes`, `rule` (rule shape-validated only; calendar cross-check NOT performed on push) (schedule/syncadapter.go:46-104).
- todo create: `title`, `type` (default one_off), `description?`, `categoryId?`, `tagIds?`, `priority` (default normal), `status` (default todo), `estimatedMinutes?`, `color?`, `deadlineAt?` (RFC3339 string); update: same keys; explicit `null` values clear nullable fields; deadline `null` clears (todo/syncadapter.go:163-296).
- todo_block create: `todoId`, `startAt`, `endAt`, `blockNote?`, `status` (default scheduled); cross-midnight validated in user tz; update: `startAt`, `endAt`, `blockNote`, `status` (todo/syncadapter.go:298-372).
- tag / todo_category create: `name`, `color?`; update: `name`, `color` (tag/syncadapter.go:51-108, category/syncadapter.go:50-107).

---

## 17. Agent change sets  (`/agent/changes/preview`, `/agent/changes/apply`)

Sources: `server/internal/agent/handlers.go:15-46`, `changeset.go:22-51,63-206,210-267`.

### POST /agent/changes/preview → 200
```json
{ "changes": [ { "operation": "create | update | delete",   // required
                 "entityType": "string",                    // required; see list
                 "entityId"?: "uuid",                       // required for update/delete; optional for create (server assigns)
                 "payload"?: { } } ] }                      // fields same as /sync/push create/update `changes`; delete ignores it
```
Constraints: 1–50 changes (else 422); supported entityType ∈ {todo, todo_block, course, recurring_schedule, tag, todo_category, academic_calendar, period_template, course_meeting} (NOT occurrence_override); create on an existing entity → 409 `SYNC_CONFLICT`; update/delete on a missing one → 404.
Preview executes everything in a rolled-back transaction and stores the resolved set.

Response 200:
```json
{ "data": { "confirmationId": "uuid", "expiresAt": "RFC3339 (Go time.Time JSON; may carry fractional seconds)",
            "summary": [ "human-readable Chinese line per change" ],
            "changes": [ { "operation": "create|update|delete", "entityType": "string",
                           "entityId": "uuid", "description": "string",
                           "conflictState": "none | soft_conflict (todo_block vs course only)",
                           "snapshot"?: { } } ] } }   // snapshot omitted for deletes? -> deletes include snapshot {"deleted":true}
```
### POST /agent/changes/apply → 200
```json
{ "confirmationId": "uuid" }
```
Stored set re-executed atomically; single-use (status → applied). Unknown/used/expired → 410 `CONFIRMATION_EXPIRED`.
Response: `{"data": {"applied": true, "changes": [ same Effect objects as preview ]}}`.

---

## 18. Error codes (exact)

Source: `server/internal/common/apperr/apperr.go:13-31,72-149`.

| code | HTTP | notes |
|---|---|---|
| `INVALID_REQUEST` | 400 | malformed/oversized/empty-when-required JSON, CSV content-type |
| `UNAUTHORIZED` | 401 | missing/invalid bearer or refresh |
| `FORBIDDEN` | 403 | constant exists; never raised by current handlers |
| `NOT_FOUND` | 404 | entity missing/foreign/bad uuid (404 keeps ownership opaque) |
| `VALIDATION_ERROR` | 422 | `details.fields` = {field: message} |
| `INVALID_TIMEZONE` | 400 | |
| `CROSS_MIDNIGHT_NOT_ALLOWED` | 422 | |
| `SCHEDULE_CONFLICT` | 409 | convenience exists; never raised today |
| `COURSE_CONFLICT` | 409 | REST course/meeting/series; 422 inside CSV preview conflict errors |
| `STALE_REVISION` | 409 | `details {entityType, currentRevision, baseRevision}` |
| `SYNC_CONFLICT` | 409 | push/agent (create on live entity, update on deleted) |
| `DUPLICATE_OPERATION` | — | constant exists; never raised (idempotency is silent replay) |
| `CSV_PARSE_ERROR` | 422 | |
| `CSV_VALIDATION_ERROR` | 422 | `details.errors` rows |
| `CONFIRMATION_REQUIRED` | — | constant exists; never raised |
| `CONFIRMATION_EXPIRED` | 410 | import commit / agent apply / re-commit |
| `INTERNAL_ERROR` | 500 | unhandled errors only |

Unexpected (non-app) errors always map to 500 `INTERNAL_ERROR` (httpx.go:52-64).

---

## 19. Environment / config

Source: `server/internal/platform/config/config.go:32-84` and `server/internal/auth/handlers.go:19,199-224`.

| env var | default | notes |
|---|---|---|
| `PORT` | `8080` | |
| `DATABASE_URL` | — | required (startup fails otherwise) |
| `JWT_SECRET` | — | required, ≥ 16 bytes (startup fails otherwise) |
| `ACCESS_TOKEN_TTL` | `15m` | Go duration or integer seconds |
| `REFRESH_TOKEN_TTL` | `720h` (30d) | |
| `CONFIRMATION_TTL` | `10m` | agent change sets + import previews |
| `COOKIE_SECURE` | `true` | set `false` for plain-HTTP dev |
| `CORS_ALLOWED_ORIGINS` | unset (no CORS middleware) | comma-separated |
| `LOG_LEVEL` | `info` | |
| `TEST_MODE` | off | `1` to enable |

Refresh cookie: name `cp_refresh_token`; set at Path `/api/v1/auth` (auth/handlers.go:210-218); cleared at Path `/api/v1` on logout (handlers.go:183). Access token = HS256 JWT, claims `{sub, iat, exp, typ:"access"}` (tokens.go:32-42).

## 20. Schema / sync-tracked tables

Source: `server/migrations/0001_init.sql`.

Tables: `users`, `refresh_tokens`, `sync_states`, `sync_changes`, `sync_operations`, `academic_calendars`, `period_templates`, `courses`, `course_meetings`, `recurring_schedules`, `todo_categories`, `todos`, `todo_blocks`, `tags`, `occurrence_overrides`, `agent_change_sets`, `import_previews`, `auth_events`.

- `users`: id (uuid), username (unique), email, password_hash, timezone, created_at, updated_at. Not sync-tracked.
- Sync-tracked entities (carry `revision` + `deleted_at`): academic_calendars, period_templates, courses, course_meetings, recurring_schedules, todo_categories, todos, todo_blocks, tags, occurrence_overrides. `sync_changes.entity_type` strings in §16. Tombstones are never GC'd.
- `sync_states`: (user_id PK → users, current_seq bigint, updated_at).
- DB-level CHECKs worth knowing: `todo_blocks.end_at > start_at`; meeting/calendar weekday/period/parity bounds; `occurrence_overrides.action IN (move,update,cancel)`; unique `(series_id, occurrence_date_local)` for overrides; unique `(user_id, name)` for tags and categories (live rows).

---

## Quick reference: mismatch/“watch out” list (server vs docs)

1. Response `weekRule`/`metadata` etc. exact shapes above; docs/openapi.yaml marks `weekRule`, `rule`, `operation` and several payloads as `additionalProperties: true` — this file pins them.
2. List endpoints return bare `{"data":[...]}` — no `pagination` envelope (docs/api.md §2 claims one).
3. `/import/courses/commit` body uses `previewId`; some docs/tests also call it a “preview token”.
4. No server-side `Idempotency-Key` handling exists — the header is only CORS-whitelisted. Idempotency for writes lives in `/sync/push` operationId.
5. `conflictState` on events: course events may be `hard_conflict`; recurring_schedule and todo_block only ever `none|soft_conflict`.
6. Course event `source.type` is `course_meeting` (not `course`), and event `metadata` has no `weekday` field (week is in `week`).
7. Free-slots `alignment=period` is currently identical to `5_minutes` (no period-grid snap; only 5-min start snap).
8. recurring_schedule scope `ALL` requires a passing `occurrenceDateLocal`.
9. tag/category REST PATCH: no optimistic locking; duplicate-name conflict surfaces as 500.
10. Push/agent creates bypass domain conflict/calendar checks that REST enforces.
