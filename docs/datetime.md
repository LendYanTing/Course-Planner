# Datetime Contract

## 1. Absolute Time

服务器和数据库中所有绝对时间统一用 UTC。

API 使用 RFC3339，例如：

```text
2026-09-08T01:00:00Z
```

禁止业务 API 发送不带时区的 datetime。

## 2. User Timezone

用户注册时必须选择 IANA timezone，例如：

```text
Asia/Shanghai
Asia/Tokyo
Europe/London
America/Los_Angeles
```

该值创建后不可修改。

## 3. Client Device Timezone

客户端系统 timezone 不参与用户日程解释。

例如：

```text
User timezone: Asia/Shanghai
Device timezone: Asia/Tokyo
```

仍然按 `Asia/Shanghai` 显示和解释用户输入。

## 4. User Input

用户输入本地时间：

```text
2026-09-08 09:00
```

必须解释为：

```text
2026-09-08 09:00 Asia/Shanghai
```

然后转换到 UTC。

## 5. Display

```text
stored UTC
   -> user timezone
   -> UI
```

## 6. Recurrence

按周、按星期、按“第几周”的周期规则属于 local calendar semantics。

因此 recurrence 规则必须与：

- 用户 timezone
- local date
- local time

绑定。

不要把一个本地周期规则单纯存成 UTC 时间再用 UTC 重复计算。

## 7. DST

虽然用户主要可能在 UTC+8 区域，但协议必须正确支持 IANA timezone 的 DST。

如果未来用户使用存在 DST 的 timezone：

- 周期规则按该 timezone 的 local wall-clock 计算
- 生成 occurrence 后再转换成 UTC

## 8. Current Time

服务器提供：

```http
GET /api/v1/meta/time
```

客户端保存 server clock offset：

```text
serverNowUtc - localDeviceNowUtc
```

当前时间线使用：

```text
estimatedServerNowUtc
```

而不是直接依赖设备时钟。

## 9. UI Refresh

当前时间线默认每分钟更新一次。

只有当前时间 indicator 需要频繁刷新，不应导致整个日程树重新渲染。

## 10. No Cross Midnight

对于单个 CourseMeeting、RecurringSchedule TimeBlock、TodoBlock：

```text
localStart.date == localEnd.date
```

否则拒绝。

## 11. API Range

API 的 `start` / `end` 是 UTC instant。

例如：

```http
GET /api/v1/calendar/events?start=2026-09-07T00:00:00Z&end=2026-09-14T00:00:00Z
```

客户端负责根据用户 timezone 计算要显示的 local week，再转换为 UTC 查询范围。
