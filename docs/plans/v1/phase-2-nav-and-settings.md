# Phase 2：Tab 瘦身（3-Tab 日程合一）与设置页分类重构

## 1. 阶段目标

在 Phase 1 完成本地化改造的基础上，重构应用的主导航骨架与设置页信息架构：
1. **Tab 瘦身（4 Tab → 3 Tab）**：
   - 将原本分离的「周视图（含时间轴/课表切换）」和「月视图」合并为第一个 Tab **「日程」**（顶栏分段切换：`课表 | 周 | 月`）。
   - 底栏精简为 3 个 Tab：**`日程`**、**`待办`**、**`设置`**。
   - 同时对 `LiquidFloatingNavBar` 进行视觉瘦身（缩小胶囊高度、紧凑边距与字号，减少对课表底部可视区域的遮挡）。
2. **设置页模块化分类重构**：
   - 彻底告别原本 `settings_page.dart` 1200+ 行、20 多个条目平铺一屏的杂乱结构。
   - 主设置页按 **5 大分类卡片分组** 收纳，并将「云同步与服务器设置」「外观与课表显示设置」抽离为整洁的二级页面。

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `flutter/lib/presentation/home_shell.dart` — 底部导航栏与 `StatefulNavigationShell`
- `flutter/lib/presentation/widgets/liquid_floating_nav_bar.dart` — 液态玻璃底栏组件
- `flutter/lib/app/router.dart` — `GoRouter` 的 `StatefulShellRoute.indexedStack` 路由表
- `flutter/lib/presentation/calendar/week_page.dart` — 周视图与课表视图容器
- `flutter/lib/presentation/calendar/month_page.dart` — 月视图页面
- `flutter/lib/presentation/settings/settings_page.dart` — 现有设置页
- `flutter/lib/state/prefs.dart` — `WeekViewModeController` 等本地偏好

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/presentation/settings/appearance_settings_page.dart` — 「外观与课表显示」二级设置页（收纳底栏外观、中午分界点、课表文字行数、月视图格子高度，并为 Phase 3 的莫奈取色/背景壁纸/卡片透明度预留插槽）。
- `flutter/lib/presentation/settings/sync_settings_page.dart` — 「云同步与服务器」二级设置页（收纳云端账号登录/退出、自动云同步开关、立即同步、冲突处理、重置网络、硬刷新、服务器地址配置）。

### 修改文件
- `flutter/lib/state/prefs.dart` — 将 `WeekViewModeController` 扩展为支持三态：`grid`（课表）、`timeline`（周时间轴）、`month`（月视图），默认值为 `grid`（学生最常用的课表视图，同时保留对旧值的兼容）。
- `flutter/lib/presentation/calendar/week_page.dart` & `flutter/lib/presentation/calendar/month_page.dart` — 在 `WeekPage` 中嵌入月视图模式（或提取 `MonthViewContent` 组件供 `WeekPage` 直接渲染），顶栏右侧提供紧凑的三段切换控件 `课表 | 周 | 月`，点击月视图的某一天可直接跳回该周的课表/周视图。
- `flutter/lib/presentation/home_shell.dart` — 底栏改为 3 个 `LiquidNavItem`：`日程`（`Icons.calendar_today_outlined` / `Icons.calendar_today`）、`待办`（`Icons.checklist_outlined` / `Icons.checklist`）、`设置`（`Icons.settings_outlined` / `Icons.settings`）。
- `flutter/lib/presentation/widgets/liquid_floating_nav_bar.dart` — 底栏胶囊瘦身：`capsuleHeight` 从 `64` 调优为 `54`（更灵巧精致），`sideInset` 在 3 Tab 下自适应缩窄（或限制最大宽度居中悬浮）。
- `flutter/lib/app/router.dart` — `StatefulShellRoute.indexedStack` 从 4 个 branch 调整为 3 个 branch（`/home/week`、`/home/todo`、`/home/settings`）；保留 `/home/month` 作为兼容重定向或子路由，新增 `/settings/appearance` 与 `/settings/sync` 路由。
- `flutter/lib/presentation/settings/settings_page.dart` — 重构为分组卡片式设置主页，代码量削减 50% 以上。
- `flutter/test/liquid_nav_bar_test.dart`、`flutter/test/week_view_switch_test.dart`、`flutter/test/month_view_widget_test.dart` — 适配 3-Tab 与三视图切换测试。

---

## 4. 详细设计与分步实施指南

### Step 1：扩展 `WeekViewModeController` 为三视图模式 (`grid` / `timeline` / `month`)

1. 在 `flutter/lib/state/prefs.dart` 中：
   ```dart
   class WeekViewModeController extends Notifier<String> {
     static const timeline = 'timeline';
     static const grid = 'grid';
     static const month = 'month';

     static const _key = 'week_view_mode';

     @override
     String build() {
       _restore();
       return grid; // 默认进入课表视图（若已有测试断言默认 timeline，请检查 week_view_switch_test.dart 并保持兼容）
     }

     Future<void> _restore() async {
       try {
         final v = await ref.read(prefStoreProvider).read(_key);
         if (v == timeline || v == grid || v == month) state = v!;
       } on Object {}
     }
     ...
   }
   ```
   > **兼容提示**：先检查 `flutter/test/week_view_switch_test.dart` 和 `flutter/test/helpers/week_page_harness.dart` 对默认 `weekViewModeProvider` 的预期。如果现有测试依赖初始状态为 `timeline`，可以让 `WeekViewModeController.build()` 默认返回 `timeline`，或者在顶栏提供三态切换按钮的同时保留原有切换测试语义。

### Step 2：在日程页整合 `课表 | 周 | 月` 三视图

1. **重构 `flutter/lib/presentation/calendar/month_page.dart`**：
   - 提取可复用的 `MonthViewContent` 组件（接收 `anchorUtc`, `onSelectDate`, `onShiftMonth` 等参数），同时保留 `MonthPage` 外壳以确保 `flutter/test/month_view_widget_test.dart` 继续直接通过测试！
2. **升级 `flutter/lib/presentation/calendar/week_page.dart`**：
   - 将 `enum WeekViewMode { timeline, grid, month }` 扩展为三态。
   - 顶栏 AppBar：
     - 左侧标题：当处于 `grid` / `timeline` 时显示周范围 + `第N周 · 本周`；当处于 `month` 时显示 `YYYY年M月` + 当前周次提示。点击标题均可弹出日期选择器跳转。
     - 右侧切换器：使用紧凑的胶囊分段切换器（`SegmentedButton<WeekViewMode>` 或自定义紧凑胶囊 Row，包含 `课表`、`周`、`月` 三个短标签），并保留原有的 `Tooltip` 或测试 Key，确保可读性与单手快速切换。
   - 当处于 `WeekViewMode.month` 时：
     - 导航栏（`‹ 今天 ›`）切换单位变为「上一月 / 今天 / 下一月」。
     - 点击月视图中的任意日期格子，自动将 `_anchor` 设为该日期（或弹出该日日程概览，并提供「查看该周课表」按钮一键切回 `grid`/`timeline`）。

### Step 3：底栏 Tab 瘦身（3 Tab + 胶囊尺寸瘦身）

1. **修改 `flutter/lib/presentation/home_shell.dart`**：
   - `LiquidFloatingNavBar.items` 改为 3 项：
     ```dart
     items: const [
       LiquidNavItem(
         icon: Icons.calendar_today_outlined,
         selectedIcon: Icons.calendar_today,
         label: '日程',
       ),
       LiquidNavItem(
         icon: Icons.checklist_outlined,
         selectedIcon: Icons.checklist,
         label: '待办',
       ),
       LiquidNavItem(
         icon: Icons.settings_outlined,
         selectedIcon: Icons.settings,
         label: '设置',
       ),
     ],
     ```
2. **修改 `flutter/lib/app/router.dart`**：
   - `StatefulShellRoute.indexedStack` 的 `branches` 调整为 3 个：
     - Branch 0: `/home/week` -> `WeekPage()`
     - Branch 1: `/home/todo` -> `TodoPage()`
     - Branch 2: `/home/settings` -> `SettingsPage()`
   - 增加一条顶层兼容路由或重定向：当导航到 `/home/month` 时，将 `weekViewModeProvider` 设为 `month` 并跳转到 `/home/week`（或者保留 `/home/month` 指向 `MonthPage`）。
3. **优化 `flutter/lib/presentation/widgets/liquid_floating_nav_bar.dart`**：
   - 将 `capsuleHeight` 从 `64` 减小为 `54`，`cornerRadius` 设为 `27`，图标大小微调为 `22`，文字字号 `11`，水平外边距在大屏/竖屏下更紧凑（可用 `ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360))` 居中展示），大幅减少对底部课表的遮挡感。

### Step 4：设置页分类重构

将 `flutter/lib/presentation/settings/settings_page.dart` 重构为清晰的 **分类卡片式布局**（每个分类使用 `Card` 包裹一组 `ListTile`）：

1. **顶部状态卡（当前模式 & 学期概览）**：
   - 若为本地模式（`session.isLocalMode`）：显示「本地模式（数据保存在本机）」+「当前时区：Asia/Shanghai（点击可修改）」+ 右侧「配置云同步」快捷按钮。
   - 若已登录云端：显示用户名、时区、当前云同步开关状态，点击进入 `/settings/sync`。
2. **分类一：课程与学期**
   - `学期与节次管理` → `/settings/semesters`（副标题显示当前激活学期名与总周数）
   - `课程管理` → `/settings/courses`（副标题显示当前学期课程门数）
   - `周期日程` → `/settings/schedules`
   - `导入课程` → `/settings/import`（副标题：`本地 CSV 导入 / 教务导入`）
   - `标签与分类` → `/settings/tags`
3. **分类二：外观与个性化**
   - `外观与课表定制` → `/settings/appearance`（集中配置主题色、背景壁纸、课程卡片透明度/字号/行数、中午分界点、月视图高度、底栏材质）
4. **分类三：AI 助手与连接**
   - `外部 MCP 连接` → `/settings/mcp`（保留原有 MCP 页面，并为 Phase 5 的「内置 AI 助手设置」预留入口）
5. **分类四：数据与云同步**
   - `云同步与服务器` → `/settings/sync`（内含：自动云同步开关 `SwitchListTile`、服务器地址设置、登录/切换云端账号、立即同步、冲突处理、重置网络连接、硬刷新本地缓存）
   - `导出本地备份` → 直接调用 `_exportBackup`
   - `导入/恢复备份` → `/settings/restore`
6. **分类五：关于**
   - `关于 Course Planner` → `/settings/about`

---

## 5. 测试与验收标准

1. **检查现有测试兼容性**：
   - 更新 `flutter/test/liquid_nav_bar_test.dart`、`flutter/test/week_view_switch_test.dart`、`flutter/test/month_view_widget_test.dart`，确保全部通过。
2. **新增导航与设置分类测试**：
   - 验证 `HomeShell` 底栏只有 3 个 Tab（`日程`、`待办`、`设置`）。
   - 验证在 `WeekPage` 顶栏可以在 `课表`、`周`、`月` 三种视图之间顺畅切换。
   - 验证设置页的 5 大分类卡片渲染正常，点击「外观与课表定制」和「云同步与服务器」能正常打开对应二级页面。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试全部通过。
