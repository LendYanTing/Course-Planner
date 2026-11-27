# Phase 9：内置 AI 助手独立底栏 Tab 页与完整 Markdown 渲染引擎

## 1. 阶段目标与问题诊断

当前内置 Agent 功能层面已经跑通，但在交互入口和输出渲染上存在 2 个明显短板：
1. **入口位置不便**：
   - 目前 AI 助手入口只是一个放在「待办页」右上角的小图标（在「日程页」甚至没有入口），在手机上单手很难按到。
   - 用户明确希望：**将 AI 助手放到主底栏 Tab 页中作为独立一页**（底栏 4 Tab：`日程` | `待办` | `AI 助手` | `设置`），随时一键直达。
2. **没有适配 Markdown，所有回答都是生硬的 Plain Text**：
   - `flutter/lib/presentation/agent/agent_chat_sheet.dart` 第 275 行直接用 `Text(message.text)` 渲染大模型回复。
   - 当大模型输出标题（`###`）、加粗（`**课程**`）、列表（`- 周一`）、代码块（` ``` `）或表格时，界面上全都是未解析的 `#`、`*`、`|` 原始符号，阅读体验很差。

本阶段将完成 **「AI 助手独立 Tab 页改造」** 与 **「SukiSU 风格完整 Markdown 渲染器」**。

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `flutter/lib/presentation/home_shell.dart` — 底部悬浮导航栏 `HomeShell`
- `flutter/lib/app/router.dart` — `GoRouter` 的 `StatefulShellRoute.indexedStack`
- `flutter/lib/presentation/agent/agent_chat_sheet.dart` — 现有 Agent 聊天面板与 `ChangeSetConfirmationCard`
- `flutter/lib/state/agent_controller.dart` — Agent 会话状态控制器
- `flutter/test/liquid_nav_bar_test.dart` — 底栏导航单元测试

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/presentation/widgets/app_markdown.dart` — 零外部重依赖、100% 适配深浅色与莫奈主题色的 Markdown 渲染组件 `AppMarkdownContent`（支持标题、加粗、斜体、删除线、行内代码、围栏代码块带一键复制、无序/有序列表、引用块、分割线、GFM 表格）。
- `flutter/lib/presentation/agent/agent_chat_page.dart` — 专用于底栏第 3 个 Tab（`/home/agent`）的全屏 AI 助手页面（复用聊天核心逻辑与 `ChangeSetConfirmationCard`，同时适配悬浮底栏 `extendBody` 的底部安全间距）。
- `flutter/test/app_markdown_test.dart` — Markdown 解析与渲染（标题、粗体、列表、代码块、表格）单元测试。

### 修改文件
- `flutter/lib/presentation/home_shell.dart` — 底栏 Tab 升级为 4 项：`日程`、`待办`、`AI 助手`（`Icons.auto_awesome_outlined` / `Icons.auto_awesome`）、`设置`。
- `flutter/lib/app/router.dart` — `StatefulShellRoute.indexedStack` 升级为 4 个 `StatefulShellBranch`：
  - Branch 0: `/home/week` (`WeekPage`)
  - Branch 1: `/home/todo` (`TodoPage`)
  - Branch 2: `/home/agent` (`AgentChatPage`)
  - Branch 3: `/home/settings` (`SettingsPage`)
- `flutter/lib/presentation/agent/agent_chat_sheet.dart` — 将 Assistant 消息气泡中的 `Text(message.text)` 替换为 `AppMarkdownContent(data: message.text)`，并支持长按/点击复制回复内容；导出共享的消息列表、输入框和 `ChangeSetConfirmationCard` 供 `AgentChatPage` 直接复用。
- `flutter/lib/presentation/todo/todo_page.dart` — 移除顶栏右上角多余的 AI 助手小按钮（因为底栏已有常驻的「AI 助手」Tab，顶栏更清爽；若有测试查找该按钮，请检查 `flutter/test/` 并确保无回归）。
- `flutter/test/liquid_nav_bar_test.dart` — 更新或补充 4-Tab 导航测试。

---

## 4. 详细设计与分步实施指南

### Step 1：实现 `AppMarkdownContent` (`flutter/lib/presentation/widgets/app_markdown.dart`)

为了保证离线环境 100% 编译通过且与应用的 `ColorScheme` / 字体栈深度融合，借鉴 SukiSU `MarkdownContent.kt` 编写纯 Dart 的结构化 Markdown 渲染器 `AppMarkdownContent`：

1. **组件签名**：
   ```dart
   class AppMarkdownContent extends StatelessWidget {
     const AppMarkdownContent({
       super.key,
       required this.data,
       this.textColor,
       this.selectable = true,
     });

     final String data;
     final Color? textColor;
     final bool selectable;
   ```

2. **支持的块级语法（Block Parser）**：
   - **围栏代码块（` ```lang ... ``` `）**：
     - 渲染为圆角 `12dp` 的独立容器（底色 `scheme.surfaceContainerHighest` 或深色代码块底色 `scheme.surfaceContainerLowest`）；
     - 顶部紧凑栏显示语言标签（如 `json`、`csv`、`text`）+ 右侧「复制代码」小按钮（点击复制到剪贴板并弹 SnackBar）；
     - 内容使用等宽字体 `monospace`，支持横向滚动。
   - **GFM 表格（`| 表头1 | 表头2 |` + `| --- | --- |` + 数据行）**：
     - 自动识别连续的 `|` 表格行；
     - 渲染为带圆角外框（`BorderRadius.circular(12)`, `Border.all(color: scheme.outlineVariant)`）的表格，表头行底色为 `scheme.secondaryContainer.withValues(alpha: 0.45)` + 加粗文字，支持 `SingleChildScrollView(scrollDirection: Axis.horizontal)` 防止宽表格溢出。
   - **标题（`#` ~ `######`）**：
     - `H1`: `19sp, FontWeight.w700`
     - `H2`: `17sp, FontWeight.w700`
     - `H3`: `15.5sp, FontWeight.w600`
     - `H4~H6`: `14.5sp, FontWeight.w600`
     - 上下带舒适的段落间距（`top: 8, bottom: 4`）。
   - **无序列表（`- `、`* `、`• `）与有序列表（`1. `、`2. `）**：
     - 支持多级缩进（每 2 个前导空格缩进 `14dp`）；
     - 左侧绘制主题色小圆点或高亮序号，右侧 `Expanded` 渲染行内富文本（确保长列表项换行时左边缘对齐，不会折到圆点下方）。
   - **引用块（`> `）**：
     - 左侧 `3.5dp` 宽的 `scheme.primary` 圆角竖条 + `scheme.surfaceContainerHighest.withValues(alpha: 0.4)` 底色与 `10dp` 内边距。
   - **水平分割线（`---` 或 `***`）**：
     - 渲染 `Divider(color: scheme.outlineVariant)`。
   - **普通段落**：
     - 行高 `1.48`，段间距 `6dp`。

3. **支持的行内语法（Inline Span Parser）**：
   - 将行内文本解析为 `List<InlineSpan>`：
     - **行内代码 `` `code` ``**：使用 `TextSpan`（背景色 `scheme.surfaceContainerHighest`，颜色 `scheme.primary`，`fontFamily: 'monospace'`，字号 `13sp`）。
     - **加粗 `**bold**` 或 `__bold__`**：`FontWeight.w700`。
     - **斜体 `*italic*`**：`FontStyle.italic`。
     - **加粗斜体 `***text***`**：`FontWeight.w700` + `FontStyle.italic`。
     - **删除线 `~~strike~~`**：`TextDecoration.lineThrough`。

---

### Step 2：实现全屏 `AgentChatPage` 并挂载到底栏第 3 个 Tab

1. **新建 `flutter/lib/presentation/agent/agent_chat_page.dart`**：
   - 使用 `Scaffold` + `AppTopBar(title: 'AI 助手')`：
     - `actions` 包含：
       - **清空对话按钮**（`IconButton(icon: Icon(Icons.delete_sweep_outlined), tooltip: '清空对话')`）
       - **模型与语音设置按钮**（`IconButton(icon: Icon(Icons.tune_rounded), tooltip: 'AI 设置', onPressed: () => context.push('/settings/agent'))`）
   - 页面主体：
     - 复用 `AgentChatSheet` 的消息流、欢迎卡片（带 SukiSU `AppIconTile` 与快捷指令胶囊）、折叠工具调用行 `_ToolRow`、`ChangeSetConfirmationCard`、以及底部输入栏（含 `VoiceInputButton` 与发送按钮）。
     - **关键布局细节（避让悬浮底栏）**：
       - 因为 `HomeShell` 的 `Scaffold` 开启了 `extendBody: true`，底部的 `LiquidFloatingNavBar` 会悬浮在页面底部上方；
       - 因此 `AgentChatPage` 底部的输入栏必须加上 `Padding(padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom))`，确保输入框和发送按钮永远位于悬浮底栏正上方，绝不被底栏遮挡！

2. **修改 `flutter/lib/presentation/home_shell.dart` 与 `flutter/lib/app/router.dart`**：
   - `HomeShell` 的 `LiquidFloatingNavBar.items` 扩展为 4 项：
     1. `日程` (`Icons.calendar_today_outlined` / `Icons.calendar_today`)
     2. `待办` (`Icons.checklist_outlined` / `Icons.checklist`)
     3. `AI 助手` (`Icons.auto_awesome_outlined` / `Icons.auto_awesome`)
     4. `设置` (`Icons.settings_outlined` / `Icons.settings`)
   - `router.dart` 的 `StatefulShellRoute.indexedStack` 对应配置 4 个 `StatefulShellBranch`（`/home/week`、`/home/todo`、`/home/agent`、`/home/settings`）。

---

## 5. 测试与验收标准

1. **Markdown 渲染单元测试 (`flutter/test/app_markdown_test.dart`)**：
   - 测试包含 `### 标题`、`**加粗**`、`- 列表项`、`` `行内代码` ``、` ```json ... ``` ` 代码块、`| 星期 | 课程 |` 表格的 Markdown 字符串在 `AppMarkdownContent` 中渲染成功，且画面上不再出现裸露的 `###` 或 `**` 符号。
   - 测试代码块上的复制按钮可点击且无异常。
2. **4-Tab 底栏与 Agent 页测试**：
   - 验证 `HomeShell` 底栏渲染 `日程`、`待办`、`AI 助手`、`设置` 4 个 Tab，点击 `AI 助手` Tab 能正常切换到 `AgentChatPage`。
   - 验证 `AgentChatPage` 的输入框位于悬浮底栏上方、不会被遮挡。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有现有测试与新增测试全部 100% 通过。
