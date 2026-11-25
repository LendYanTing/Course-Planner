# Course Planner (Flutter) V1 大改分阶段执行文档

本目录包含 Course Planner **Flutter 客户端（Android / Windows）** V1 升级的完整分阶段施工文档，专门面向**高性价比编码 Agent**（如 DeepSeek、Qwen-Coder、GPT-4o-mini、Claude Haiku/Sonnet 等）设计。

每个阶段（Phase 1 ~ Phase 6）都是**高内聚、低耦合、可独立编译并跑通测试**的闭环任务。请按顺序把单个阶段的文档喂给执行 Agent，待当前阶段通过验收后再进入下一阶段。

---

## 一、 核心改造方向总览

1. **系统优化（本地化与去强制同步）**
   - 免登录开箱即用（默认初始化本地 Profile 与时区，不再强制跳转 `/login`）。
   - 所有操作 100% 本地 SQLite 完成：单次/后续/全系列调课与删课（本地读写 `OccurrenceOverride` 与规则切片）、CSV 导课全部改为本地执行，彻底解除对服务端 API 的强依赖。
   - 云同步改为**可选功能**（默认关闭自动同步，用户按需在「设置 → 数据与云同步」中登录服务器并开启自动同步或手动同步）。
2. **UI 大改（Tab 瘦身、莫奈取色、背景壁纸、卡片调节、设置分类）**
   - **Tab 瘦身**：底栏精简为 3 个 Tab：`日程`（顶栏分段切换 `课表 | 周 | 月`）、`待办`、`设置`。
   - **设置页分类**：将原本 1200+ 行的单列表拆分为 5 大分类模块与清晰的子页面。
   - **莫奈取色与多主题**：支持动态取色（从自定义背景图或系统提取主色）、多套预设主题色、亮/暗/跟随系统模式。
   - **背景自定义**：支持自定义课表/日程背景图片，可调节高斯模糊度与暗化/亮化遮罩浓度。
   - **课程颜色差分、透明度、大小调整**：基于色相环大色差自动分配课程颜色，支持一键重分配；支持调节课程卡片不透明度、圆角、字号缩放与行高。
3. **人工操作优化（任务添加减负）**
   - 重构新建/编辑待办面板：首屏极简（标题 + 快捷截止时间胶囊 + 分类/优先级 Chip），高级项折叠。
   - 打通 `Todo` 与 `TodoBlock`：在新建待办时可一键勾选「排入日程」并选择时间段，单事务同时写入待办与时间块，消除「先建待办、再去二级菜单建时间块」的割裂感。
   - 强化课表/周视图空白格点选快速创建体验。
4. **内置 Agent（自带本地 MCP Tools、教务自动导课、语音识别、提示词优化）**
   - **客户端内置 Agent + 本地 Tools**：支持在客户端直接配置 OpenAI 兼容接口（DeepSeek / 硅基流动 / Qwen / OpenAI 等），内置与 `docs/mcp.md` 完全同构的本地读写工具集，直接操作本地 `EntityRepo` 与 `EventExpander`。
   - **Change Set 一次性确认卡片**：所有写操作在聊天流内生成可视化变更预览卡片，用户点击「全部确认」后在本地单事务内原子提交。
   - **提示词工程优化**：针对中国高校学期周次、节次时间、空闲时段查找、大作业自动拆块排期进行专项提示词优化。
   - **双模语音识别（ASR）**：默认调用系统原生语音转文字，同时支持配置云端 Whisper 兼容 ASR 接口。
   - **学校教务系统自动抓取并导入**：内置 WebView 登录教务网提取课表（内置正方/强智/青果等主流教务脚本 + 内置 Agent HTML/文本智能解析兜底），预览确认后一键导入本地学期。

---

## 二、 阶段文档索引与依赖顺序

| 阶段 | 文档路径 | 核心交付物 | 前置依赖 |
| --- | --- | --- | --- |
| **Phase 1** | `docs/plans/v1/phase-1-local-first.md` | 免登录本地会话、调课/删课本地化、CSV 导课本地化、可选云同步开关 | 无（第一优先级） |
| **Phase 2** | `docs/plans/v1/phase-2-nav-and-settings.md` | 3-Tab 导航（日程三视图合一）、设置页模块化分类重构 | Phase 1 |
| **Phase 3** | `docs/plans/v1/phase-3-theme-and-visuals.md` | 莫奈取色与多主题、背景自定义（模糊/遮罩）、课程颜色差分、卡片透明度与大小调整 | Phase 2 |
| **Phase 4** | `docs/plans/v1/phase-4-task-ux.md` | 极简添加任务面板、待办与时间块一站式创建、日程空白处快捷交互优化 | Phase 2 |
| **Phase 5** | `docs/plans/v1/phase-5-builtin-agent.md` | 内置 Agent 聊天抽屉、本地 MCP 同构 Tools、ChangeSet 确认卡片、排期提示词优化 | Phase 1, Phase 2 |
| **Phase 6** | `docs/plans/v1/phase-6-voice-and-edu-import.md` | 双模语音识别（原生 + 云端 API）、教务系统 WebView 抓取 + AI 智能解析导课 | Phase 1, Phase 5 |

---

## 三、 给下游性价比模型 Agent 的全局硬性守则

当把本目录下的阶段文档交给编码 Agent 执行时，请同时附上以下提示词约束：

1. **只改 Flutter 端**：本次 V1 改造范围限定在 `flutter/` 目录下，**禁止修改 `server/`、`web/` 或 `docs/openapi.yaml`**。
2. **遵守时区铁律**：所有时间换算必须通过 `UserTime`（`flutter/lib/core/time/user_time.dart`）进行 `UTC <-> 用户固定时区` 转换，严禁直接用 `DateTime.now().toLocal()` 的设备偏移量计算日程的跨日或周次。
3. **遵守本地数据库契约**：所有持久化业务实体（学期、节次、课程、课次、周期日程、单次调整 Override、待办、时间块、标签、分类）必须通过 `EntityRepo`（`flutter/lib/data/repo/entity_repo.dart`）写入 Drift SQLite，并保持 `EntityTypes` 命名与 `docs/openapi.yaml` 一致，以便用户开启可选云同步时能无缝同步到服务端。
4. **离线编译约束**：注意 `flutter/pubspec.yaml` 中配置了 `hooks.user_defines.sqlite3` 使用本地 `third_party/sqlite3/sqlite3.c`，**切勿删除 `pubspec.yaml` 底部的 `hooks` 和 `shaders` 配置**。
5. **每步必跑测试**：每个阶段完成后，必须在 `flutter/` 目录下执行：
   ```bash
   flutter analyze
   flutter test
   ```
   确保 0 error 且所有现有测试与新增测试全部通过。
