# Phase 5：内置 Agent、自带本地 MCP Tools 与提示词优化

## 1. 阶段目标

原本的客户端只能生成一个 MCP Token 让外部桌面软件（如 Claude Desktop / Cursor）去连 Go 服务端。本阶段要在 **Flutter 客户端内部直接内置一个完整的 AI 日程规划 Agent**，且**不依赖 Go 服务端即可独立运行**：

1. **自带本地 MCP 同构工具集 (`LocalAgentTools`)**：
   - 在 Flutter 本地直接实现与 `docs/mcp.md` 完全一致的 **10 个 Read Tools**（无需用户确认，Agent 可随时调用以读取当前时间、学期、课程、周期日程、待办、空闲时间段 Free Slots）和 **Write Tools / `preview_changes` + `apply_changes`**。
   - 所有读写直接对接本地 `EntitiesSnapshot`、`EventExpander` 和 `EntityRepo`（离线/纯本地模式下 100% 可用；若开启了云同步，写入本地后也会自动按同步设置同步上云）。
2. **内置 OpenAI 兼容大模型客户端 (`LlmClient`)**：
   - 支持用户配置任意兼容 OpenAI Chat Completions (`POST /v1/chat/completions` with `tools`) 的大模型服务（预设一键填充：**DeepSeek**、**硅基流动 SiliconFlow**、**通义千问 DashScope**、**OpenAI**、**本地 Ollama / 自定义接口**）。
   - API Key 安全存储在 `flutter_secure_storage`（或 `PrefStore`）中。
3. **内置 Agent 聊天交互界面 + Change Set 一次性确认卡片**：
   - 在「日程」和「待办」页面提供悬浮/顶栏 AI 助手按钮，点击弹出 `AgentChatSheet`（或全屏/侧边抽屉）。
   - 严格遵循 `docs/agent-behavior.md`：**一个用户请求产生的所有写入必须合并成一个 Change Set 确认卡片**（清晰展示新增 `+`、修改 `~`、删除 `-` 的每一项明细及软/硬冲突警告），用户点击 **「全部确认」** 后，在单个本地 SQLite 事务内原子写入！严禁逐项弹窗。
4. **提示词优化（Prompt Engineering）**：
   - 内置针对中国大学生课表与任务排期深度优化的 System Prompt：自动注入当前用户时区、当前时间、当前处于第几学期第几周，指导 Agent 遵守「先查 `get_free_slots` 再排期」「大型任务拆分为多个带 `blockNote` 的 `TodoBlock`」「默认避开课程与已有日程」「不跨午夜」等核心准则。

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `docs/mcp.md` — MCP 读写工具集定义与 `preview_changes` / `apply_changes` 契约
- `docs/agent-behavior.md` — Agent 读写行为、排期优先级、冲突提示与一次性确认规则
- `server/internal/mcp/tools.go` & `server/internal/agent/changeset.go` & `server/internal/freeslot/freeslot.go` — 服务端 MCP 工具、ChangeSet 与空闲时间段计算参考实现
- `flutter/lib/sync/expander.dart` & `flutter/lib/state/event_projection.dart` — 本地事件展开与冲突计算
- `flutter/lib/data/repo/entity_repo.dart` — 本地实体事务写入接口

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/domain/free_slot_finder.dart` — 本地空闲时间段（Free Slots）计算器（移植 `server/internal/freeslot/freeslot.go`，剔除课程、周期日程与已有 TodoBlock 占用的时间，返回可用空闲区间）。
- `flutter/lib/agent/agent_config.dart` — LLM 接口配置模型（`baseUrl`, `apiKey`, `model`, `temperature`, 预设服务商模板）及持久化 Provider。
- `flutter/lib/agent/local_agent_tools.dart` — 本地 MCP 同构工具定义（JSON Schema）与执行器（10 个 Read 工具 + `preview_changes` 生成 `LocalChangeSet` + `apply_changes` 原子写入 `EntityRepo`）。
- `flutter/lib/agent/agent_prompts.dart` — 深度优化的系统提示词（System Prompt）构建器与快捷指令（Quick Prompts）模板。
- `flutter/lib/agent/llm_client.dart` — 基于 `Dio` 的 OpenAI Chat Completions + Tool Calling 循环驱动器（支持多轮 tool_calls 自动执行并在遇到 `preview_changes` 时挂起等待用户点击确认卡片）。
- `flutter/lib/state/agent_controller.dart` — 聊天消息流、正在思考状态、待确认 `LocalChangeSet` 状态管理。
- `flutter/lib/presentation/agent/agent_chat_sheet.dart` — 内置 Agent 聊天面板 + 可视化 Change Set 确认卡片 + 快捷指令胶囊。
- `flutter/lib/presentation/settings/agent_settings_page.dart` — 「内置 AI 助手设置」页面（选择预设服务商、填写 API Key / Model、测试连接、自定义附加提示词）。
- `flutter/test/free_slot_finder_test.dart` — 本地空闲时间段计算单元测试。
- `flutter/test/local_agent_tools_test.dart` — 本地 Agent 读写工具与 ChangeSet 预览/原子提交单元测试。

### 修改文件
- `flutter/lib/app/router.dart` — 新增 `/settings/agent` 路由。
- `flutter/lib/presentation/settings/settings_page.dart` — 在「AI 助手与连接」分类卡中新增「内置 AI 助手配置」入口（排在外部 MCP 连接之上）。
- `flutter/lib/presentation/calendar/week_page.dart` & `flutter/lib/presentation/todo/todo_page.dart` — 在顶栏 AppBar 增加「AI 助手」按钮（`Icons.auto_awesome`），点击唤起 `AgentChatSheet`。

---

## 4. 详细设计与分步实施指南

### Step 1：实现本地空闲时段计算器 (`flutter/lib/domain/free_slot_finder.dart`)

移植 `server/internal/freeslot/freeslot.go` 到 Dart：
1. 输入：`EntitiesSnapshot snapshot`, `UserTime userTime`, `DateTime fromUtc`, `DateTime toUtc`, `int minDurationMinutes = 30`, `int dayStartMinute = 8 * 60`（早上 08:00）, `int dayEndMinute = 22 * 60`（晚上 22:00，避免把凌晨 02:00 当作空闲排期给学生！可由参数覆盖）。
2. 利用 `EventProjection(EventExpander(userTime)).project(snapshot, startUtc: fromUtc, endUtc: toUtc)` 获取区间内所有非 deadline 事件（课程、周期日程、已安排的 TodoBlock）。
3. 按用户在 `userTime` 下的每一个本地自然日，在 `[dayStartMinute, dayEndMinute]` 范围内减去所有忙碌区间（合并重叠区间），输出所有长度 `>= minDurationMinutes` 的空闲时间段 `List<FreeSlot>`（含 `dateLocal`, `startUtc`, `endUtc`, `displayStartLocal`, `displayEndLocal`, `durationMinutes`）。

---

### Step 2：实现本地 MCP 同构工具集 (`flutter/lib/agent/local_agent_tools.dart`)

定义 OpenAI Function Calling 格式的 `tools` JSON Schema，并在本地直接执行：

1. **Read Tools（直接返回 JSON 结果给大模型，无需确认）**：
   - `get_current_time`: 返回当前 UTC 时间、用户时区本地时间 `YYYY-MM-DD HH:mm`、星期几、当前激活学期的名称与**当前是第几周**。
   - `get_calendar`: 返回所有学期（`AcademicCalendar`）及每个学期的节次时间表（`PeriodTemplate`，如第 1 节 08:00-08:45）。
   - `get_courses`: 查询指定学期或全部课程及其每周上课安排（`Course` + `CourseMeeting`）。
   - `get_schedule`: 查询指定时间范围内的所有日历事件（展开后的课程、周期安排、时间块、截止时间）。
   - `get_todos`: 按状态（`todo` / `in_progress` / `completed`）、分类或关键词查询待办及其关联的 `TodoBlock`。
   - `get_free_slots`: 调用 `FreeSlotFinder` 查询未来某段时间内的空闲时间段（默认作息 `08:00 - 22:30`）。
   - `get_tags_and_categories`: 返回已有标签和分类列表。

2. **Write Tool（统一收敛为 `preview_changes` 生成确认集）**：
   - 为了让性价比大模型（如 DeepSeek-V3 / Qwen-Plus / GPT-4o-mini）调用最稳定、最不容易漏掉确认步骤，提供统一的写工具 `propose_changes`（或同时兼容 `preview_changes` 及单项写工具自动汇聚为同一个 `LocalChangeSet`）：
   - 支持的 `changes` 条目类型（`LocalChangeItem`）：
     - `create_todo`（可同时内嵌 `blocks: [{startLocal, endLocal, blockNote}]`，方便模型一次创建待办并排期！）
     - `update_todo` / `delete_todo`
     - `create_todo_block` / `update_todo_block` / `delete_todo_block`
     - `create_course`（含 `meetings` 列表） / `update_course` / `delete_course`
     - `move_course_occurrence` / `cancel_course_occurrence`（调用 Phase 1 的 `LocalSeriesService`）
     - `create_recurring_schedule` / `update_recurring_schedule` / `delete_recurring_schedule`
   - **冲突预检与人类可读摘要**：
     - 当 `LocalAgentTools` 收到模型的写入提议时，**不立即修改数据库**，而是先校验时间合法性（不跨午夜）、检测是否与现有课程冲突（若覆盖课程，在 `LocalChangeItem.conflictWarning` 中标注 `⚠️ 与课程「xxx」时间冲突`），并生成人类可读的中文摘要列表（例如：`+ 周二(11/27) 15:00-16:30 [时间块] 生化大作业：查阅文献`），存入 `LocalChangeSet` 等待用户在聊天卡片上点击「全部确认」。
   - **原子执行 (`applyChangeSet(LocalChangeSet changeSet)`)**：
     - 当用户点击「全部确认」时，在 `db.transaction(() async { ... })` 内依次调用 `EntityRepo` / `LocalSeriesService` 完成所有写入，保证要么全部成功、要么全部回滚。

---

### Step 3：提示词优化 (`flutter/lib/agent/agent_prompts.dart`)

构建结构化、高准确率的 System Prompt，动态注入实时上下文：

```text
你是 Course Planner 的内置智能日程与课表助手。
【当前环境上下文】
- 当前本地时间：{{nowLocal}} ({{weekdayLabel}})
- 用户固定时区：{{timezone}}
- 当前激活学期：{{semesterName}}（第一周周一：{{firstDay}}，共 {{totalWeeks}} 周，当前为 {{currentWeekLabel}}）
- 学期节次时间表：{{periodsSummary}}

【核心行为准则】
1. 读操作先行：当用户要求安排任务、询问日程或调整课表时，必须先调用 `get_todos`、`get_schedule` 或 `get_free_slots` 了解现状，严禁凭空捏造时间或课程 ID。
2. 智能拆块排期：当用户需要安排大型任务/作业/复习（例如“帮我安排本周完成生化大作业，大概需要4小时”）：
   - 先调用 `get_free_slots` 查找截止时间前的空闲时段；
   - 将任务合理拆分为多个 45~120 分钟的 `todo_block`，每个时间块写明具体的阶段目标 `blockNote`（如“1. 查资料与列提纲”、“2. 主体撰写”、“3. 润色与检查”）；
   - 默认避开所有已有课程和日程，且优先安排在 08:00–22:30 之间，严禁跨午夜（23:00 -> 次日 01:00）。
3. 一次性批量确认：一个用户请求涉及的所有创建、修改、删除操作，必须合并到一次 `propose_changes` 调用中提交给用户确认，绝不能分多次零散提交。
4. 自然语言时间换算：用户说的“明天下午三点”“这周四第3-4节”“下周一”，一律根据上方【当前环境上下文】中的本地日期和节次时间表精准换算为 `YYYY-MM-DD HH:mm`。
```

同时在聊天界面空白处提供 **4 个高频快捷指令胶囊**：
- `📅 总结我今天和明天的课程与待办`
- `🧩 帮我把未排期的待办自动安排到本周空闲时间`
- `🔍 看看我这周有哪些超过 2 小时的空闲时段`
- `📥 粘贴课表文本/HTML 帮我解析导入课程`

---

### Step 4：内置 Agent 聊天面板与 Change Set 确认卡片 (`agent_chat_sheet.dart`)

1. **聊天消息流**：
   - 用户消息气泡、Agent 回复气泡、工具调用折叠状态条（如 `🔍 已查询本周空闲时段 (6 个可用区间)`）。
2. **Change Set 确认卡片 (`ChangeSetConfirmationCard`)**：
   - 卡片标题：`即将修改你的日程与待办（共 N 项）`
   - 列表展示每一条变更：
     - 新增项带绿色 `+` 徽章
     - 修改项带蓝色 `~` 徽章
     - 删除/取消项带红色 `-` 徽章
     - 若存在软/硬冲突，显示醒目的橙色/红色冲突提示标签
   - 底部两个按钮：`[取消]` 与 `[全部确认]`（确认后变为 `✅ 已应用全部修改` 状态）。
3. **未配置 API Key 时的友好引导**：
   - 若用户尚未配置大模型 API Key，打开 `AgentChatSheet` 时展示引导卡片，点击一键跳转到 `/settings/agent`（支持一键选 DeepSeek / 硅基流动 / OpenAI / 自定义 BaseURL）。

---

## 5. 测试与验收标准

1. **本地空闲时段计算测试 (`flutter/test/free_slot_finder_test.dart`)**：
   - 给定一天的第 1-2 节（08:00-09:40）有课、14:00-15:30 有 TodoBlock，验证 `FreeSlotFinder` 正确返回 `09:40-14:00` 和 `15:30-22:00` 两个空闲区间。
2. **本地 Agent 工具与 ChangeSet 测试 (`flutter/test/local_agent_tools_test.dart`)**：
   - 测试 `get_current_time`、`get_calendar`、`get_free_slots` 返回正确的本地快照数据。
   - 测试调用 `propose_changes`（包含创建 1 个 Todo + 2 个 TodoBlock + 移动 1 节课程）：
     - 在未调用 `applyChangeSet` 前，数据库实体数量不变；
     - 调用 `applyChangeSet` 后，Todo、2 个 TodoBlock 和 1 个 OccurrenceOverride 全部在单事务内正确写入本地 SQLite。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试全部通过。
