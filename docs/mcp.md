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
