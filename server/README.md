# Course Planner — Server

Go 后端：课程表 / 日程 / Todo / 离线同步 / MCP Agent 的云端权威数据源。

设计基线见仓库根目录 `README.md` 与 `docs/`。任何影响跨端语义的改动必须先改文档与 `docs/openapi.yaml`，再改代码（变更顺序见根 README）。

## 快速开始

```bash
# 1. 数据库（或自备 PostgreSQL）
docker compose up -d postgres      # 127.0.0.1:5433, courseplanner/courseplanner

# 2. 配置环境变量（生产环境务必用真实 secret）
#    Windows: 参考 .env.example；或
export DATABASE_URL='postgres://courseplanner:courseplanner@127.0.0.1:5433/courseplanner?sslmode=disable'
export JWT_SECRET="$(openssl rand -hex 32)"

# 3. 启动（首次启动自动执行 migrations，数据库结构见 migrations/）
go run ./cmd/server

# 4. 健康检查 / 契约冒烟
curl http://127.0.0.1:8080/healthz
curl http://127.0.0.1:8080/api/v1/meta/time
```

构建产物路径：`cmd/server`；Docker 镜像构建见仓库根 `docker-compose.yml` 的 `server` 服务。

## 测试

```bash
# 单元测试（无需数据库）
go test ./internal/...

# 集成测试（黑盒 HTTP，需要 PostgreSQL）
export TEST_DATABASE_URL='postgres://.../courseplanner_test?sslmode=disable'
go test ./tests/ -count=1
```

集成测试每次运行会重建 schema（确定性结果），共覆盖：auth、时区锁定、课程 CRUD、
周规则/单双周/连堂、CSV 导入、RecurringSchedule、Todo/Block/Deadline、free slots、
课程硬冲突、软冲突、occurrence override、THIS/THIS_AND_FUTURE/ALL、sync cursor、
revision 冲突、幂等 push、tombstone、三方合并、MCP preview/apply、长效 MCP token
（签发/吊销/到期/只读 scope）、`/mcp/connect` 登录页（含 redirect 白名单与跨站拒绝）、
MCP 传输边界（405/406/202、协议版本协商、工具 annotations）。

## 架构与模块

```
HTTP handlers / MCP tools
        ↓
Domain services（唯一业务逻辑入口，REST 与 MCP 共用）
        ↓
Repositories（显式 SQL + 事务）
        ↓
PostgreSQL
```

- `internal/auth`     注册/登录/刷新/登出，Argon2id，JWT access + 可撤销 refresh token
- `internal/user`     用户表与时区（创建后不可改）
- `internal/calendar` 学期（AcademicCalendar）+ 课节模板（PeriodTemplate）
- `internal/course`   Course 与 CourseMeeting（weekday + 节次 + 单双周规则）
- `internal/schedule` RecurringSchedule（daily / weekly / by_academic_week）
- `internal/todo`     Todo / TodoBlock / deadline
- `internal/tag`、`internal/category`
- `internal/override` 单次 occurrence 编辑（move/update/cancel）
- `internal/series`   THIS / THIS_AND_FUTURE / ALL 系列编辑（切分旧系列）
- `internal/event`    CalendarEvent 统一投影 + conflict_state（hard/soft）
- `internal/freeslot` 空闲时段（默认把软冲突来源也算作占用）
- `internal/importcsv` 课程 CSV preview/commit
- `internal/sync`     cursor + revision + tombstone + 幂等 operation + 三方合并
- `internal/agent`    MCP Change Set：preview → confirmationId → 原子 apply
- `internal/mcp`      Streamable-HTTP JSON-RPC（/api/v1/mcp）+ 工具注册
- `internal/mcptoken` 长效 MCP 凭证（`cpmcp_` 前缀、哈希落库、scope、吊销）
- `internal/mcpconnect` 浏览器登录页（`/mcp/connect`），签发 MCP token
- `internal/platform` 配置、pgx 连接池、迁移、HTTP 工具
- `internal/common`   apperr 错误码、timeutil（UTC/本地时间）、weekrule

## MCP 接入

MCP 端点是 `POST /api/v1/mcp`（JSON-RPC 2.0，streamable HTTP，无状态）。
Agent 不能用 15 分钟的 access token 长期挂着，所以用长效 MCP token：

```bash
# 方式一：浏览器登录换取（推荐给人用）
open http://127.0.0.1:8080/mcp/connect          # 登录 → 显示 token + 客户端配置
node scripts/mcp-connect.js                     # 本地 helper：自动开浏览器、回调取 token、打印配置

# 方式二：用会话 token 通过 REST 铸造
curl -X POST http://127.0.0.1:8080/api/v1/mcp-tokens \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Claude Desktop","scopes":["read","write"],"expiresInDays":0}'
```

客户端配置（token 明文只在创建时返回一次，服务端只存 SHA-256 哈希）：

```json
{
  "mcpServers": {
    "course-planner": {
      "type": "http",
      "url": "http://127.0.0.1:8080/api/v1/mcp",
      "headers": { "Authorization": "Bearer cpmcp_..." }
    }
  }
}
```

- `scopes: ["read"]` 得到只读凭证：MCP write 工具与 `preview_changes` /
  `apply_changes` 会返回 `isError`，REST 写路径返回 `FORBIDDEN`。
- `GET /api/v1/mcp-tokens` 列出（只显示 `tokenPrefix`，永不回显明文），
  `DELETE /api/v1/mcp-tokens/{id}` 立即吊销；这两个接口只接受会话 token。
- 传输细节（协议版本协商、405/406/202、`instructions`、工具 annotations）见
  `docs/mcp.md` §12。

## 关键约定

- 绝对时间一律 UTC RFC3339（`timeutil.ParseInstant` 拒绝无时区串）。
- 本地日历语义（重复规则、周数、跨午夜判断）一律按用户不可变 IANA 时区计算。
- 单次块（meeting / recurring occurrence / todo block）禁止跨本地午夜。
- 每个同步实体带 `revision`；软删除留下 tombstone 与 `deleted_at`。
- 每次持久化变更在同一事务里写入 `sync_changes`（同时充当 revision 历史与墓碑）。
- push 按 `operationId` 幂等；update 冲突做按字段三方合并，冲突返回
  `base/local/server` 与冲突字段，绝不静默覆盖。
- 写操作（REST 与 MCP 一致）都经由同一 Domain Service；MCP 写入一律
  `preview_changes → confirmationId → apply_changes`，Change Set 单事务原子提交。
- 课程互撞 = 硬冲突（创建/移动被拒，除非 `force`）；RecurringSchedule、
  TodoBlock 与课程重叠 = 软冲突（允许，带 `conflictState`）。
- 用户身份只来自认证上下文；API/MCP 均不接受客户端 userId 作为授权依据。

## 实现说明 / 与推荐栈的偏差

- 数据库访问使用 `pgx/v5` + 手写显式 SQL（repository 层），未使用 sqlc：
  本仓库大量动态 JSONB 规则、按字段更新与投影查询，sqlc 收益有限且会引入代码生成
  环节；分层与“显式 SQL、事务优先”的原则保持不变。
- 迁移执行器是内置的轻量 runner（`server/migrations` 下按文件名顺序执行，
  记录在 `schema_migrations`），不依赖外部 CLI。
- 刷新令牌以 SHA-256 哈希落库、每次刷新轮换、登出即吊销；Web 端经 HttpOnly
  cookie（`COOKIE_SECURE` 默认 true），原生客户端从响应体读取。
- CORS 默认关闭；允许名单由 `CORS_ALLOWED_ORIGINS` 显式配置（杜绝 `*`）。

## 运维

- 后端只监听内网 HTTP；公网 HTTPS 由 Cloudflare Tunnel / 反向代理终结，
  不要把 `:8080` 直接暴露到公网。
- `JWT_SECRET`、数据库口令等 secrets 一律来自环境变量，禁止入库。
- 错误响应格式与错误码清单见 `docs/api.md`；客户端只依赖 `error.code`。
