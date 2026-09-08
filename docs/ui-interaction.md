# UI Interaction

## 1. Week View

默认：

- 横向 7 天
- 纵向 24 小时
- 当前时间橙色横线
- 课程
- Recurring Schedule
- Todo Block
- Deadline 红线

## 2. Time Axis

时间轴是连续时间，不是简单的 24 个离散格子。

Period 模板只是课程和吸附的参考。

## 3. Folding

支持：

- 凌晨折叠
- 午休折叠
- 夜间折叠

折叠只是视觉压缩，不能改变真实时间。

即使折叠，也必须明显区分：

- 上午
- 下午
- 晚上

## 4. Merge Periods

如果多个连续节次组成连堂课，可以合并为一个视觉块。

是否显示中间下课时间是用户设置，而不是数据库语义。

## 5. Event Layering

当 Todo Block 与 Course 重叠：

```text
Course
Todo Block
```

Todo Block 在视觉层叠于 Course 之上，同时显示明显的冲突状态。

建议采用透明度、边框、斜线纹理或冲突图标表达，而不要依赖颜色 alone。

## 6. Drag

Course：

拖动具体 occurrence 时，默认只修改这一周这一节课程。

Todo Block：

拖动只修改当前 Block。

整个系列的修改必须通过编辑菜单明确选择。

## 7. Resize

事件块上下边界均可拖动。

- 拖顶部：修改 startAt
- 拖底部：修改 endAt

不得跨午夜。

## 8. Snap

默认吸附到课程上下课时间 / period boundary。

建议支持：

```text
period
5_minutes
free
```

默认：

- 从课程空档选时间 -> period
- 自定义输入 -> 5 分钟

## 9. Creating Todo from Week View

点击空闲区域：

```text
Create Todo Block
```

可以：

- 选择某一节
- 连续选择多节
- 自定义 start/end

创建后马上进入本地状态，后台同步。

## 10. Edit Scope Menu

周期性对象：

```text
仅这一次
这一次及以后
整个系列
```

必须在一次操作中清楚表达，不要隐藏在多层弹窗。

## 11. Month View

展示：

- 课程
- Todo Block
- Deadline
- Recurring Schedule

Deadline 使用高辨识度红色标志。

## 12. Todo UX

创建 Todo 默认：

```text
one_off
```

高级设置中：

```text
project
```

Recurring Schedule 不放进 Todo 类型选择，单独入口。

## 13. Todo Block Note

编辑 Block 时提供短备注：

```text
这一时段准备完成什么？
```

## 14. Current Time

每分钟更新一次。

只刷新 current time indicator。
