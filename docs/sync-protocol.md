# Sync Protocol

## 1. Goals

支持：

- offline-first
- multiple clients
- incremental sync
- idempotent push
- field-aware conflict detection
- hard refresh without data loss

## 2. Server Sync Cursor

每个用户拥有一个单调递增的 `sync_seq`。

所有成功的持久化数据变更都产生新的 sync change。

例如：

```text
1001 create Todo A
1002 update Course B
1003 delete Todo C
```

客户端保存：

```text
last_server_cursor = 1003
```

## 3. Entity Revision

每个同步实体拥有 `revision`。

例如：

```text
Todo A revision = 5
```

客户端修改时必须携带：

```text
baseRevision = 5
```

## 4. Operation

```json
{
  "operationId": "uuid",
  "entityType": "todo",
  "entityId": "uuid",
  "operation": "update",
  "baseRevision": 5,
  "changes": {
    "title": "新的标题"
  }
}
```

## 5. Client Mutation Flow

```text
User Action
 -> local SQLite/IndexedDB transaction
 -> update local entity
 -> append pending operation
 -> render immediately
 -> background sync
```

客户端不能依赖服务器成功响应后才更新 UI。

## 6. Push Idempotency

`operationId` 全局唯一。

服务器必须记录已经处理过的 operation。

重复发送同一个 operation 不得造成第二次业务效果。

## 7. Pull

```http
GET /api/v1/sync/changes?after=1000&limit=500
```

返回变更以及下一 cursor。

## 8. Push

```http
POST /api/v1/sync/push
```

请求：

```json
{
  "baseCursor": 1003,
  "operations": []
}
```

## 9. Normal Case

若 entity revision == baseRevision：

直接应用 operation。

## 10. Concurrent Case

若 entity revision != baseRevision：

服务器必须判断：

```text
Base
Local
Server
```

进行 field-aware three-way merge。

## 11. Auto Merge

例如：

```text
Base:
 title=A
 priority=normal

Local:
 title=B
 priority=normal

Server:
 title=A
 priority=high
```

可以自动合并：

```text
 title=B
 priority=high
```

## 12. Conflict

如果：

```text
Base:
 title=A

Local:
 title=B

Server:
 title=C
```

则产生冲突。

第一版 UI 提供：

- 保留本地
- 保留云端

未来可以扩展逐字段手动合并。

## 13. Conflict Response

服务器返回：

```json
{
  "accepted": [],
  "merged": [],
  "conflicts": [
    {
      "operationId": "...",
      "entityType": "todo",
      "entityId": "...",
      "base": {},
      "local": {},
      "server": {},
      "conflictingFields": ["title"]
    }
  ],
  "serverCursor": 1008
}
```

## 14. Tombstone

删除不能立即从同步系统中消失。

服务器必须留下 tombstone：

```text
entityType
entityId
revision
syncSeq
deletedAt
```

## 15. Client Delete

客户端离线删除：

1. 本地标记 deleted
2. 创建 delete operation
3. UI 隐藏
4. 后台同步

## 16. Hard Refresh

不得删除 pending operations。

过程：

```text
pause sync
preserve pending operations
clear derived/cache state
pull authoritative snapshot
rebuild local entities
replay pending operations
resume sync
```

如果 replay 发现冲突，进入标准 conflict UI。

## 17. Sync Atomicity

单个 operation 必须原子执行。

同一个 MCP Change Set 则要求整个 Change Set 在单事务内提交。
