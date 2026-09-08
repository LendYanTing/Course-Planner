# Web Agent Prompt

你负责 Course Planner 的 Web Client。

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

- Next.js
- React
- TypeScript
- Tailwind CSS
- shadcn/ui
- TanStack Query
- Zustand
- Dexie / IndexedDB

## 核心原则

1. OpenAPI 是唯一 API 契约。
2. 使用 generated API client。
3. 不自行猜字段名。
4. 不使用浏览器 timezone 解释用户日程。
5. 用户 timezone 来自服务器。
6. 所有绝对时间先规范化为 UTC，再在用户 timezone 下显示。
7. UI 状态和同步状态分离。
8. 本地 mutation 优先写 IndexedDB，然后后台同步。

## 页面

```text
/login
/register
/week
/month
/todos
/settings
/import/courses
```

## Week View

必须支持：

- 7 天
- 24 小时纵轴
- 当前时间橙线
- course
- recurring schedule
- todo block
- deadline
- morning / afternoon / evening 区分
- folding
- merged periods
- event overlap

## Interaction

### Move

拖动整个事件修改 start/end。

### Resize

拖顶部边界修改 start。

拖底部边界修改 end。

### Snap

默认 snap 到 period boundaries。

支持：

```text
period
5_minutes
free
```

### Course Drag

默认只编辑这一周这一 occurrence。

不要因为拖动 9 月 14 日的课而修改整条 CourseMeeting。

用户要修改整个系列时通过显式 scope UI：

- 仅这一次
- 这一次及以后
- 整个系列

### Todo Block

同样只操作当前 Block。

## Conflict UI

Todo 可以覆盖课程。

渲染顺序：

```text
Course layer
Todo layer
Conflict indicator
```

不应该因为 soft conflict 阻止创建。

## Todo

默认创建 one_off。

高级设置：

- project

Project Todo：

- deadline
- estimated duration
- multiple blocks
- block_note
- progress

RecurringSchedule 使用独立入口，不作为 Todo type。

## Month View

一次查询需要的完整 range，然后本地按日期分组。

突出：

- deadline
- task blocks
- course
- recurring schedule

## Tags / Categories

标签输入时展示已有标签作为候选，并允许创建新标签。

## Offline

所有写操作：

```text
local DB transaction
-> pending operation
-> optimistic UI
-> background sync
```

Hard refresh：

```text
保留 pending operations
-> 清 cache
-> 拉服务器
-> rebuild
-> replay pending operations
```

## Agent Confirmation

Agent 产生多个写操作时，只显示一个确认窗口。

必须明确区分：

- 创建
- 修改
- 删除

用户确认后才调用 apply_changes。

## Performance

每分钟只更新 current time indicator。

不要因为 current time 改变导致所有 event 重渲染。

事件布局采用可计算的 absolute positioning / CSS Grid。

## 安全

不要将 refresh token 放入 localStorage。

认证、CORS、CSRF、cookie 行为遵循 `docs/security.md`。
