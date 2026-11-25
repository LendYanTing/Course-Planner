# Phase 4：人工操作优化（添加任务界面与流程减负）

## 1. 阶段目标

解决当前添加待办（`Todo`）、时间块（`TodoBlock`）和日程时**字段繁杂、层级割裂、思考负担重**的问题：
1. **极简一屏添加待办（减少思考负担）**：
   - 用户最常做的只是「记一件事 + 什么时候截止/什么时候做」。
   - 重构 `TodoEditorSheet`：
     - **首屏核心区**：标题输入框 + **快捷时间胶囊**（`今晚 22:00`、`明天 18:00`、`本周日 23:59`、`自定义`）+ 原本的提醒/截止时间按钮 + **「同时排入日程（时间块）」快捷开关** + 优先级快捷横排 Chip（`低 / 普通 / 高 / 紧急`，取代原本需要点开再选的 Dropdown）。
     - **可折叠更多选项（「更多设置 ▾」）**：将描述、任务类型（一次性/项目，当用户添加多个时间块时自动升级为项目，无需用户事先思考该选哪种类型！）、分类下拉、预计时长、标签收纳到可展开区域（若处于编辑模式且已有这些字段值，则默认展开）。
2. **打通 `Todo` 与 `TodoBlock`（一站式创建）**：
   - 过去用户想把一个任务排进日历，必须：先建待办 → 保存关闭 → 在列表找到该待办 → 点右侧三个点菜单 → 点「时间块」 → 点「添加时间块」 → 选开始结束时间 → 保存。整整 **8 步**！
   - 现在在 `TodoEditorSheet` 内直接提供 **「安排执行时间段（排入课表/周视图）」**：勾选或点击「+ 添加执行时间段」即可直接在同一个弹窗里指定今天/明天的某段时间（或按第几节课吸附），点击「保存」时在单个本地事务中同时写入 `Todo` 和 `TodoBlock`（由 **8 步缩短为 2 步**）。
3. **优化课表/周视图空白格点选快速创建**：
   - 在 `WeekPage`（时间轴）和 `GridViewContent`（课表视图）中点击空白格子时，弹出的快速创建面板（`_QuickCreateSheet`）支持：
     - 模式切换：`新建待办并排期` | `排入已有待办` | `新建周期日程`
     - 时长快捷胶囊：`45分钟(1节)`、`90分钟(2节)`、`1小时`、`2小时`
     - 若从课表视图（`GridViewContent`）点击第 `K` 节空白格，默认将开始/结束时间精准对齐到第 `K` 节（或 `K ~ K+1` 连堂节次）的起止时间！

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `flutter/lib/presentation/todo/todo_page.dart` — `TodoPage`、`_TodoTile`、`TodoEditorSheet`
- `flutter/lib/presentation/todo/todo_blocks_sheet.dart` — `TodoBlocksSheet` 与 `_BlockEditor`
- `flutter/lib/state/todo_controller.dart` — `TodoController` 的 `save`、`setStatus`、`delete`
- `flutter/lib/presentation/calendar/week_page.dart` — `_onEmptySlotTap` 与 `_QuickCreateSheet`
- `flutter/lib/presentation/calendar/grid_view.dart` — 课表视图手势与空白格点击支持
- `flutter/test/todo_editor_timezone_test.dart` — **重要：检查现有测试对 `TodoEditorSheet` 按钮文案的断言**

---

## 3. 涉及文件清单

### 修改文件
- `flutter/lib/state/todo_controller.dart` — 扩展 `TodoController.save(...)`，支持可选传入 `List<({DateTime startUtc, DateTime endUtc, String? note})> initialBlocks`，在保存待办的同时一键创建关联的 `TodoBlock`；当传入多个时间块时自动将 `type` 设为 `TodoType.project`。
- `flutter/lib/presentation/todo/todo_page.dart` — 重构 `TodoEditorSheet` UI 布局（快捷时间胶囊、一站式添加执行时间段、横排优先级 ChoiceChip、可折叠高级项）以及 `_TodoTile` 上的快捷「+ 排期」入口。
- `flutter/lib/presentation/calendar/week_page.dart` & `flutter/lib/presentation/calendar/grid_view.dart` — 为 `GridViewContent` 空白节次单元格增加点击快速创建回调 `onEmptyCellTap(tz.TZDateTime day, int periodStart, int periodEnd, int startMin, int endMin)`；升级 `_QuickCreateSheet` 支持时长胶囊与节次对齐。
- `flutter/test/todo_editor_timezone_test.dart` & `flutter/test/todo_controller_test.dart` — 确保原有测试 100% 通过，并新增一站式创建 `Todo + TodoBlock` 的测试。

---

## 4. 详细设计与分步实施指南

### Step 1：保留测试兼容性的前提下重构 `TodoEditorSheet`

> **硬性兼容要求**：`flutter/test/todo_editor_timezone_test.dart` 中断言了：
> 1. 默认存在一个 `OutlinedButton` 包含文本 `'设置提醒时间'`（当 `_type == TodoType.oneOff` 且未选时间时）；
> 2. 当 `userTime == null` 时，该 `OutlinedButton` 为 disabled，且页面上显示文本 `'用户时区未就绪，暂时无法设置或显示时间。'`。
> **因此在重构 `TodoEditorSheet` 时，务必保留这个 `OutlinedButton` 及其文案逻辑！**

1. **首屏布局（无需滚动即可完成 90% 的日常输入）**：
   - **第一行：标题输入框**（`autofocus: !isEdit`，带清晰的 `hintText: '要做什么？（例如：完成高数作业第三章）'`）。
   - **第二行：提醒/截止时间区**：
     - 保留原有的 `OutlinedButton.icon`（文案为 `_deadlineLabel(userTime)`，即 `'设置提醒时间'` / `'设置截止时间'`）。
     - 在按钮下方紧跟一排紧凑的 **快捷时间 ActionChip**（仅当 `userTime != null` 时可点）：
       - `今天 22:00`
       - `明天 18:00`
       - `周日 23:59`
       - 点击任意 Chip 直接计算出 `userTime.utcFromLocalParts(...)` 赋值给 `_deadline`，省去弹出两次 DatePicker + TimePicker 的繁琐操作！
   - **第三行：「同时排入日程（时间块）」内嵌卡片（新建模式或编辑模式下均可直接加块）**：
     - 提供一个轻量开关或按钮：`ActionChip` / `SwitchListTile(dense: true, title: Text('排入日程时间表'))`。
     - 展开后可直接选择日期（`今天` / `明天` / `自定义日期`）和起止时间（默认当前整点后 1 小时，附带 `45分` / `1小时` / `2小时` 快捷时长胶囊），也可点击「+ 再加一段」（当超过 1 段时，自动将 `_type` 切换为 `TodoType.project`，无需用户手动去切类型！）。
   - **第四行：优先级单行快选**：
     - 使用 4 个紧凑 `ChoiceChip` 横排展示：`低`、`普通`、`高`、`紧急`，一眼可见、一点即选。
2. **折叠高级区（「更多选项：分类、标签、描述、类型 ▾」）**：
   - 使用 `ExpansionTile` 或自定义折叠面板（默认折叠；若 `isEdit` 且原有待办包含描述、分类、标签或为 `project` 类型，则默认展开）。
   - 内部放置：
     - 任务类型 `SegmentedButton<TodoType>`（一次性 / 项目）
     - 分类选择 + 快速新建分类按钮
     - 预计时长输入框（附带 `30分`、`60分`、`120分` 快捷填入按钮）
     - 标签 `FilterChip` 列表 + 新建标签按钮
     - 描述输入框

---

### Step 2：扩展 `TodoController.save` 支持一站式写入 `Todo + TodoBlock`

在 `flutter/lib/state/todo_controller.dart` 中：
1. 为 `save(...)` 增加可选参数：
   ```dart
   List<({DateTime startUtc, DateTime endUtc, String? blockNote})> newBlocks = const [],
   ```
2. 当 `newBlocks.length > 1` 时，自动确保保存的 `TodoType` 为 `TodoType.project`。
3. 在新建或更新 `Todo` 得到 `todoId` 后，遍历 `newBlocks`，校验不跨午夜（`userTime.isSameLocalDay(b.startUtc, b.endUtc)`），然后调用 `repo.localCreate(entityType: EntityTypes.todoBlock, snapshot: { 'todoId': todoId, 'startAt': b.startUtc, 'endAt': b.endUtc, 'blockNote': b.blockNote, 'status': BlockStatus.scheduled.wire })`。
4. 在 `_TodoTile`（待办列表项）右侧除了原有的三点菜单外，增加一个直观的快捷图标按钮 `IconButton(icon: Icon(Icons.more_time, size: 20), tooltip: '排入日程', onPressed: onManageBlocks)`，让用户无需点开二级 PopupMenu 就能一键给已有待办排期。

---

### Step 3：课表 (`GridViewContent`) 与周时间轴空白处点选增强

1. **在 `flutter/lib/presentation/calendar/grid_view.dart` 中支持点击空白课表单元格快速创建**：
   - 为 `GridViewContent` 增加可选回调：
     ```dart
     final void Function(tz.TZDateTime day, int startMinute, int endMinute, int periodNo)? onEmptySlotTap;
     ```
   - 当用户点击课表网格中没有课程覆盖的空白节次行（第 `periodNo` 节，起止分钟为 `row.start` ~ `row.end`）时，触发 `onEmptySlotTap(days[dayIdx], row.start, row.end, row.periodNo)`。
2. **升级 `flutter/lib/presentation/calendar/week_page.dart` 中的 `_QuickCreateSheet`**：
   - 接收初始 `startMinute` 和可选的 `initialDurationMinutes`（从课表点击进来时，默认时长即为该节课的时长，如 45 分钟；并可一键点「连堂 2 节」自动把结束时间对齐到下一节下课时间！）。
   - 面板内提供：
     - 顶部模式切换：`新建待办时间块` | `关联已有待办`
     - 标题输入框（当选「新建待办时间块」时）或待办下拉选择（当选「关联已有待办」时）
     - 时间段显示与快捷时长胶囊：`1节课(45m)`、`2节课(90m)`、`1小时`、`2小时`
     - 可选的「同时将该时间设为截止时间」勾选框

---

## 5. 测试与验收标准

1. **现有时区与编辑器测试 100% 兼容**：
   - 运行 `flutter test test/todo_editor_timezone_test.dart` 和 `flutter test test/todo_controller_test.dart` 必须直接通过。
2. **新增一站式创建与快捷胶囊测试**：
   - 在 `flutter/test/todo_controller_test.dart` 中新增测试：调用 `todoController.save(...)` 并传入 `newBlocks` 时，验证本地 `SyncStore` 中同时生成了 `todo` 和对应的 `todo_block` 实体；当传入 2 个 `newBlocks` 时，`todo.type` 自动为 `project`。
   - 测试在 `TodoEditorSheet` 中点击快捷时间胶囊（如 `今天 22:00`），验证截止/提醒时间立即更新为用户时区下的 `22:00`。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试全部通过。
