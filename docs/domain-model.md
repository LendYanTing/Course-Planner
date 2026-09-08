# Domain Model

## 1. User

```text
User
- id UUID
- username
- email nullable
- password_hash
- timezone IANA string
- created_at
- updated_at
```

`timezone` 创建账户时确定，之后不可修改。

## 2. Academic Calendar

代表一个学期：

```text
AcademicCalendar
- id
- user_id
- name
- first_day DATE
- total_weeks INT
- created_at
- updated_at
- revision
- deleted_at nullable
```

## 3. Period Template

代表学期的课节时间。

```text
PeriodTemplate
- id
- calendar_id
- period_no
- start_local TIME
- end_local TIME
```

要求：

- `start_local < end_local`
- 不跨午夜
- 同一 Calendar 中时间定义必须可排序
- 是否显示下课间隔由 UI 偏好决定，不改变实际时间

## 4. Course

```text
Course
- id
- calendar_id
- name
- teacher nullable
- location nullable
- color nullable
- notes nullable
- created_at
- updated_at
- revision
- deleted_at nullable
```

## 5. Course Meeting / Series

一门课程可以有一个或多个周期安排。

```text
CourseMeeting
- id
- course_id
- weekday 1..7
- period_start
- period_end
- week_rule
- created_at
- updated_at
- revision
- deleted_at nullable
```

例如：周一第 1-3 节，1-16 周。

## 6. Recurring Schedule

用户自定义的周期性安排，功能类似自定义课程。

```text
RecurringSchedule
- id
- user_id
- title
- color
- weekday(s)
- period rule or local time rule
- date/week range
- notes nullable
- created_at
- updated_at
- revision
- deleted_at nullable
```

它：

- 可以按课程方式使用“第几周”安排
- 可以使用自定义具体时间
- 没有 deadline
- 没有 Todo 完成状态
- 可以单次、这次及以后、整个系列地修改/删除

内部统一理解为一个 recurrence series。

## 7. Todo

Todo 表示任务本身：

```text
Todo
- id
- user_id
- title
- description nullable
- category_id nullable
- priority
- status
- estimated_minutes nullable
- color nullable
- deadline_at nullable
- created_at
- updated_at
- revision
- deleted_at nullable
```

### Todo 类型

```text
one_off
project
```

重复性安排不作为 Todo 类型；重复任务属于 `RecurringSchedule`。

### Todo Status

```text
todo
in_progress
completed
cancelled
```

## 8. Todo Block

```text
TodoBlock
- id
- todo_id
- start_at UTC
- end_at UTC
- block_note nullable
- status
- created_at
- updated_at
- revision
- deleted_at nullable
```

`block_note` 用于说明该时间块具体完成哪一部分工作。

例如：

```text
Todo: 完成生化大作业

Block 1: 查资料和整理文献
Block 2: 分析实验数据
Block 3: 撰写讨论部分
```

Todo 可以有多个 Block。

## 9. Deadline

Deadline 不是 Block，是一个时间点：

```text
todo.deadline_at
```

它可以在周视图显示为红线，在月视图显示为红色标记。

## 10. Tags

```text
Tag
- id
- user_id
- name
- color nullable
```

多对多：

```text
TodoTag
- todo_id
- tag_id
```

## 11. Category

```text
TodoCategory
- id
- user_id
- name
- color
```

## 12. Recurrence Override

课程与 RecurringSchedule 的具体 occurrence 都允许临时修改。

建议抽象：

```text
OccurrenceOverride
- id
- series_type
- series_id
- occurrence_date_local
- action
- replacement_start_at nullable
- replacement_end_at nullable
- replacement_period_start nullable
- replacement_period_end nullable
- metadata patch
```

`action` 至少：

```text
move
update
cancel
```

## 13. Series Editing

必须支持：

```text
THIS
THIS_AND_FUTURE
ALL
```

### THIS

生成当前 occurrence 的 override。

### THIS_AND_FUTURE

从当前 occurrence 切断原 series，并生成后半段 series。

### ALL

修改 / 删除整个 series。

## 14. CalendarEvent Projection

用于客户端展示，不要求一一对应数据库表。

```text
CalendarEvent
- id
- type
- title
- start_at UTC
- end_at UTC nullable
- all_day false
- source_type
- source_id
- conflict_state
- metadata
```

`conflict_state`：

```text
none
soft_conflict
hard_conflict
```

## 15. Conflict Semantics

### Course vs Course

默认属于 hard conflict。

### RecurringSchedule vs Course

soft conflict。

### TodoBlock vs Course

soft conflict。

人工创建 Todo Block 允许覆盖课程，但 UI 必须清晰提示。

Agent 默认避开课程时间，除非用户明确要求强行安排。

## 16. No Cross-Midnight Rule

以下对象单个时间块禁止跨午夜：

- CourseMeeting
- RecurringSchedule occurrence
- TodoBlock

判断以用户 timezone 的本地自然日为准。

```text
23:00 -> 01:00
```

必须被 UI 和 Backend Domain Service 双重拒绝。
