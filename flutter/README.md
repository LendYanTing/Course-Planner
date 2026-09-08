# Course Planner — Flutter client

Flutter client of Course Planner (see repository `README.md`). Contract source
of truth is `docs/openapi.yaml`; behavior follows `docs/*.md` and
`agents/flutter-agent.md`.

## Stack

Flutter · Dart · Riverpod (3) · Dio · Drift/SQLite · go_router ·
flutter_secure_storage · timezone (IANA, bundled)

## Layout (docs/project-tree.md)

```text
lib/
  app/        app bootstrap, router, theme
  core/       config, errors, time (fixed user tz), small utils
  domain/     typed entities mirroring the API payloads (calendar, course,
              schedule, todo, override, event, sync wire models)
  data/
    api/      Dio transport + endpoint clients (spec-mirroring)
    auth/     secure token storage
    db/       Drift schema (app_database.dart → generated)
    local/    offline mirror, pending ops, conflicts, view models
    repo/     local-first mutation entry points
  presentation/  pages: week / month / todo / settings(+import/conflicts)
  state/      riverpod providers (session, sync coordinator, snapshot)
  sync/       server clock, occurrence expander, sync engine
```

## Key design decisions

- **Local-first, single source of truth.** The SQLite DB is an offline working
  copy of the server (never a second truth). Every mutation writes the local
  mirror + appends a pending operation; the UI renders immediately; the sync
  engine pushes in the background (pull → push → pull per cycle).
- **Timezone.** All rendering and input interpretation goes through the fixed
  IANA user timezone from the server. `DateTime.now().timeZoneOffset` is never
  used to interpret schedule data. Current-time uses the server clock offset
  (`/meta/time`) and only the now-line ticker rebuilds per minute.
- **Weeks/months offline.** Courses, recurring schedules and their occurrence
  overrides are stored as entities; week/month grids are projected locally
  (`lib/sync/expander.dart` mirrors the server's event service), so offline
  views behave identically.
- **Occurrence edits of course/recurring series** are server-owned
  (`POST /series/.../apply`, which creates overrides/splits server-side).
  Overrides are not pushable through `/sync/push`, so such edits require a
  connection; todo-block edits are pure local entity updates and work offline.
- **API client.** `docs/openapi.yaml` is the only contract; endpoint clients
  in `lib/data/api` mirror its paths/operationIds 1:1. No Flutter OpenAPI
  generator is wired yet (see `scripts/generate-api.sh` placeholder); if one
  is adopted later it must regenerate from the same yaml.
- **CSV import** deliberately sends the raw text to the server
  (`/import/courses/preview` → confirm → `/import/courses/commit`); clients
  never re-implement the parser.

## Dev commands (Windows)

The Flutter SDK used during development lives at `.tools/flutter` (a writable
copy of the toolchain) with `PUB_CACHE=.tools/pub-cache` — both are
gitignored.

```powershell
$env:PUB_CACHE = (Resolve-Path .tools/pub-cache)
.tools\flutter\bin\flutter.bat pub get
.tools\flutter\bin\flutter.bat analyze
# host VM tests load sqlite3.dll from PATH (sqlite3 3.x auto-loader)
$env:PATH = (Resolve-Path .tools/sqlite3).Path + ';' + $env:PATH
.tools\flutter\bin\flutter.bat test
```

Point the app at a running backend with:

```powershell
.tools\flutter\bin\flutter.bat run -d windows `
  --dart-define=API_BASE_URL=http://127.0.0.1:8080/api/v1
```

## Status / next steps

Implemented: auth (login/register/refresh/logout/me), session resume + secure
storage, sync engine (pull/push, cursor, conflicts, hard refresh), todo CRUD
with tags/categories/priority/status/deadline, todo blocks, week view
(7×24 grid, events, deadline/now lines, drag-to-move with snap + cross-midnight
guard, create-block-on-tap, edit sheets), month view (whole-range projection,
per-day index, deadline markers), settings (sync state, semesters/periods,
courses/meetings, recurring schedules, tags/categories), course CSV import,
conflict resolution UI.

Deferred to follow-ups: 凌晨/午休/夜间 folding in week view, top/bottom resize
handles (resize via editor today), drag of course occurrences while fully
offline (server-owned series edits), pure-Dart drift schema tests
(tables covered by widget tests in later rounds).
