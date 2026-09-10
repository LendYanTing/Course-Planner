-- Long-lived MCP credentials (docs/mcp.md §10, docs/security.md §11).
--
-- MCP clients attach a static credential to every request and cannot walk the
-- 15-minute access/refresh cycle, so agents authenticate with an opaque
-- `cpmcp_` token instead. Only the SHA-256 hash is stored; the secret itself
-- is returned exactly once at creation.

CREATE TABLE mcp_tokens (
    id           UUID PRIMARY KEY,
    user_id      UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    token_prefix TEXT NOT NULL,          -- display-only identifier, e.g. cpmcp_AbCdEfGh
    token_hash   TEXT NOT NULL UNIQUE,   -- SHA-256 of the opaque token
    scopes       TEXT[] NOT NULL DEFAULT ARRAY['read', 'write']::TEXT[],
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ,            -- NULL = never expires
    revoked_at   TIMESTAMPTZ,
    CHECK (cardinality(scopes) > 0 AND scopes <@ ARRAY['read', 'write']::TEXT[]),
    CHECK (char_length(name) BETWEEN 1 AND 64)
);
CREATE INDEX idx_mcp_tokens_user ON mcp_tokens (user_id, created_at DESC);
