# Course Planner 项目规格文档

> 跨平台课程表、日程规划、Todo、离线同步与 MCP Agent 系统。
>
> 本目录是 Server、Web、Flutter 三个 Agent 的共同设计基线。实现过程中，代码可以演进，但任何影响跨端通信、数据语义、时间语义或同步语义的修改，都必须先修改这里的文档与 OpenAPI 契约。

## 核心目标

- 数据安全优先
- 数据模型结构简洁、直观、可长期维护
- Web / Flutter 体验一致
- 用户时区固定、绝不依赖设备系统时区
- 课程、周期性安排、Todo 与 Todo Block 语义明确分离
- 支持离线优先、多端同步和可解释的冲突处理
- Agent 读取日程无需确认，写入统一预览后一次性确认
- 前端周视图 / 月视图美观、流畅、可直接编辑
- 后端不负责公网 TLS；公网 HTTPS 由 Cloudflare Tunnel / 反向代理提供

## 推荐技术栈

### Backend

- Go
- Chi
- PostgreSQL
- sqlc
- SQL migrations
- OpenAPI 3.1
- Argon2id
- Access Token + Refresh Token
- MCP SDK

### Web

- Next.js
- React
- TypeScript
- Tailwind CSS
- shadcn/ui
- TanStack Query
- Zustand
- Dexie / IndexedDB

### Flutter

- Flutter
- Dart
- Riverpod
- Dio
- Drift / SQLite
- go_router
- flutter_secure_storage

## 文档入口

- `docs/architecture.md`：总体架构、模块边界、开发原则
- `docs/domain-model.md`：数据库与领域模型
- `docs/api.md`：REST API 约定
- `docs/openapi.yaml`：机器可读 API 契约
- `docs/datetime.md`：UTC、用户时区、重复规则的时间处理
- `docs/sync-protocol.md`：离线同步、Revision、Cursor、冲突
- `docs/mcp.md`：MCP 工具、预览与批量确认
- `docs/csv-import.md`：课程 CSV 导入规范
- `docs/ui-interaction.md`：周/月视图、拖拽、吸附、折叠
- `docs/security.md`：认证、令牌、密码、安全边界
- `docs/agent-behavior.md`：AI Agent 通用行为规范

Agent 专用提示词：

- `agents/server-agent.md`
- `agents/web-agent.md`
- `agents/flutter-agent.md`

## 变更顺序

影响协议的修改必须遵循：

1. 修改领域文档
2. 修改 OpenAPI / 通信契约
3. 修改 Backend
4. 更新生成代码 / 客户端 API 层
5. 修改 Web / Flutter
6. 补充测试

不要反向从某个客户端“猜”协议。
