# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

Layout: **single-context**.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root, or
- **`GLOSSARY-MAP.md`** at the repo root if it exists: it points at one `GLOSSARY.md` per context. Read each one relevant to the topic.
- **`docs/adr/`**: read ADRs that touch the area you're about to work in.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## This repo's existing domain documents

These predate the glossary and are **not** replaced by it — read them alongside it:

- **`docs/domain-model.md`** — the authoritative entity model (`User`, `AcademicCalendar`, `PeriodTemplate`, `Course`, `RecurringSchedule`, `Todo`, `TodoBlock`, `Category`, `Tag`, …) with field lists and invariants. When the glossary and this file disagree about an entity, this file wins for structure; `GLOSSARY.md` wins for wording.
- **`docs/architecture.md`** — end-to-end architecture across the three ends.
- **`docs/openapi.yaml`** — the single API contract. No end defines a second one.
- **`docs/datetime.md`** — UTC ↔ user-timezone rules. The user timezone comes from the server and is immutable; never derive it from the device.
- **`docs/sync-protocol.md`** — the one sync protocol (pull → push → pull, revision-based conflict resolution).
- **`docs/agent-behavior.md`** — what MCP-driven agents may read freely and what needs a confirmed Change Set.
- **`agents/*.md`** — per-end working briefs (`server-agent.md`, `web-agent.md`, `flutter-agent.md`).

Domain vocabulary is shared across all three ends. Only implementation concerns differ per end, so the glossary stays single-context at the root.

## File structure

Single-context repo (most repos):

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

Multi-context repo (presence of `GLOSSARY-MAP.md` at the root):

```
/
├── GLOSSARY-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── GLOSSARY.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── GLOSSARY.md
        └── docs/adr/
```

This repo is single-context: `GLOSSARY.md` and `docs/adr/` at the root, alongside `server/`, `web/`, and `flutter/`.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_