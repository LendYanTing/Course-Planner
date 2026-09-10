# MCP Contract

## 1. Purpose

MCP 只是 AI 操作本系统的标准接口，不能成为第二套业务逻辑。

```text
MCP
 -> Application Service
 -> Repository
 -> PostgreSQL
```

## 2. Read Tools

至少提供：

```text
get_current_time
get_user_timezone
get_calendar
get_courses
get_schedule
get_todos
get_todo
get_free_slots
search_todos
search_courses
```

读取无需用户确认。

## 3. Write Tools

至少提供：

```text
create_todo
update_todo
delete_todo
create_todo_block
update_todo_block
delete_todo_block
create_course
update_course
delete_course
create_recurring_schedule
update_recurring_schedule
delete_recurring_schedule
```

但推荐不是直接执行，而是：

```text
preview_changes
apply_changes
```

## 4. Preview

Agent 先生成 Change Set：

```json
{
  "changes": [
    {
      "operation": "create",
      "entityType": "todo_block",
      "payload": {}
    }
  ]
}
```

服务器返回：

```json
{
  "confirmationId": "uuid",
  "expiresAt": "2026-09-08T05:00:00Z",
  "changes": []
}
```

## 5. Apply

```text
apply_changes(confirmationId)
```

整批 Change Set 在一个事务中执行。

成功则全部提交，失败则全部回滚。

## 6. Confirmation

客户端负责展示确认 UI。

一次 Agent 请求产生的多个写入必须合并成一个确认窗口。

禁止逐项反复弹窗。

## 7. Timezone

自然语言时间和 local datetime 默认按当前用户 timezone 解释。

工具内部 canonical datetime 仍然使用 UTC。

建议返回：

```json
{
  "startAt": "2026-09-08T01:00:00Z",
  "displayStart": "2026-09-08 09:00",
  "timezone": "Asia/Shanghai"
}
```

## 8. Scheduling Behavior

当 Agent 要安排大型 Todo：

1. 获取课程和固定安排
2. 获取现有 Todo Blocks
3. 获取 deadline（若有）
4. 查询 free slots
5. 根据 estimated duration 分配时间
6. 生成多个 Todo Blocks
7. 每个 Block 写明 work note
8. 生成 Change Set
9. 等待用户一次性确认
10. atomic apply

## 9. Agent Must Not

- 直接操作数据库
- 修改用户 timezone
- 绕过 API authorization
- 未确认直接创建 / 修改 / 删除
- 默认覆盖课程
- 捏造不存在的时间空闲

## 10. Credentials

MCP 端点需要认证，凭证一律通过 `Authorization: Bearer <token>` 传递。支持两类：

```text
Access Token   HS256 JWT，默认 15 分钟寿命。适合交互式调试，不适合长期挂载的客户端。
MCP Token      以 cpmcp_ 开头的长效不透明令牌，默认永不过期，可随时吊销。
```

MCP Token 规则：

- 明文只在创建响应中出现一次；服务端只保存 SHA-256 哈希（与 refresh token 同策略）
- `scopes` 可选 `read`（只读）与 `read` + `write`（默认）
- 只读令牌调用任何 write 工具、`preview_changes`、`apply_changes` 都会被拒绝
- 可选 `expiresInDays`，缺省表示长期有效
- 记录 `createdAt` / `lastUsedAt`，可单独吊销，吊销后立即失效

客户端配置里应该放 MCP Token，而不是 access token——后者 15 分钟后就失效，
而 MCP 客户端不会自己走 `/auth/refresh`。

## 11. Connect（网页登入换取 token）

```text
GET  /mcp/connect     浏览器页面（HTML 表单）
POST /mcp/connect     登录并签发 MCP Token
```

两个端点都不在 `/api/v1` 之下：这是给人用的页面，不是版本化 API 的一部分。

表单 / 查询参数：

```text
name          令牌名称，默认 "MCP client"
scopes        read 或 write；默认 read,write
redirect_uri  可选，仅允许 loopback
```

成功后：

- 页面展示 token 明文，以及可直接粘贴进 MCP 客户端配置的 JSON 片段
- 若提供了合法 `redirect_uri`，则以 303 跳转到
  `redirect_uri?token=...&name=...&tokenId=...&expiresAt=...`

安全约束：

- `redirect_uri` 只接受 `http://127.0.0.1[:port]` 与 `http://localhost[:port]`，其余一律拒绝
  （否则登录页会变成一个 token 外泄渠道）
- 表单提交做同源判断：`Origin` 是具体源时必须与本机 host 一致；`Origin: null`
  （内嵌 WebView / 沙箱 iframe 的 opaque origin）或缺失时按"未知来源"放行——
  这个头本身不可信（任何页面都能造出 `null`），真正的约束是"口令必须手工输入"+
  "redirect_uri 仅限回环"；当浏览器给出 `Referer` 时仍会用 `Referer` 复核
- 登录失败按来源 IP 节流
- 响应 `Cache-Control: no-store`；页面 CSP 只允许自身内联样式与脚本

对应的 REST 管理接口（用会话 access token 调用，不能用一个 MCP token 去铸造新的
MCP token）见 `docs/api.md` §18。

## 12. Transport

Streamable HTTP，单一端点：

```text
POST /api/v1/mcp
Content-Type: application/json
Accept: application/json, text/event-stream
```

服务端行为：

- 支持单个 JSON-RPC 消息，也支持 batch 数组
- 响应统一为 `application/json`，不提供 SSE 流；因此 `GET` / `DELETE` 返回 `405`
- 无状态：不签发 `Mcp-Session-Id`，客户端若回传该头会被忽略
- 支持的协议版本：`2025-06-18`（默认）/ `2025-03-26` / `2024-11-05`；
  `initialize` 回显客户端请求的版本，不在列表内则回退到最新版本
- 请求头 `MCP-Protocol-Version` 若存在但不受支持，返回 HTTP 400
- 只包含 notification 的请求返回 `202 Accepted` 且没有响应体
- `Accept` 头不含 `application/json`（或 `*/*`）时返回 `406`
- 工具执行失败表现为 `result.isError = true`，不占用 JSON-RPC 错误码
- `initialize` 返回 `instructions`，向 Agent 说明"写入必须走 preview → apply"
- 每个工具带 `title` 与 `annotations`（`readOnlyHint` / `destructiveHint` /
  `idempotentHint`），让客户端能对只读工具自动放行、对破坏性工具强制确认
