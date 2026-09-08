-- Course Planner initial schema.
--
-- Conventions:
--  * All absolute timestamps are TIMESTAMPTZ (UTC).
--  * Local dates are stored as TEXT 'YYYY-MM-DD'; local wall-clock times as
--    TEXT 'HH:MM' (user-timezone semantics are applied in Go, never in SQL).
--  * All user data rows carry user_id for trivial ownership scoping.
--  * Synced entities carry revision (server-side optimistic concurrency) and
--    deleted_at (tombstone). Rows are soft-deleted so the sync log stays
--    meaningful; tombstones are never garbage-collected in v1.

CREATE TABLE users (
    id            UUID PRIMARY KEY,
    username      TEXT NOT NULL UNIQUE,
    email         TEXT,
    password_hash TEXT NOT NULL,
    timezone      TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE refresh_tokens (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,          -- SHA-256 of the opaque token
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ
);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens (user_id);

-- Per-user monotonic sync sequence. Every persisted change allocates the next
-- sequence value under a row lock on this table.
CREATE TABLE sync_states (
    user_id     UUID PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    current_seq BIGINT NOT NULL DEFAULT 0,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Append-only sync journal. Also doubles as per-entity revision history
-- (needed for three-way merge) and as the tombstone record for deletes.
CREATE TABLE sync_changes (
    user_id     UUID    NOT NULL,
    sync_seq    BIGINT  NOT NULL,
    entity_type TEXT    NOT NULL,
    entity_id   UUID    NOT NULL,
    operation   TEXT    NOT NULL CHECK (operation IN ('create', 'update', 'delete')),
    revision    INT     NOT NULL,
    payload     JSONB   NOT NULL,   -- full API-shaped snapshot at this revision
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, sync_seq)
);
CREATE INDEX idx_sync_changes_entity ON sync_changes (user_id, entity_type, entity_id, revision DESC);

-- Idempotency ledger for pushed client operations.
CREATE TABLE sync_operations (
    user_id      UUID   NOT NULL,
    operation_id UUID   NOT NULL,
    status       TEXT   NOT NULL CHECK (status IN ('processing', 'accepted', 'merged', 'conflict', 'rejected')),
    result       JSONB  NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, operation_id)
);

CREATE TABLE academic_calendars (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    first_day   TEXT NOT NULL CHECK (first_day ~ '^\d{4}-\d{2}-\d{2}$'),   -- local date
    total_weeks INT  NOT NULL CHECK (total_weeks BETWEEN 1 AND 60),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision    INT  NOT NULL DEFAULT 1,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX idx_calendars_user ON academic_calendars (user_id) WHERE deleted_at IS NULL;

CREATE TABLE period_templates (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    calendar_id UUID NOT NULL REFERENCES academic_calendars (id) ON DELETE CASCADE,
    period_no   INT  NOT NULL CHECK (period_no >= 1),
    start_local TEXT NOT NULL CHECK (start_local ~ '^([01]\d|2[0-3]):[0-5]\d$'),
    end_local   TEXT NOT NULL CHECK (end_local ~ '^([01]\d|2[0-3]):[0-5]\d$'),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision    INT  NOT NULL DEFAULT 1,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX idx_periods_calendar ON period_templates (calendar_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_periods_calendar_no ON period_templates (calendar_id, period_no) WHERE deleted_at IS NULL;

CREATE TABLE courses (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    calendar_id UUID NOT NULL REFERENCES academic_calendars (id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    teacher     TEXT,
    location    TEXT,
    color       TEXT,
    notes       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision    INT  NOT NULL DEFAULT 1,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX idx_courses_calendar ON courses (calendar_id) WHERE deleted_at IS NULL;

CREATE TABLE course_meetings (
    id           UUID PRIMARY KEY,
    user_id      UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    course_id    UUID NOT NULL REFERENCES courses (id) ON DELETE CASCADE,
    weekday      INT  NOT NULL CHECK (weekday BETWEEN 1 AND 7),   -- 1=Monday..7=Sunday
    period_start INT  NOT NULL CHECK (period_start >= 1),
    period_end   INT  NOT NULL CHECK (period_end >= 1),
    week_rule    JSONB NOT NULL,    -- [{"start":1,"end":16,"parity":"all"|"odd"|"even"}, ...]
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision     INT  NOT NULL DEFAULT 1,
    deleted_at   TIMESTAMPTZ,
    CHECK (period_end >= period_start)
);
CREATE INDEX idx_meetings_course ON course_meetings (course_id) WHERE deleted_at IS NULL;

CREATE TABLE recurring_schedules (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    title      TEXT NOT NULL,
    color      TEXT,
    rule       JSONB NOT NULL,     -- see internal/schedule.Rule
    notes      TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision   INT  NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ
);
CREATE INDEX idx_recurring_user ON recurring_schedules (user_id) WHERE deleted_at IS NULL;

CREATE TABLE todo_categories (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    color      TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision   INT  NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_todo_categories_user_name ON todo_categories (user_id, name) WHERE deleted_at IS NULL;

CREATE TABLE todos (
    id                UUID PRIMARY KEY,
    user_id           UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    title             TEXT NOT NULL,
    type              TEXT NOT NULL DEFAULT 'one_off' CHECK (type IN ('one_off', 'project')),
    description       TEXT,
    category_id       UUID REFERENCES todo_categories (id) ON DELETE SET NULL,
    tag_ids           JSONB NOT NULL DEFAULT '[]',    -- [tagId, ...]
    priority          TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('low', 'normal', 'high', 'urgent')),
    status            TEXT NOT NULL DEFAULT 'todo' CHECK (status IN ('todo', 'in_progress', 'completed', 'cancelled')),
    estimated_minutes INT,
    color             TEXT,
    deadline_at       TIMESTAMPTZ,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision          INT  NOT NULL DEFAULT 1,
    deleted_at        TIMESTAMPTZ
);
CREATE INDEX idx_todos_user ON todos (user_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_todos_deadline ON todos (user_id, deadline_at) WHERE deleted_at IS NULL AND deadline_at IS NOT NULL;

CREATE TABLE todo_blocks (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    todo_id    UUID NOT NULL REFERENCES todos (id) ON DELETE CASCADE,
    start_at   TIMESTAMPTZ NOT NULL,
    end_at     TIMESTAMPTZ NOT NULL,
    block_note TEXT,
    status     TEXT NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled', 'in_progress', 'completed', 'skipped')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision   INT  NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ,
    CHECK (end_at > start_at)
);
CREATE INDEX idx_blocks_todo ON todo_blocks (todo_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_blocks_range ON todo_blocks (user_id, start_at, end_at) WHERE deleted_at IS NULL;

CREATE TABLE tags (
    id         UUID PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    color      TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision   INT  NOT NULL DEFAULT 1,
    deleted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX idx_tags_user_name ON tags (user_id, name) WHERE deleted_at IS NULL;

-- occurrence overrides: THIS-scope edits on course meetings / recurring schedules.
CREATE TABLE occurrence_overrides (
    id                    UUID PRIMARY KEY,
    user_id               UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    series_type           TEXT NOT NULL CHECK (series_type IN ('course_meeting', 'recurring_schedule')),
    series_id             UUID NOT NULL,
    occurrence_date_local TEXT NOT NULL CHECK (occurrence_date_local ~ '^\d{4}-\d{2}-\d{2}$'),
    action                TEXT NOT NULL CHECK (action IN ('move', 'update', 'cancel')),
    replacement_start_at  TIMESTAMPTZ,
    replacement_end_at    TIMESTAMPTZ,
    metadata              JSONB,     -- patch: {"title":..., "location":..., "color":..., "notes":...}
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    revision              INT  NOT NULL DEFAULT 1,
    deleted_at            TIMESTAMPTZ,
    UNIQUE (series_id, occurrence_date_local)
);
CREATE INDEX idx_overrides_series ON occurrence_overrides (series_type, series_id) WHERE deleted_at IS NULL;

-- MCP change sets (preview -> confirmationId -> atomic apply).
CREATE TABLE agent_change_sets (
    id         UUID PRIMARY KEY,     -- confirmationId
    user_id    UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    changes    JSONB NOT NULL,
    preview    JSONB NOT NULL,
    status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'applied', 'expired')),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_at TIMESTAMPTZ
);
CREATE INDEX idx_changesets_user ON agent_change_sets (user_id, status);

-- CSV import previews (upload -> parse/validate -> preview -> confirm -> commit).
CREATE TABLE import_previews (
    id          UUID PRIMARY KEY,
    user_id     UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    calendar_id UUID NOT NULL REFERENCES academic_calendars (id),
    result      JSONB NOT NULL,
    status      TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'committed', 'expired')),
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    committed_at TIMESTAMPTZ
);
CREATE INDEX idx_import_previews_user ON import_previews (user_id, status);

-- Security-relevant auth events (login/refresh/denials). No secrets inside.
CREATE TABLE auth_events (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID,
    username   TEXT,
    event      TEXT NOT NULL,     -- login_success | login_failure | refresh | logout | denied
    detail     TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_auth_events_user ON auth_events (user_id, created_at);
