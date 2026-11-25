# Phase 6：双模语音识别（ASR）与学校教务系统自动抓取导课

## 1. 阶段目标

在 Phase 5 内置 Agent 的基础上，补齐最后两大杀手级自动化入口：
1. **双模语音识别（默认系统原生 + 可选云端 ASR API）**：
   - 用户在 **内置 Agent 聊天框** 或 **新建待办面板** 中点击麦克风按钮，即可直接说话（例如：“帮我记一下下周三交毛概论文，顺便在这周末找两个下午安排写论文”）。
   - **双引擎架构 (`VoiceRecognitionService`)**：
     1. **系统原生语音识别模式（默认）**：零配置、免费、低延迟；
     2. **云端大模型语音 API 模式（可选）**：支持配置 OpenAI Whisper 兼容接口（`POST /v1/audio/transcriptions`，如硅基流动 `FunAudioLLM/SenseVoiceSmall`、Groq Whisper、OpenAI Whisper 等），也支持复用内置 Agent 的 API BaseURL + Key，实现超高准确率的中文校园词汇识别。
     3. **跨平台优雅降级**：若当前运行环境（如无麦克风的桌面端或测试环境）不可用，给出清晰提示而不崩溃。
2. **自动从学校教务系统抓取课程表并导入**：
   - 提供统一的 **「从教务系统 / 智能导入课表」** 页面（`/settings/edu-import`，并在「课程管理」和「CSV 导入」页面提供直达入口），支持三种互补抓取方式，覆盖 99% 中国高校教务系统：
     1. **内置教务网页抓取 / URL 抓取 + 主流教务 DOM 解析器**：
        - 内置针对国内主流高校教务系统（**正方教务 / 新正方**、**强智教务**、**青果教务**、**金智教务**、**通用 HTML `<table>` 课表**）的课表提取器（`EduHtmlParser`）。
        - 支持在应用内通过内置网页视图/浏览器登录教务网提取 DOM，或直接抓取页面 HTML。
     2. **AI 智能解析兜底（通杀任何非标自研教务系统）**：
        - 当遇到学校自研或非标格式的教务网页/课表文本（甚至从教务网全选复制出来的乱序文字、JSON、HTML 源码）时，一键调用 Phase 5 的 **内置 Agent (`EduAiExtractor`)**，自动将杂乱的网页 HTML/文本结构化提取为标准的 `List<ParsedCourse>`（包含课程名、教师、教室、星期、开始/结束节次、单双周规则）及节次时间表！
     3. **统一可视化预览、自动补齐节次、大色差配色与一键入库**：
        - 提取出的课程进入可视化预览列表（支持勾选/微调），自动检测并生成缺失的学期节次模板，自动调用 Phase 3 的 `CoursePalette.assignColorsForCourses` 分配大色差颜色，确认后一键写入本地 `EntityRepo`！

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `flutter/lib/domain/local_csv_import.dart` — Phase 1 实现的本地课程导入数据结构与入库逻辑
- `flutter/lib/core/theme/course_palette.dart` — Phase 3 实现的课程颜色差分分配器
- `flutter/lib/agent/llm_client.dart` & `flutter/lib/agent/agent_config.dart` — Phase 5 实现的内置大模型客户端与配置
- `flutter/lib/presentation/agent/agent_chat_sheet.dart` — 内置 Agent 聊天输入框
- `flutter/lib/presentation/todo/todo_page.dart` — `TodoEditorSheet` 标题输入框
- `flutter/lib/presentation/settings/import_page.dart` — 课程导入页

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/core/voice/voice_config.dart` — 语音识别配置模型（引擎模式：`native` | `cloudWhisper`，云端 ASR BaseURL / Key / Model，默认可复用 Agent Key）与持久化 Provider。
- `flutter/lib/core/voice/voice_recognizer.dart` — 统一语音识别服务接口 `VoiceRecognizer`（抽象出 `startListening`、`stopListening`、`cancel`、状态流 `VoiceState`，并提供系统原生实现与云端 Whisper Multipart 上传实现，以及测试可注入的 Mock 实现）。
- `flutter/lib/presentation/widgets/voice_input_button.dart` — 可复用的麦克风录音动画按钮组件（支持点击开始/结束录音、实时波形/脉冲提示、识别文本回调）。
- `flutter/lib/domain/edu_import/edu_html_parser.dart` — 高校教务系统 HTML / JSON / 文本课表解析引擎（内置新旧正方、强智、通用表格解析规则，自动提取课程名、周次 `1-16周(单)`、节次 `(1-2节)`、教师、地点）。
- `flutter/lib/domain/edu_import/edu_ai_extractor.dart` — 基于内置 Agent 的 AI 教务课表兜底提取器（将任意教务网页精简 DOM 或复制的课表文本通过 Structured JSON Prompt 转换为标准课程列表）。
- `flutter/lib/presentation/settings/edu_import_page.dart` — 教务系统自动抓取与智能导课页面（包含：教务网页提取 / 粘贴教务源码或文本 / AI 智能提取 → 预览微调 → 一键导入当前学期）。
- `flutter/test/edu_html_parser_test.dart` — 正方/强智/通用教务 HTML 与文本课表解析单元测试。
- `flutter/test/voice_input_test.dart` — 语音识别状态机与 `VoiceInputButton` 交互单元测试。

### 修改文件
- `flutter/lib/app/router.dart` — 新增 `/settings/edu-import` 路由。
- `flutter/lib/presentation/settings/import_page.dart` & `flutter/lib/presentation/settings/courses_page.dart` & `flutter/lib/presentation/settings/settings_page.dart` — 增加「从学校教务系统自动抓取 / AI 导课」显著入口。
- `flutter/lib/presentation/agent/agent_chat_sheet.dart` — 在聊天输入框旁集成 `VoiceInputButton`，识别结果自动填入或直接发送给 Agent。
- `flutter/lib/presentation/todo/todo_page.dart` — 在 `TodoEditorSheet` 标题栏旁集成 `VoiceInputButton`，支持语音快速录入待办标题。
- `flutter/lib/presentation/settings/agent_settings_page.dart` — 增加「语音识别（ASR）设置」分区（切换系统原生 / 云端语音 API，配置 ASR 模型如 `FunAudioLLM/SenseVoiceSmall` 或 `whisper-1`）。

---

## 4. 详细设计与分步实施指南

### Step 1：实现高校教务课表解析引擎 (`edu_html_parser.dart` & `edu_ai_extractor.dart`)

1. **`EduHtmlParser`（纯本地零延迟解析主流教务 HTML / JSON / 文本）**：
   - **支持格式 1：新正方教务 JSON (`kbList` / `sjkList`)**：
     - 自动识别新正方接口返回的 JSON 结构（字段含 `kcmc` 课程名、`xm` 教师、`cdmc` 场地、`xqj` 星期几、`jcs` 节次如 `"1-2"`、`zcd` 周次如 `"1-16周(单)"`），直接 100% 精准映射为 `List<ParsedCourse>`。
   - **支持格式 2：传统正方 / 强智 / 青果 HTML 课表表格 (`<table>`)**：
     - 剥离 `<script>`、`<style>`，解析 `<tr>` / `<td>` 网格或单元格内的常见排布格式：
       - 正则提取节次模式：`第?(\d+)[-~](\d+)节` 或 `\((\d+)[-~](\d+)节\)`
       - 正则提取周次模式：`(\d+[-~]\d+|\d+)([,、]\s*(\d+[-~]\d+|\d+))*\s*周?\s*(\([单双]\)|[单双]周?)?`
       - 自动根据所在的 `<td>` 列索引推断 `weekday (1..7)`，或从文本中的 `周一`~`周日` / `星期一`~`星期日` 提取。
   - **HTML 瘦身函数 `stripHtmlForAi(String rawHtml)`**：
     - 当本地规则未命中或课程字段不完整时，先剥离 HTML 中的 `script`、`style`、`svg`、`head` 和无关属性，只保留核心文本与表格结构（将几十 KB 的网页压缩到 3~5 KB 以内），再传给 `EduAiExtractor`。

2. **`EduAiExtractor`（内置 Agent 智能提取兜底）**：
   - 将瘦身后的教务网页内容或用户复制的任意格式课表文本，发送给 `LlmClient`，要求输出严格的 JSON 数组：
     ```json
     [
       {
         "name": "高等数学A(1)",
         "weekday": 1,
         "periodStart": 1,
         "periodEnd": 2,
         "teacher": "张教授",
         "location": "逸夫楼201",
         "weeks": "1-16"
       }
     ]
     ```
   - 解析返回的 JSON 并复用 Phase 1 的 `LocalCsvImporter.validateParsedCourses(...)` 进行校验。

---

### Step 2：实现教务导课页面 (`edu_import_page.dart`)

在 `EduImportPage` 中提供清晰的三步向导或分栏体验：
1. **顶部选择目标学期**（若当前还没有学期，提供「一键创建当前学期（含默认 12 节课时间表）」按钮，彻底消除新手“先去设置建学期再建节次再回来导课”的痛点！）。
2. **抓取与输入区（支持两种便捷模式切换）**：
   - **模式 A：教务网地址抓取 / 内置登录提取**
     - 提供学校教务网址输入框与内置网页抓取/提取引导；
     - 提供一键注入/复制提取脚本，能够直接从已登录的教务课表页提取 DOM / 新正方 JSON。
   - **模式 B：智能粘贴 / 源码 / 文本一键识别（最快、跨平台 100% 成功）**
     - 用户在电脑或手机浏览器打开教务课表页，`Ctrl+A` 全选复制网页文字，或者粘贴网页 HTML / 新正方 JSON；
     - 点击 **「自动识别课表」**：优先运行 `EduHtmlParser` 毫秒级本地提取；若识别数不足或用户点击 **「使用 AI 深度解析」**，则调用 `EduAiExtractor` 智能提取。
3. **可视化预览与一键导入区**：
   - 展示提取出的所有课程卡片（显示分配好的差分颜色圆点、课程名、星期几第几节、周次、老师、教室）。
   - 支持在预览列表中直接删除多余行或点击编辑修正某门课。
   - 提供「清空目标学期原有课程后导入」或「追加导入」选项。
   - 点击 **「确认导入 N 门课程」**，自动补齐缺失的 `PeriodTemplate`，使用 `CoursePalette.assignColorsForCourses` 赋色，并通过 `EntityRepo.createCourseWithMeetings` 本地事务入库！

---

### Step 3：实现双模语音识别与 `VoiceInputButton` (`flutter/lib/core/voice/`)

> **依赖与跨平台注意**：
> 在离线编译或跨平台（Windows + Android）环境下，为了避免第三方 C++/Gradle 语音插件导致编译失败，采用 **「平台原生通道 + 云端 Whisper API 双实现，无重型原生插件强绑定」** 的稳健架构：
> 1. **云端语音 API / OpenAI Whisper 兼容模式** + **系统键盘语音 / 原生 MethodChannel 桥接**：
>    - 在 Android / Windows 上提供轻量 MethodChannel (`course_planner/speech`) 调用系统自带语音识别 Intent (`RecognizerIntent.ACTION_RECOGNIZE_SPEECH` on Android, Windows Speech API on Windows)，无需引入容易破坏 Gradle 版本的第三方 pub 插件！
>    - 同时实现标准的 **OpenAI Audio Transcriptions (`/v1/audio/transcriptions`)** 客户端，支持直接对接硅基流动 (`FunAudioLLM/SenseVoiceSmall`，免费且中文极准)、OpenAI (`whisper-1`) 等云端接口。

1. **在 `android/app/src/main/kotlin/.../MainActivity.kt` 中增加 20 行轻量原生语音桥接**（如果项目有 `MainActivity.kt`）：
   - 处理 `course_planner/speech` MethodChannel 的 `startSpeechToText` 调用，直接拉起 Android 系统原生 `RecognizerIntent.ACTION_RECOGNIZE_SPEECH` 并把识别出的中文字符串返回给 Flutter，**0 第三方依赖、0 权限配置负担、100% 兼容所有国内 Android 手机系统自带语音引擎**！
2. **`VoiceInputButton` 组件 (`flutter/lib/presentation/widgets/voice_input_button.dart`)**：
   - 放置在 `AgentChatSheet` 输入框左侧/右侧，以及 `TodoEditorSheet` 标题输入框的 `suffixIcon`。
   - 点击按钮触发 `ref.read(voiceRecognizerProvider).recognize(...)`：
     - 录音/识别中显示脉冲动画与提示；
     - 识别完成后通过 `onTextRecognized(String text)` 将文字追加到输入框中（在 Agent 聊天框中支持「识别后直接发送」或「填入输入框后编辑」）。

---

## 5. 测试与验收标准

1. **教务课表解析测试 (`flutter/test/edu_html_parser_test.dart`)**：
   - 测试新正方 JSON（含 `kcmc`, `xqj`, `jcs`, `zcd`）解析为正确的 `ParsedCourse` 列表（包括 `1-16周(单)` 解析为 odd parity）。
   - 测试传统正方/强智 HTML `<table>` 课表片段解析出正确的课程名、教师、地点、星期、节次与周次。
   - 测试全选复制的纯文本课表解析，以及 `EduAiExtractor` 对大模型返回 JSON 的解析与容错。
2. **语音输入组件测试 (`flutter/test/voice_input_test.dart`)**：
   - 使用 Mock `VoiceRecognizer` 测试点击 `VoiceInputButton` 后，识别出的文本能正确填入 `TodoEditorSheet` 的标题框和 `AgentChatSheet` 的消息框。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有现有测试与 Phase 1 ~ Phase 6 新增测试全部 100% 通过！
