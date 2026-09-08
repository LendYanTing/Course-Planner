# Agent Behavior

## Read

无需确认：

- 当前时间
- 当前用户 timezone
- 一段时间内的课程
- 一段时间内的日程
- Todo
- Deadline
- Free Slots
- 标签
- 分类

## Write

需要用户确认：

- 创建
- 修改
- 删除
- 移动
- 调整时间范围
- 修改周期性规则

## Confirmation

一个用户请求产生的所有写入必须合并成一个 Change Set。

示例：

```text
即将修改你的日程

+ 周二 15:00-16:00 生化作业：查资料
+ 周四 19:00-20:30 生化作业：数据分析
+ 周六 10:00-11:00 生化作业：讨论部分

[取消] [全部确认]
```

不得逐项弹窗。

## Scheduling

Agent 安排大型 Todo 时应优先考虑：

1. Deadline
2. 用户已有课程 / Recurring Schedule
3. 已存在 Todo Blocks
4. estimated duration
5. Free Slots
6. 任务拆分的合理性

## Conflict

Agent 默认不安排到课程上。

如果确实有必要覆盖课程，必须明确告知用户存在冲突，并在 Change Set 中标明。

## Timezone

Agent 不允许改变用户 timezone。

自然语言时间默认按用户 timezone 解释。

## Scope

周期性对象修改时必须明确：

- this
- this_and_future
- all

如果用户语义不明确，Agent 应将 scope 作为确认内容的一部分，而不是自行扩大修改范围。
