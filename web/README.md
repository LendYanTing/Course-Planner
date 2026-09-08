# Course Planner — Web

Next.js (App Router) + TypeScript + Tailwind CSS client for the Course Planner
system. Shared design baseline and API contract live in the repo root
(`README.md`, `docs/`, `docs/openapi.yaml`).

## Stack

- Next.js 16 (App Router), React 19, TypeScript
- Tailwind CSS v4 + shadcn/ui-style components (`components/ui`)
- TanStack Query (server reads), Zustand (session/clock/sync state)
- Dexie / IndexedDB: pending-operation queue + REST cache for offline reads
- Custom typed transport (`lib/api/http.ts`): Bearer token in memory only,
  silent single-flight refresh via the HttpOnly `cp_refresh_token` cookie
- All date/time handled in the immutable per-user IANA timezone from `/me`
  (never the device timezone) — see `lib/time/tz.ts`

## Scripts

```bash
npm install
npm run dev        # http://localhost:3000 (proxies /api -> API_PROXY_TARGET, default 127.0.0.1:8080)
npm run typecheck  # tsc --noEmit
npm run lint
npm run gen:api    # openapi-typescript ../docs/openapi.yaml -o generated/api.ts
npm run build
```

Run the backend first (`server/README.md`): Postgres on 5433, API on 8080.

## Pages

`/login`, `/register`, `/week`, `/month`, `/todos`, `/settings`,
`/import/courses`.

- Week view: continuous 24h axis (CSS-positioned events), 7 day columns,
  current-time line driven by the server clock offset, course/recurring
  layers, todo-block overlay + deadline markers, conflict textures,
  drag/move/resize with period / 5-minute / free snapping, occurrence edits
  with explicit scope (仅这一次 / 这一次及以后 / 整个系列).
- Month view: one range query per displayed month, grouped per local day,
  high-visibility deadline marks.
- Todos: one_off / project, tags & categories (create on the fly), projects
  get deadline + estimated duration + schedulable time blocks.
- Offline: every write is queued first (Dexie), optimistic UI, background
  push via `/sync/push` (operationId idempotent); conflicts open one dialog
  with “keep local / keep cloud”; hard refresh clears derived caches but never
  the pending queue (`settings → Sync & local data`).

Wire-shape notes for structured fields that `docs/openapi.yaml` leaves open
(`weekRule`, recurrence `rule`, series `operation`, sync payloads) are pinned
in `web-docs/api-wire-reference.md` and mirrored in `generated/entities.ts`.
