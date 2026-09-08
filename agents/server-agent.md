# Server Agent Prompt

你负责 Course Planner 的 Backend。

先阅读整个仓库的：

- `README.md`
- `docs/architecture.md`
- `docs/domain-model.md`
- `docs/api.md`
- `docs/openapi.yaml`
- `docs/datetime.md`
- `docs/sync-protocol.md`
- `docs/mcp.md`
- `docs/csv-import.md`
- `docs/security.md`
- `docs/agent-behavior.md`

## 技术栈

- Go
- Chi
- PostgreSQL
- sqlc
- SQL migrations
- OpenAPI
- Argon2id
- Access Token + Refresh Token
- MCP SDK

## 核心原则

1. Server 是云端权威数据源。
2. OpenAPI 是唯一 HTTP 契约。
3. 用户 timezone 创建后不可修改。
4. 数据库绝对时间使用 UTC。
5. recurrence 按用户 local time 计算，再转换为 UTC。
6. 单个 CourseMeeting、RecurringSchedule、TodoBlock 不得跨午夜。
7. Course 与 CourseMeeting 分离。
8. RecurringSchedule 与 Todo 分离。
9. Todo 与 TodoBlock 分离。
10. Series / Occurrence / Override 复用统一思想。
11. Sync 使用 cursor + revision。
12. Operation 必须幂等。
13. Delete 必须可同步，使用 tombstone。
14. MCP 不直接碰数据库。
15. HTTP 与 MCP 复用相同 Domain Service。
16. 不允许把客户端提交的 userId 作为授权依据。
17. 不要把数据库模型直接当作 API request/response DTO。

## 领域规则

### Course

- 可以按学期、星期、节数、周规则创建
- 支持连堂
- 课程本身不跨午夜
- Course vs Course 默认 hard conflict

### RecurringSchedule

- 语义类似自定义课程
- 可以按第几周安排
- 可以按自定义 local time 安排
- 无 deadline
- 无 Todo 完成状态

### Todo

支持：

- one_off
- project

Project 可以拥有多个 TodoBlock。

### TodoBlock

- 可自定义 start/end
- 可与课程重叠
- 与课程重叠时返回 soft conflict 信息
- 禁止跨午夜
- 支持 block_note

## Series 编辑

支持：

```text
THIS
THIS_AND_FUTURE
ALL
```

`THIS_AND_FUTURE` 必须切断旧 series，而不是篡改旧历史 occurrence。

## Free Slots

提供可复用服务计算：

- courses
- recurring schedules
- todo blocks

的忙碌区间和空闲区间。

默认 Agent 不把软冲突时间当作可用时段。

## Sync

实现：

- sync state
- changes
- push
- operation idempotency
- entity revision
- tombstone
- three-way conflict metadata

优先使用数据库事务和明确 SQL，不要用“最后修改时间相等”作为同步依据。

## MCP

Read tools 无需确认。

Write workflow：

```text
preview_changes
-> confirmationId
-> apply_changes
```

Change Set 必须原子提交。

## 测试

至少覆盖：

- auth
- timezone lock
- course CRUD
- week rules
- odd/even weeks
- continuous periods
- CSV import
- recurring schedule
- Todo / Block
- deadline
- free slot
- course conflict
- soft conflict
- occurrence override
- this / this_and_future / all
- sync cursor
- revision conflict
- idempotency
- tombstone
- MCP preview/apply
