# Flutter Agent Prompt

你负责 Course Planner 的 Flutter Client。

先阅读整个仓库的：

- `README.md`
- `docs/architecture.md`
- `docs/domain-model.md`
- `docs/api.md`
- `docs/openapi.yaml`
- `docs/datetime.md`
- `docs/sync-protocol.md`
- `docs/mcp.md`
- `docs/ui-interaction.md`
- `docs/security.md`
- `docs/agent-behavior.md`

## 技术栈

- Flutter
- Dart
- Riverpod
- Dio
- Drift / SQLite
- go_router
- flutter_secure_storage

## 核心原则

1. OpenAPI 是 API 唯一契约。
2. 使用 generated API client。
3. 禁止自行定义第二套同步协议。
4. 禁止使用设备 timezone 解释日程。
5. 用户 timezone 由服务端提供并固定。
6. SQLite 是离线工作副本。
7. 所有 mutation 首先写本地 DB 和 operation queue。
8. UI 采用 optimistic local update。

## 页面

至少实现：

- Login
- Register
- Week
- Month
- Todo
- Settings
- Course Import

## Week View

支持：

- 7 列
- 24 小时
- 当前时间橙线
- course
- recurring schedule
- todo block
- deadline
- folding
- period merge
- drag
- resize
- conflict indicator

## Drag / Resize

Course 默认只修改当前 occurrence。

Todo Block 只修改当前 Block。

边界拖动修改 start/end。

不得跨午夜。

默认吸附 period boundary。

## Todo

支持：

- one_off
- project
- deadline
- estimated duration
- multiple blocks
- block note
- tags
- category
- priority
- status

## Month

一次拉取完整日期范围的数据，在本地按日期索引。

## Timezone

严格使用：

```text
UTC
<->
user timezone
```

不得使用 `DateTime.now().timeZoneOffset` 决定用户日程 timezone。

Current time 通过 server time offset 估算。

## Sync

本地保存：

```text
lastServerCursor
entity revision
pending operations
```

Operation：

```text
operationId
entityType
entityId
operation
baseRevision
changes
```

冲突使用 Base / Local / Server 三方信息。

## Hard Refresh

永远保留 pending operations。

执行：

```text
pause sync
-> clear cache
-> fetch authoritative state
-> rebuild SQLite
-> replay pending operations
-> resume
```

## Agent

Read 无需确认。

Write 必须预览 Change Set，并由用户一次性确认。

禁止一项写入弹一个确认框。

## Networking

Dio interceptor 负责：

- Authorization
- access token refresh
- structured error decoding
- retry（谨慎，避免非幂等请求重复执行）

Refresh Token 存 secure storage。

## Performance

Riverpod 状态至少分离：

```text
currentServerNow
calendarEvents
syncState
```

当前时间每分钟变化时不要触发整个 Week View 重建。
