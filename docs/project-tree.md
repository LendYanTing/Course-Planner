# Project Tree

```text
course-planner/
├── README.md
├── LICENSE
├── .gitignore
├── .env.example
├── docker-compose.yml
│
├── docs/
│   ├── architecture.md
│   ├── domain-model.md
│   ├── api.md
│   ├── openapi.yaml
│   ├── datetime.md
│   ├── sync-protocol.md
│   ├── mcp.md
│   ├── csv-import.md
│   ├── ui-interaction.md
│   ├── security.md
│   └── agent-behavior.md
│
├── agents/
│   ├── server-agent.md
│   ├── web-agent.md
│   └── flutter-agent.md
│
├── server/
│   ├── cmd/
│   │   └── server/
│   │       └── main.go
│   ├── internal/
│   │   ├── auth/
│   │   ├── user/
│   │   ├── calendar/
│   │   ├── course/
│   │   ├── schedule/
│   │   ├── todo/
│   │   ├── tag/
│   │   ├── category/
│   │   ├── event/
│   │   ├── sync/
│   │   ├── importcsv/
│   │   ├── mcp/
│   │   ├── platform/
│   │   └── common/
│   ├── migrations/
│   ├── sql/
│   ├── generated/
│   ├── tests/
│   └── go.mod
│
├── web/
│   ├── app/
│   ├── components/
│   ├── features/
│   │   ├── auth/
│   │   ├── week-view/
│   │   ├── month-view/
│   │   ├── courses/
│   │   ├── todos/
│   │   ├── sync/
│   │   ├── agent/
│   │   └── settings/
│   ├── db/
│   ├── lib/
│   ├── generated/
│   └── package.json
│
├── flutter/
│   ├── lib/
│   │   ├── app/
│   │   ├── core/
│   │   ├── data/
│   │   ├── domain/
│   │   ├── presentation/
│   │   ├── sync/
│   │   └── generated/
│   ├── test/
│   └── pubspec.yaml
│
└── scripts/
    ├── generate-api.sh
    ├── test-all.sh
    └── dev.sh
```

## Dependency Direction

```text
UI
 ↓
Feature / Application
 ↓
API Client / Local DB
 ↓
Sync Engine
```

Web / Flutter 不共享具体实现代码，但共享：

- OpenAPI
- datetime contract
- domain names
- sync semantics
- MCP semantics
