# Phase 8：新建待办与待办页 UI 彻底重设计（消除线框感与认知负担）

## 1. 阶段目标与痛点分析

从用户实机录屏来看，当前「新建待办（`TodoEditorSheet`）」和「待办列表（`TodoPage`）」虽然把部分选项放进了折叠栏，但视觉与交互依然非常杂乱：
1. **满屏生硬线框（Wireframe Soup）**：
   - 标题输入框一个大线框、提醒时间一个大通栏线框、下面 4 个带框的快捷时间 Chip（还因为放不下折成了两行，`自定义` 孤零零掉在第二行）、下面又是一个带线框的「排入日程时间表」、下面又是 4 个带框的优先级 Chip、展开更多后又是「一次性 | 项目」大线框和原生下拉框。视觉碎片化极其严重。
2. **概念打架，强迫用户思考底层模型**：
   - 用户只是想设个「截止时间」，却看到按钮写着「设置提醒时间」，底下还有一行小字教育用户“提醒时间用于一次性事情，截止时间请去更多选项里切项目类型”——导致用户必须先点开「更多选项」→ 把「一次性」切成「项目」→ 再滚回上面看它变成「截止时间」。
3. **待办列表页 (`TodoPage`) 缺乏卡片层次**：
   - 列表项只是平铺的原生 `ListTile` + 方框 `Checkbox`，没有 SukiSU 的分段卡片（`SegmentedColumn`）质感。

本阶段将运用 Phase 7 建立的 **SukiSU 风格 `AppSegmentedColumn` + `AppIconTile` + 无边框填充卡片**，对 `TodoEditorSheet` 和 `TodoPage` 进行彻底的视觉与交互重设计。

---

## 2. 全新「新建/编辑待办」设计规范（SukiSU 极简分段卡片式）

### 整体布局结构（自上而下仅 3 个干净的视觉块）

#### 视觉块 1：顶部标题栏 + 沉浸式无边框输入卡（标题 + 备注合一）
- **顶部栏**：左侧标题 `新建待办` / `编辑待办`（`18sp, FontWeight.w700`），右侧直接放置圆润的 `FilledButton` **「保存」** 胶囊按钮（同时底部也保留通栏「保存」按钮，方便单手大拇指操作与兼容测试）。
- **沉浸式输入卡（一个圆角 `24dp`、底色为 `colorScheme.surfaceBright` / `surfaceContainerHigh` 的柔和容器）**：
  - **上半部（标题行）**：大字号（`17sp, FontWeight.w600`）**完全无边框**（`InputBorder.none`）的标题 `TextField`（`hintText: '准备做什么？'`），右侧内嵌柔和圆形背景的 `VoiceInputButton`。
  - **中间**：一条极淡的 `0.5dp` 内缩分割线（`colorScheme.outlineVariant.withValues(alpha: 0.35)`）。
  - **下半部（备注行）**：直接在标题下方提供轻量无边框的备注/描述 `TextField`（`13.5sp`，`minLines: 1, maxLines: 3`，`InputBorder.none`，`hintText: '添加备注、要求或步骤（可选）…'`）。
  - **为什么这样好**：既把「描述」从折叠抽屉里解放出来，又和标题融合在同一张圆角卡片里，**0 线框、0 视觉杂乱**！

#### 视觉块 2：时间与排期分段卡片组（`AppSegmentedColumn`，外圆角 24dp、内圆角 6dp、间距 2dp）
包含 2 个分段卡片项：
1. **分段项 A：截止 / 提醒时间**
   - **第一行**：左侧 `AppIconTile(icon: Icons.event_available_outlined)` + 中间主标题（不再强迫用户去切类型，直接显示当前选中的时间，未选时显示**「设置提醒时间」** / **「设置截止时间」**；保留一个无外框或融入式 `OutlinedButton` 以 100% 兼容 `todo_editor_timezone_test.dart`！）+ 右侧清除按钮 `Icons.close`（当已选时间时）。
   - **第二行（单行横向滚动的紧凑胶囊条 `SingleChildScrollView(scrollDirection: Axis.horizontal)`）**：
     - `今天 22:00` · `明天 18:00` · `周日 23:59` · `自定义…`
     - 使用 `ChoiceChip` / `ActionChip`（无边框 `BorderSide.none`，圆角 `999` 胶囊），因为是 `Row` 横向滚动，**4 个胶囊永远整齐排在同一行，绝不丑陋折行**！
     - **彻底删除**原本那句啰嗦的灰色说明文字（`"提醒时间用于「到点做一下」的一次性事情..."`）！
2. **分段项 B：排入日程时间表（分配执行时间块）**
   - **开关行**：左侧 `AppIconTile(icon: Icons.more_time_rounded)` + 标题 `排入日程时间表`（副标题：`在课表/周视图中预留专门的执行时间段`）+ 右侧 SukiSU 弹簧开关 `AppSwitch`。
   - **展开内容（当开启时，平滑展示在同一个分段项内部）**：
     - 每个时间块采用一张柔和的内嵌小卡（`colorScheme.surfaceContainerHighest.withValues(alpha: 0.55)`, 圆角 `16dp`）：
       - 顶部一行：日期胶囊（`今天` / `明天` / `M月d日`） + 时间段胶囊（`19:00 – 20:00`） + 时长快选（`45分` · `1小时` · `2小时`） + 删除图标；
       - 底部一行：无边框紧凑备注输入（`hintText: '这一段具体做什么？（如：查文献）'`）。
     - 底部一个清爽的 `+ 添加执行时间段` 按钮（当时间段 `> 1` 时，自动将任务标记为多阶段项目，完全不需要用户操心！）。

#### 视觉块 3：属性分段卡片组（`AppSegmentedColumn`：优先级、分类与标签、预计时长）
不再用粗糙的折叠面板包一堆线框，而是用 3 行干净的 `AppSegmentedColumn` 条目一眼尽览：
1. **分段项 A：优先级**
   - 左侧 `AppIconTile(icon: Icons.flag_outlined)` + 标题 `优先级` + 右侧紧凑排列 4 个胶囊按钮（`低` · `普通` · `高` · `紧急`，当前选中项高亮为对应语义色或 `primaryContainer`）。
2. **分段项 B：分类**
   - 左侧 `AppIconTile(icon: Icons.folder_outlined)` + 标题 `分类` + 右侧水平滚动胶囊（`无` + 已有分类胶囊 + `+ 新建` 胶囊）。**直接点胶囊即选，彻底干掉丑陋笨重的 `DropdownButtonFormField`！**
3. **分段项 C：标签与预计时长（可展开或单行胶囊）**
   - 左侧 `AppIconTile(icon: Icons.sell_outlined)` + 标题 `标签与更多`（右侧摘要显示已选标签数 / 预计时长，点击展开标签 Chip 组、预计时长 `30分 / 60分 / 120分` 快选与类型切换）。

---

## 3. 待办列表页 (`TodoPage`) SukiSU 风格卡片化升级

1. **分类分组 (`_CategoryGroup`) 卡片化**：
   - 每个分类标题采用带彩色圆点与计数徽章的清爽分组头（`padding: EdgeInsets.fromLTRB(18, 14, 18, 6)`）。
   - 该分类下的所有 `_TodoTile` 不再是裸露在背景上的平铺 `ListTile`，而是放入 **`AppSegmentedColumn`** 中（外圆角 `24dp`、相邻内圆角 `6dp`、间距 `2dp`）！
2. **待办条目 (`_TodoTile`) 精细化**：
   - 左侧勾选框采用大圆角（`Checkbox(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)))`）；
   - 标题字号 `15.5sp, FontWeight.w600`；
   - 截止时间、分类、标签、进度块（`0/1 块`）采用精致的圆角胶囊 `_Pill`；
   - 右侧保留一键排期图标 `Icons.more_time` 与更多操作菜单。

---

## 4. 涉及文件清单

### 修改文件
- `flutter/lib/presentation/todo/todo_page.dart` — 按照上述 3 大视觉块重构 `TodoEditorSheet`，并将 `TodoPage` 的列表分组升级为 `AppSegmentedColumn` 分段卡片风格。
- `flutter/test/todo_editor_timezone_test.dart` — 保持所有现有时区测试通过，并验证新布局下无 overflow。
- `flutter/test/todo_page_sorting_test.dart` — 验证分段卡片化后的待办列表排序与分组渲染测试全部通过。

---

## 5. 硬性兼容检查点与验收标准

1. **必须保持 `todo_editor_timezone_test.dart` 的 3 个核心 Widget 断言兼容**：
   - 页面中仍能通过 `find.text('设置提醒时间')` 找到一个 `OutlinedButton`（可以把该 `OutlinedButton` 放在「截止/提醒时间」分段行的右侧或主位置，设置 `style: OutlinedButton.styleFrom(side: BorderSide.none, backgroundColor: scheme.surfaceContainerHighest)` 让它既有无边框胶囊的高颜值，又满足 `w is OutlinedButton` 的测试断言！）。
   - 当 `userTime == null` 时，该 `OutlinedButton` 的 `onPressed` 为 `null`（disabled），且渲染文本 `'用户时区未就绪，暂时无法设置或显示时间。'`。
   - 快捷胶囊 `find.text('今天 22:00')`、`find.text('明天 18:00')`、`find.text('周日 23:59')`、优先级 `ChoiceChip`、`排入日程时间表` 开关等文本标识全部保留。
2. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试 100% 绿灯。
