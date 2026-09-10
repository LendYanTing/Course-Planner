# REST API Contract

Base URL：

```text
/api/v1
```

所有接口均以认证用户为数据边界。

## 1. Common Headers

```http
Authorization: Bearer <access-token>
Content-Type: application/json
```

`Authorization` 接受两种凭证：

```text
access token    会话用，15 分钟寿命（见 §3）
MCP token       cpmcp_ 前缀的长效令牌，用于 Agent / MCP 客户端（见 §18）
```

写操作推荐支持：

```http
Idempotency-Key: <uuid>
```

## 2. Common Response

成功单对象：

```json
{
  "data": {}
}
```

列表：

```json
{
  "data": [],
  "pagination": {
    "nextCursor": null
  }
}
```

错误：

```json
{
  "error": {
    "code": "SCHEDULE_CONFLICT",
    "message": "Schedule conflict",
    "details": {}
  }
}
```

客户端依赖 `error.code`，不要依赖自然语言 `message`。

## 3. Auth

### Register

```http
POST /auth/register
```

Request：

```json
{
  "username": "alice",
  "email": "alice@example.com",
  "password": "...",
  "timezone": "Asia/Shanghai"
}
```

### Login

```http
POST /auth/login
```

### Refresh

```http
POST /auth/refresh
```

### Logout

```http
POST /auth/logout
```

### Current User

```http
GET /me
```

用户 timezone 由服务端返回，但没有修改 timezone 的 API。

## 4. Meta

### Server Time

```http
GET /meta/time
```

Response：

```json
{
  "data": {
    "serverTimeUtc": "2026-09-08T04:00:00Z"
  }
}
```

## 5. Academic Calendars

```text
GET    /calendars
POST   /calendars
GET    /calendars/{calendarId}
PATCH  /calendars/{calendarId}
DELETE /calendars/{calendarId}
```

## 6. Period Templates

```text
GET    /calendars/{calendarId}/periods
POST   /calendars/{calendarId}/periods
PATCH  /calendars/{calendarId}/periods/{periodId}
DELETE /calendars/{calendarId}/periods/{periodId}
```

禁止跨午夜。

## 7. Courses

```text
GET    /courses
POST   /courses
GET    /courses/{courseId}
PATCH  /courses/{courseId}
DELETE /courses/{courseId}
```

### Course Meetings

```text
GET    /courses/{courseId}/meetings
POST   /courses/{courseId}/meetings
PATCH  /courses/{courseId}/meetings/{meetingId}
DELETE /courses/{courseId}/meetings/{meetingId}
```

编辑 occurrence 时使用统一 series operation，而不是伪造一个“修改单次课程”的普通 meeting PATCH。

## 8. Recurring Schedules

```text
GET    /recurring-schedules
POST   /recurring-schedules
GET    /recurring-schedules/{id}
PATCH  /recurring-schedules/{id}
DELETE /recurring-schedules/{id}
```

支持：

- 按自然日周期
- 按星期
- 按学期第几周
- 自定义时间

不支持 deadline。

## 9. Todos

```text
GET    /todos
POST   /todos
GET    /todos/{todoId}
PATCH  /todos/{todoId}
DELETE /todos/{todoId}
```

### Todo Blocks

```text
GET    /todos/{todoId}/blocks
POST   /todos/{todoId}/blocks
PATCH  /todo-blocks/{blockId}
DELETE /todo-blocks/{blockId}
```

### Todo Block Move/Resize

移动和调整上下边界最终都可以归一化为：

```http
PATCH /todo-blocks/{blockId}
```

Body：

```json
{
  "startAt": "2026-09-08T06:00:00Z",
  "endAt": "2026-09-08T07:00:00Z"
}
```

## 10. Series Editing

推荐统一动作接口：

```http
POST /series/{seriesType}/{seriesId}/apply
```

Request：

```json
{
  "scope": "THIS",
  "occurrenceDateLocal": "2026-09-14",
  "operation": {
    "type": "MOVE",
    "startAt": "2026-09-14T01:00:00Z",
    "endAt": "2026-09-14T02:30:00Z"
  }
}
```

scope：

```text
THIS
THIS_AND_FUTURE
ALL
```

这类接口用于周期性课程 / RecurringSchedule 的具体 occurrence 编辑与删除。

## 11. Calendar Events

```http
GET /calendar/events
```

Query：

```text
start=<UTC RFC3339>
end=<UTC RFC3339>
includeCourses=true
includeRecurringSchedules=true
includeTodoBlocks=true
includeDeadlines=true
```

Response：

```json
{
  "data": [
    {
      "id": "event-1",
      "type": "course",
      "title": "高等数学",
      "startAt": "2026-09-14T00:00:00Z",
      "endAt": "2026-09-14T01:20:00Z",
      "source": {
        "type": "course",
        "id": "course-1"
      },
      "conflictState": "none",
      "metadata": {
        "teacher": "小明",
        "location": "逸夫楼201",
        "periodStart": 1,
        "periodEnd": 2,
        "weekday": 1
      }
    }
  ]
}
```

## 12. Free Slots

```http
GET /free-slots
```

参数：

```text
start=<UTC>
end=<UTC>
durationMinutes=60
alignment=period|5_minutes|free
considerCourses=true
considerRecurringSchedules=true
considerTodoBlocks=true
```

返回：

```json
{
  "data": [
    {
      "startAt": "2026-09-08T06:00:00Z",
      "endAt": "2026-09-08T07:00:00Z"
    }
  ]
}
```

默认：

- Course 是强占用
- RecurringSchedule 是占用
- Todo Block 是占用

但 Todo 与 Course 之间允许软冲突；`free-slots` 默认会避开它们。

## 13. Tags / Categories

```text
GET    /tags
POST   /tags
PATCH  /tags/{id}
DELETE /tags/{id}

GET    /todo-categories
POST   /todo-categories
PATCH  /todo-categories/{id}
DELETE /todo-categories/{id}
```

## 14. CSV Import

### Preview

```http
POST /import/courses/preview
Content-Type: text/csv
```

### Commit

```http
POST /import/courses/commit
```

只有 preview 成功并经用户确认后才 commit。

## 15. Sync

### State

```http
GET /sync/state
```

```json
{
  "data": {
    "serverCursor": 1005
  }
}
```

### Changes

```http
GET /sync/changes?after=1000&limit=500
```

### Push

```http
POST /sync/push
```

## 16. Error Codes

至少包括：

```text
INVALID_REQUEST
UNAUTHORIZED
FORBIDDEN
NOT_FOUND
VALIDATION_ERROR
INVALID_TIMEZONE
CROSS_MIDNIGHT_NOT_ALLOWED
SCHEDULE_CONFLICT
COURSE_CONFLICT
STALE_REVISION
SYNC_CONFLICT
DUPLICATE_OPERATION
CSV_PARSE_ERROR
CSV_VALIDATION_ERROR
CONFIRMATION_REQUIRED
CONFIRMATION_EXPIRED
```

## 17. API Rules

- 所有 datetime absolute values 使用 UTC RFC3339
- 所有用户数据通过认证身份隔离
- API 不接受客户端传入 userId 作为授权依据
- 所有写入必须产生 revision / sync change
- 删除必须留下 tombstone
- API 不暴露数据库结构细节

## 18. MCP Credentials

长效 MCP 凭证的增删查。这类接口只接受会话 access token：不能用一枚 MCP token
去铸造或吊销另一枚 MCP token。

```text
GET    /mcp-tokens
POST   /mcp-tokens
DELETE /mcp-tokens/{tokenId}
```

### Create

Request：

```json
{
  "name": "Claude Desktop",
  "scopes": ["read", "write"],
  "expiresInDays": 0
}
```

`scopes` 缺省 `["read","write"]`；`expiresInDays` 为 0 / 缺省表示长期有效。

Response（`token` 只在这里出现一次，之后无法再取回）：

```json
{
  "data": {
    "id": "0b0a2c1e-...",
    "name": "Claude Desktop",
    "token": "cpmcp_...",
    "tokenPrefix": "cpmcp_AbCdEfGh",
    "scopes": ["read", "write"],
    "createdAt": "2026-09-10T03:00:00Z",
    "expiresAt": null
  }
}
```

### List

```json
{
  "data": [
    {
      "id": "0b0a2c1e-...",
      "name": "Claude Desktop",
      "tokenPrefix": "cpmcp_AbCdEfGh",
      "scopes": ["read", "write"],
      "createdAt": "2026-09-10T03:00:00Z",
      "lastUsedAt": "2026-09-10T04:00:00Z",
      "expiresAt": null,
      "revokedAt": null
    }
  ]
}
```

### Revoke

```http
DELETE /mcp-tokens/{tokenId}
```

返回 204。吊销立即生效，列表保留该记录（带 `revokedAt`）以便审计。

### 浏览器 Connect

```text
GET  /mcp/connect
POST /mcp/connect
```

不属于 `/api/v1`：这是给人用的 HTML 页面，登录后直接签发 MCP token 并给出客户端
配置片段。流程与安全约束见 `docs/mcp.md` §11。

### Scope 语义

`read` 只读令牌可以调用所有读接口（含 MCP 只读工具），写路径一律返回
`FORBIDDEN`：

```text
POST/PATCH/DELETE  /api/v1/**（除 /mcp，其按工具粒度判断）
MCP write 工具、preview_changes、apply_changes
```
