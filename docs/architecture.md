# Architecture

## 1. Overall Architecture

```text
                           Internet
                              |
                       HTTPS / TLS edge
                              |
             Cloudflare Tunnel / Reverse Proxy
                              |
                          HTTP only
                              |
                    +---------------------+
                    |      Backend        |
                    | Go + Chi             |
                    | Auth                 |
                    | Domain Services      |
                    | REST API             |
                    | Sync                 |
                    | MCP                  |
                    +----------+----------+
                               |
                         PostgreSQL

             +----------------+----------------+
             |                                 |
       +-----v------+                    +-----v------+
       |    Web     |                    |  Flutter   |
       | Next.js    |                    |   App      |
       +-----+------+                    +-----+------+
             |                                 |
       IndexedDB                         SQLite/Drift
             |                                 |
             +------------- Sync ---------------+
```

## 2. Source of Truth

服务器数据库是云端权威来源。

客户端本地数据库是离线工作副本，不是第二个独立数据源。

API 数据契约由 `docs/openapi.yaml` 定义。

## 3. Domain Layer

Backend 必须至少分成：

```text
HTTP Handler / MCP Tool
        |
        v
Application / Domain Service
        |
        v
Repository
        |
        v
PostgreSQL
```

HTTP API 和 MCP 必须调用同一 Domain Service，不得各写一套业务逻辑。

## 4. Main Modules

```text
server/internal/
├── auth/
├── user/
├── calendar/
├── course/
├── schedule/
├── todo/
├── tag/
├── category/
├── event/
├── sync/
├── importcsv/
├── mcp/
└── common/
```

### Calendar

学期、周数、课程节次模板。

### Course

学校课程及其周期性安排。

### Schedule

用户自定义周期性安排，语义接近“自定义课程”，没有 Todo 完成状态，也没有 deadline。

### Todo

待完成的事情。

### Todo Block

某个 Todo 在某个具体时间内执行的一次工作安排。

### Event Projection

周视图 / 月视图所使用的统一事件投影。

## 5. Event Categories

统一展示层 `CalendarEvent` 至少支持：

- `course`
- `recurring_schedule`
- `todo_block`
- `deadline`

以后可扩展 `manual_event`，但第一版不必强行实现。

## 6. Ownership

所有用户数据都必须带明确 owner：

```text
user_id
```

服务端每次从认证上下文确定用户身份，客户端提交的 `user_id` 不得作为权限依据。

## 7. Public Transport

Backend 可以只监听内网 HTTP，例如 Docker network、localhost 或 VPN 网络。

公网入口负责 HTTPS：

```text
Browser / App
   HTTPS
     |
Cloudflare / Reverse Proxy
     |
   HTTP
     |
Backend
```

不要把 Backend HTTP 端口直接暴露在公网。

## 8. Performance

### Web

- 周视图采用 CSS Grid / positioned events
- 当前时间线独立刷新
- 事件组件尽量 memo
- 月视图整段 range 查询，不逐日请求
- 只加载当前及相邻需要的日期范围

### Flutter

- 当前时间状态与日程数据状态分离
- 使用本地数据库查询驱动 UI
- 避免每分钟导致整个页面重建

## 9. Hard Refresh

硬刷新只清理可重建 cache，不得丢弃未上传 mutation。

正确过程：

```text
pause sync
-> preserve pending operations
-> discard derived/cache data
-> fetch authoritative snapshot
-> rebuild local DB
-> replay pending operations
-> resume sync
```
