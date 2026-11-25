# Course Planner — Agent Guide

课程表 / 日程 / Todo 工具，带离线同步和 MCP。三个端可以独立构建、独立部署，通过 `docs/openapi.yaml` 这一个契约连接。

## 仓库结构

| 目录 | 内容 | 技术栈 |
| --- | --- | --- |
| `server/` | 后端 API、同步、MCP | Go + Chi + PostgreSQL |
| `web/` | 网页端 | Next.js |
| `flutter/` | 客户端（Windows / Android） | Flutter + Riverpod + Drift |

issue 里请写明涉及哪个端；跨端改动（例如改 API 契约）要显式列出所有受影响的端。

## 先读这些

各端的开工brief在 `agents/` 下：`server-agent.md`、`web-agent.md`、`flutter-agent.md`。它们列出了该端必须先读的文档。

仓库级文档在 `docs/` 下，其中这几份是硬约束，改动前必读：

- `docs/domain-model.md` — 实体模型与不变量
- `docs/openapi.yaml` — API 唯一契约，禁止另立一套
- `docs/datetime.md` — UTC ↔ 用户时区的换算规则
- `docs/sync-protocol.md` — 唯一同步协议
- `docs/agent-behavior.md` — MCP 读写行为与 Change Set 确认规则

## Agent skills

### Issue tracker

Issues live as GitHub issues in `LendYanTing/Course-Planner`, via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, label strings unchanged (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` plus `docs/adr/` at the repo root, alongside `server/`, `web/`, and `flutter/`. See `docs/agents/domain.md`.