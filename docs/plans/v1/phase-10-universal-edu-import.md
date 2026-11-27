# Phase 10：基于商业课表逆向成果的全国高校教务导入引擎（脱机脚本 + 多厂商解析 + LLM 兜底）

## 1. 阶段背景与目标

在 `D:\Projects\CarryingOn\android-security\export` 目录中，我们已经完成了对某主流商业课程表（WakeUp 6.1.80）的完整逆向与离线剥离，获得了：
1. **全国 3570 所高校/教务配置库**（`schools_manifest.json` / `schools_manifest.csv` / `remote_school_configs.csv`）：包含学校名、登录 URL、教务类型（`type`）、桌面 UA 标记（`mode: "pc"`）、推荐策略（`strategy`）以及显式解析器映射（`parser`）。
2. **15 大主流教务厂商的完整接口与 DOM 解析逻辑**（`common_parsers/README.md` 与 `common_parsers/pretty/*.js`）：涵盖正方（ZF/ZF2/ZF3）、强智（QZ/QZ2/QZ2017-Vue）、金智（JinZhi 1/2/3）、树维/EAMS（ShuWei/DBDXQHD/QLLGXY）、青果（Kingo）、超星/学习通（ChaoXing/XueXiTong）、南软（SouthSoft）、乘方（ChengFang）、优慕课（UMOOC）、为途（VATUU）、拓扑（TuoPu）等。
3. **118 个在线热更新解析脚本与页面指纹探测器**（`plugin_schedule.js` 与 `remote_scripts/Parser_*.js`）。
4. **生产级 AI 课表表格定位、HTML 压缩与 `IClassesItem[]` 提取提示词**（`remote_scripts/Parser_GPT.js`）。

**本阶段目标**：
将这套商业级导入架构**彻底剥离原有的在线商业服务器依赖**，与我们项目现有的**内置 WebView / 本地解析器 / 用户已配置的 LLM Provider** 无缝结合，让用户无论是通过**「选学校登录教务网一键抓取」**还是**「粘贴 HTML/JSON/课表文本」**，都能直接走通 **「学校配置路由 → 页面指纹探测与接口主动拉取 → 多厂商本地解析 → 最高权重表格压缩 + 本地 LLM Provider (`IClassesItem[]`) 兜底 → 预览入库」** 的完整闭环！

---

## 2. 必读逆向资源与项目现有文件

施工前请先阅读以下文件：
- **逆向成果目录（只读参考与数据源）**：
  - `D:\Projects\CarryingOn\android-security\export\README.md` — 导出资源总览与脱机化指南
  - `D:\Projects\CarryingOn\android-security\export\common_parsers\README.md` — 15 大通用教务系统接口、参数、DOM 与字段归一化完整说明
  - `D:\Projects\CarryingOn\android-security\export\schools_manifest.json` — 3570 所高校主表
  - `D:\Projects\CarryingOn\android-security\export\remote_school_configs.csv` — 249 所高校的 `host/path -> Parser_*` 显式映射
  - `D:\Projects\CarryingOn\android-security\export\common_parsers\pretty\` — 格式化后的各厂商核心解析脚本
- **Flutter 端现有教务导入文件**：
  - `flutter/lib/domain/edu_import/edu_html_parser.dart`
  - `flutter/lib/domain/edu_import/edu_ai_extractor.dart`
  - `flutter/lib/presentation/settings/edu_import_page.dart`
  - `flutter/android/app/src/main/kotlin/com/trysting/courseplanner/MainActivity.kt`

---

## 3. 总体架构设计（无商业后端依赖的三级漏斗）

```text
用户选择学校 (3570 所高校搜索) 或 输入自定义教务 URL
       │
       ▼
[第一级：内置原生教务 WebView 登录与主动提取脚本 (In-Page JS Extractor)]
  • 用户在内置 WebView 完成 CAS / 验证码 / WebVPN 登录，进入个人课表页，点「一键提取课表」
  • 注入脱机版提取脚本：
    1. 若当前页面命中正方(ZF/ZF2/ZF3)、金智(JZ1/2/3)、树维(ShuWei/EAMS)、青果(Kingo)、
       强智(QZ/QZ2/QZ2017 Vue __vue__.data)、超星、乘方、南软等指纹：
       直接在页面上下文内通过 fetch/$.ajax (自动携带登录 Cookie) 拉取教务 JSON/HTML 接口，
       或递归穿透所有同源 iframe/frame 提取课表数据！
    2. 同时运行 Parser_GPT 的「跨 iframe 智能课表 <table> 权重打分器 + HTML 压缩器」，
       提取出得分最高的精简课表 HTML（保留 class/title/rowspan/colspan）一并回传给 Flutter。
       │
       ▼
[第二级：Dart 多厂商结构化解析引擎 (EduVendorParser + WakeupFormatNormalizer)]
  • 接收 WebView 回传（或用户直接粘贴）的 JSON / HTML：
    - 支持直接解析 `IClassesItem[]` 统一交换格式
    - 支持正方 JSON (`kbList` + `sjkList`)、正方旧版 `#Table1` (`第x节{第a-b周|单/双}`)
    - 支持金智 JSON (`arrangedList` / `weeksAndTeachers` / `ZCBH` 01位图周次 / `KSJCDM`..`JSJCDM`)
    - 支持树维 EAMS JSON (`studentTableVms[].activities[]` / `lessons[]` / `weekIndexes` / `startUnit`..`endUnit`)
    - 支持强智 Vue JSON (`xq1`..`xq7`) 与强智 `#kbtable` `.kbcontent` (`<font title="教师/周次(节次)/教室">`)
    - 支持青果 `#lessonSchedule-content ul li` 与超星 `sdpkkbList` JSON
       │ (若第一、二级未识别出有效课程，或该校属于 1028 所 ai-fallback 学校)
       ▼
[第三级：生产级 Prompt + 本地 LLM Provider 智能兜底 (EduAiExtractor)]
  • 将第一级筛选并压缩好的最高权重 `<table ...>` HTML（保留 title/rowspan/colspan）
    通过逆向得到的 `IClassesItem[]` 生产级 Prompt 发送给用户配置的 LLM Provider
  • 经过 `valifyTimeLoc` 校验与 `WakeupFormatNormalizer` 归一化（weekNums 数组自动合并为 WeekRule）
       │
       ▼
[可视化预览 → 自动补齐学期节次模板 → 莫奈大色差赋色 → 本地 SQLite 入库]
```

---

## 4. 涉及文件清单

### 新增文件
- `flutter/lib/domain/edu_import/wakeup_normalizer.dart` — 统一中间模型 `IClassesItem` / `ClassTimeLoc` 及各大厂商 JSON（金智、树维、超星、强智 Vue、青果）向 `ParsedCsvCourse` 的归一化转换器（含显式 `weekNums: [1,3,5,7,8,9]` 数组自动压缩为 `1-5单,7-9` 周次规则算法）。
- `flutter/lib/domain/edu_import/school_catalog.dart` — 高校教务目录检索服务（内置精选主流高校与教务厂商模板 + 支持从 `assets/edu/schools_manifest.json` 异步加载并按校名/拼音首字母/厂商类型毫秒级搜索 3570 所高校）。
- `flutter/lib/domain/edu_import/webview_extractor_script.dart` — 注入到教务 WebView 的脱机版 JavaScript 探测与提取脚本（集成跨 `iframe`/`frame` 穿透、15 大教务系统指纹探测与接口主动 `fetch`/`$.ajax` 拉取、以及 `Parser_GPT` 的 `getWeight`/`findTables`/`compressHtml` 最高权重表格提取器，**0 外部上报**）。
- `flutter/android/app/src/main/kotlin/com/trysting/courseplanner/EduWebViewActivity.kt` — 基于 Android 原生 `android.webkit.WebView` 的内置教务登录与抓课页面（无需任何第三方 Gradle/pub 插件，原生支持校园网自签名证书放行、HTTP/HTTPS 混合内容、PC/移动 UA 切换、JS Bridge 回传提取结果）。
- `flutter/assets/edu/schools_manifest.json` — 从 `D:\Projects\CarryingOn\android-security\export\schools_manifest.json` 精简提取的高校索引（仅保留 `name`, `login_url`, `type`, `mode`, `strategy`, `parser` 6 个核心字段，体积小、加载快）。
- `flutter/test/wakeup_normalizer_test.dart` — 测试 `IClassesItem[]`、金智 JSON（含 `ZCBH` 位图周次）、树维 `activities/lessons` JSON、强智 `<font title>` HTML、以及 `weekNums` 显式周次数组转 `WeekRule` 的单元测试。

### 修改文件
- `flutter/pubspec.yaml` — 在 `flutter.assets` 下注册 `- assets/edu/schools_manifest.json`。
- `flutter/android/app/src/main/AndroidManifest.xml` — 注册 `<activity android:name=".EduWebViewActivity" android:exported="false" android:theme="@android:style/Theme.DeviceDefault.NoActionBar" />` 并开启 `android:usesCleartextTraffic="true"`（因为 3570 所高校中有 1261 所高校教务网仍在使用明文 `http://`！不开启此项在 Android 9+ 上无法打开 HTTP 教务网！）。
- `flutter/android/app/src/main/kotlin/com/trysting/courseplanner/MainActivity.kt` — 在 `course_planner/media`（或新增 `course_planner/edu_webview`）MethodChannel 中增加 `"openEduWebView"` 方法，启动 `EduWebViewActivity` 并将提取到的 `{ pageUrl, schoolName, vendorType, extractedData, bestTableHtml }` 返回给 Flutter。
- `flutter/lib/domain/edu_import/edu_html_parser.dart` — 接入 `WakeupFormatNormalizer`，扩充对金智、树维、强智 `<font title>`、青果 `ul/li`、超星 JSON 以及保留 `title`/`rowspan`/`colspan` 的 `compressTableHtmlForAi` 支持。
- `flutter/lib/domain/edu_import/edu_ai_extractor.dart` — 升级 System Prompt 为逆向提取的 `IClassesItem[]` 生产级 Prompt（同时兼容原有的扁平 JSON 数组格式），并用 `WakeupFormatNormalizer` 校验和合并同课程时段。
- `flutter/lib/presentation/settings/edu_import_page.dart` — 新增 **「选择学校 / 教务系统并登录导入」** 首选模式（支持搜索 3570 所高校 → 点击打开内置教务浏览器登录 → 一键提取课表 → 若本地规则未命中自动无缝调用已配置的 LLM Provider 深度解析 → 预览入库）。

---

## 5. 详细设计与分步实施指南

### Step 1：实现 `WakeupFormatNormalizer` 与多厂商 JSON/DOM 解析 (`wakeup_normalizer.dart`)

1. **核心算法：显式周次数组 `List<int> weekNums` 转 `WeekRule` 字符串 (`compressWeekNumsToText`)**：
   商业脚本和 `IClassesItem` 中的 `weekNums` 是展开后的整数数组（例如 `[1, 3, 5, 7, 9, 10, 11, 12]` 或金智 `ZCBH: "101010111000"` 位图）。我们需要将其无损压缩为 `parseWeekRuleText` 支持的紧凑文本：
   - 先对 `weekNums` 去重、过滤 `>= 1` 并升序排序；
   - 扫描数组，优先识别连续递增（步长为 1，如 `9,10,11,12` → `9-12`）或连续同奇偶递增（步长为 2 且长度 `>= 3`，如 `1,3,5,7` → `1-7单`，`2,4,6,8` → `2-8双`），其余单点输出为单周数字（如 `15`），用 `,` 连接！
   - 同时提供金智 `ZCBH` 01 位图转 `List<int>` 函数：遍历字符串，若 `zcbh[i] == '1'` 则加入第 `i + 1` 周（注意部分金智系统第 0 位是占位符或第 1 周，若以 `0` 开头且长度 `> 20` 可按常见 1-based 位图对齐）。

2. **统一中间模型 `IClassesItem` 解析 (`parseIClassesItems`)**：
   ```json
   [
     {
       "classDefId": "",
       "courseName": "高等数学",
       "classTimeLoc": [
         {
           "teacher": "张老师",
           "location": "A101",
           "weekDay": 1,
           "weekNums": [1,2,3,4,5,6,7,8],
           "classTimeDailyIdxList": [1,2]
         }
       ]
     }
   ]
   ```
   - 注意商业格式中 **`weekDay`: `0 = 周日，1 = 周一 … 6 = 周六`**（若遇到 `7` 也视为周日），转换为我们的 `weekday` 时：**`weekDay == 0 ? 7 : weekDay`**！
   - `classTimeDailyIdxList`: 取首尾元素 `[first, last]` 作为 `periodStart` 和 `periodEnd`（clamp 到 `1..20`）。

3. **新增四大高频教务厂商原生 JSON 解析**：
   在 `EduHtmlParser._tryJson` / `WakeupFormatNormalizer` 中除现有的新正方 `kbList` 外，直接支持：
   - **金智教务 JSON (`arrangedList` / `datas.getMyScheduleDetail.arrangedList` / `rows`)**：
     - 字段映射：
       - 课程名：`courseName` 或 `KCMC`
       - 星期：`dayOfWeek` 或 `XQ`（`7` 或 `0` 归一为 `7`）
       - 节次：`beginSection`~`endSection` 或 `KSJCDM`~`JSJCDM` 或 `KSJC`~`JSJC`
       - 地点：`placeName` 或 `JASMC`
       - 周次与教师：若含 `weeksAndTeachers`（形如 `"1-16周/张老师;17周/李老师"`），按 `;` 拆分为多条记录，再按 `/` 拆出周次与教师；否则读取 `ZCBH`（位图）或 `ZCMC`（周次文本）与 `JSXM` / `teacherName`。
   - **树维 / EAMS 教务 JSON (`studentTableVms` / `activities` / `lessons`)**：
     - 字段映射：
       - 课程名：`courseName` 或 `course.nameZh`
       - 星期：`weekday`（1..7）
       - 节次：`startUnit` ~ `endUnit`
       - 周次：`weekIndexes`（`List<int>`）或 `weeksStr`
       - 教师：`teachers`（数组取姓名拼接）或 `teacherNames`
       - 地点：`room` 或 `campus`
   - **强智 2017 Vue JSON (`xq1`..`xq7` 行列表)**：
     - 遍历每行的 `xq1` ~ `xq7` 字段，非空时从中提取 `kcname`/`ktname`（课程名）、`lsname`（教师）、`js`（教室）、`zc`（周次与节次）。
   - **超星教务 JSON (`sdpkkbList` / `data`)**：
     - 字段映射：`kcmc`（剥离 HTML 标签 `<a>`）、`xingqi`、`zcstr`、`djc`、`tmc`（剥离 HTML）、`croommc`（剥离 HTML）。

4. **增强强智教务 `#kbtable` / `#timetable` 的 `<font title="...">` 与 `-----` 多课解析**：
   - 在 `EduHtmlParser` 解析 HTML `<td>` 时：
     - 强智教务一个单元格内有多门课时，用 `-----`（5 个以上连字符）或连续 `<br><br>` 分隔；先按 `-{4,}` 切分块！
     - 识别 `<font title="教师">...</font>` / `<font title="老师">...</font>` 直接提取为 `teacher`；
     - 识别 `<font title="教室">...</font>` / `<font title="教学楼">...</font>` / `<font title="上课地点">...</font>` 直接提取为 `location`；
     - 识别 `<font title="周次(节次)">1-16(周)[01-02节]</font>` 直接提取出周次和节次！

---

### Step 2：移植 `Parser_GPT.js` 的智能表格打分压缩器与生产级 LLM Prompt (`edu_ai_extractor.dart` & `edu_html_parser.dart`)

1. **升级 HTML 压缩逻辑 (`EduHtmlParser.compressHtmlForAi`)**：
   - 借鉴 `Parser_GPT.js` 的 `getWeight`、`findTables` 与 `compressHtml`：
   - 当输入是完整网页 HTML 时：
     - 先提取页面中所有的 `<table ...>[\s\S]*?</table>`；
     - 对每个 `<table>` 进行打分（统计是否包含 `星期一..日` / `周一..日`、是否包含 `节次/第1节/上午/下午`、以及命中 `课程|教师|老师|教授|地点|教室|楼|校区|周|星期|节次` 的次数）；
     - 选出得分最高的课表 `<table>`（若页面是 DIV 伪表格、没有 `<table>`，再回退到全文纯文本提取）；
     - 对选中的 `<table>`，移除 `<script>`, `<style>`, `<svg>`, `<!-- -->`，并在标签上**保留 `class`, `title`, `rowspan`, `colspan` 属性**（如 `<td rowspan="2">`, `<font title="教室">`），移除其余冗余属性（如 `onclick`, `id`, ` data-*`, `width`, `align`）。
     - 这样可以把 150KB 的教务网页精准浓缩为 2~6KB 的高信息密度课表 HTML，既保留了强智的 `title` 和正方的 `rowspan` 连堂信息，又不会超出大模型上下文窗口！

2. **升级 `EduAiExtractor` 的 System Prompt 与 JSON 解析器 (`flutter/lib/domain/edu_import/edu_ai_extractor.dart`)**：
   - 将 `_systemPrompt` 升级为 `Parser_GPT.js` 中经过海量高校验证的 `IClassesItem[]` 提取提示词（要求模型识别所有课程、处理同课程不同周次/连堂节次合并，输出 `IClassesItem[]` JSON）。
   - 在 `EduAiExtractor` 解析模型返回值时：**同时兼容两种返回结构**：
     1. 商业标准 `IClassesItem[]` 结构（含 `courseName` 和 `classTimeLoc` 数组，交由 `WakeupFormatNormalizer.fromIClassesItems` 转换）；
     2. 原有的扁平 `[{name, weekday, periodStart, periodEnd, teacher, location, weeks}]` 结构（保持对现有 `edu_html_parser_test.dart` 中 Mock 测试用例的 100% 兼容！）。

---

### Step 3：内置 3570 所高校检索目录 (`school_catalog.dart` & `assets/edu/schools_manifest.json`)

1. **生成精简高校配置资产文件 `flutter/assets/edu/schools_manifest.json`**：
   - 从 `D:\Projects\CarryingOn\android-security\export\schools_manifest.json`（及 `remote_school_configs.csv`）提取所有学校条目，写入 `flutter/assets/edu/schools_manifest.json`。
   - 每条记录保留紧凑字段：
     ```json
     {"n":"安徽大学","u":"https://jw.ahu.edu.cn","t":"shuwei_new","m":"","s":"remote-detect","p":"Parser_ShuWei"}
     ```
     （`n`=name, `u`=login_url, `t`=type, `m`=mode, `s`=strategy, `p`=parser）。3570 条记录压缩后仅约 250KB！
2. **实现 `flutter/lib/domain/edu_import/school_catalog.dart`**：
   - 顶部固定置顶 **8 个通用教务系统入口**（正方教务、强智教务、金智教务、树维/EAMS 教务、青果教务、超星/学习通、乘方教务、其他/通用教务网页）。
   - 支持按学校名称关键字（如 `"安徽"`、`"理工"`、`"研究生"`）实时过滤 3570 所高校，展示学校名、教务系统类型标签（如 `正方` / `强智` / `树维` / `AI 智能解析`）和教务网址。

---

### Step 4：实现 Android 原生教务登录抓课 WebView (`EduWebViewActivity.kt` & `webview_extractor_script.dart`)

1. **在 `flutter/android/app/src/main/AndroidManifest.xml` 中**：
   - 在 `<application>` 标签上添加 `android:usesCleartextTraffic="true"`（必须开启，否则 1261 所使用 `http://` 的高校教务系统无法加载！）。
   - 注册 `<activity android:name=".EduWebViewActivity" android:exported="false" android:configChanges="orientation|screenSize|keyboardHidden" />`。

2. **编写 `EduWebViewActivity.kt`（纯 Android SDK `android.webkit.WebView` 实现，0 外部依赖）**：
   - 接收 Intent 参数：`url`（初始教务网址）、`schoolName`、`parserType`、`desktopMode`（`mode == "pc"` 时默认开启桌面版 User-Agent）。
   - 界面采用纯代码构建的紧凑布局：
     - **顶部工具栏**：返回关闭按钮、可编辑地址栏（支持用户修改内网/WebVPN 地址并回车跳转）、刷新按钮、「电脑版/手机版 UA」切换开关。
     - **中部 `WebView`**：
       - 开启 `javaScriptEnabled = true`, `domStorageEnabled = true`, `databaseEnabled = true`, `mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW`；
       - `WebViewClient.onReceivedSslError`: 针对校园网常见的自签名/过期教务证书，弹窗或允许继续加载，避免白屏；
       - 注册 `@JavascriptInterface` 桥接对象 `window.CoursePlannerBridge.onExtracted(jsonPayload: String)`。
     - **底部操作栏**：
       - 提示文字：`请先登录并进入「个人课表」页面，然后点击右侧按钮 →`
       - 醒目的 **「一键提取当前页课表」** 按钮。

3. **点击「一键提取当前页课表」时的页面内 JS 注入逻辑 (`webview_extractor_script.dart`)**：
   - 当用户点击按钮时，WebView 执行提取脚本，按以下优先级在同一页面上下文（携带当前登录 Cookie）提取数据并回传 JSON `{ status, vendor, dataJson, rawHtml, bestTableHtml }`：
     1. **新正方主动拉取**：若页面存在 `#xnm` 和 `#xqm`（或 `meta[content="zfsoft"]`），脚本自动通过 `fetch` / `$.ajax` POST `/kbcx/xskbcx_cxXsgrkb.html?gnmkdm=N2151` 获取 `{ kbList, sjkList }` JSON；
     2. **强智 2017 Vue 提取**：若页面或同源 iframe 中存在 `div.el-table` 且含 `__vue__.data`，直接提取 `__vue__.data` JSON；
     3. **树维 EAMS 主动拉取**：若存在 `window.CONTEXT_PATH` 或 `/for-std/course-table`，自动通过 `$.ajax` 拉取 `print-data` / `get-data` 获取 `activities` / `lessons` JSON；
     4. **金智主动拉取**：若存在 `window.WIS_CONFIG` 或路径含 `/jwapp/sys/`，自动请求 `getMyScheduleDetail.do` 获取 `arrangedList` JSON；
     5. **全页面 + 跨 `iframe`/`frame` 递归 HTML 与最高分 `<table>` 提取**：
        - 无论上述特定接口是否命中，同时递归遍历 `document` 及所有同源 `iframe`/`frame` 的 `contentDocument`：
        - 拼接完整的页面 HTML；
        - 运行 `Parser_GPT` 的 `findTables` + `getWeight` + `compressHtml`，选出权重最高的课表 `<table>` HTML。
     6. 调用 `window.CoursePlannerBridge.onExtracted(JSON.stringify(result))` 将提取包传回 `EduWebViewActivity`，`EduWebViewActivity` 通过 `setResult(Activity.RESULT_OK, intent)` 返回给 `MainActivity` → Flutter `EduImportPage`！

---

### Step 5：在 `EduImportPage` 中串联「选学校 → 登录提取 → 本地解析 → LLM 自动兜底」

在 `flutter/lib/presentation/settings/edu_import_page.dart` 中：
1. **新增「选择学校 / 教务系统」卡片**：
   - 点击「搜索全国高校（3570 所）」弹出带搜索框的学校选择面板（`SchoolPickerSheet`）：
     - 输入学校名即时过滤；
     - 选中某所学校后，显示该校名称、教务系统类型标签（如 `正方教务` / `强智教务` / `树维教务` / `AI 智能解析`），并自动将教务网址填入地址框。
2. **「内置浏览器登录并一键提取」（Android 端直达，桌面端提供一键在浏览器打开 + 粘贴引导）**：
   - 在 Android 端点击 **「打开教务网登录并提取」**，直接拉起 `EduWebViewActivity`。
   - 当用户从 `EduWebViewActivity` 点「一键提取当前页课表」返回时：
     - **第一步（毫秒级本地解析）**：`EduImportPage` 先把回传的 `dataJson` / `rawHtml` 交给 `EduHtmlParser.parse(...)`（内部含 `WakeupFormatNormalizer`）；
     - **第二步（未命中或 `ai-fallback` 学校自动无缝转 LLM Provider）**：
       - 如果本地解析结果为空（或该学校策略标记为 `ai-fallback`），且用户已配置内置 AI 助手（`agentConfigProvider.isConfigured`），**自动无缝调用 `_parseWithAi(bestTableHtml ?? rawHtml)`**，直接用大模型提取出课程列表并展示预览！
       - 如果用户尚未配置 AI Key 且本地规则未命中，则将提取到的 HTML 填入文本框并提示用户点击「去配置 AI 助手后解析」。

---

## 6. 测试与验收标准

1. **多厂商与 `IClassesItem` 归一化测试 (`flutter/test/wakeup_normalizer_test.dart`)**：
   - 测试标准 `IClassesItem[]` JSON（含 `weekDay: 0` 周日转换、同一门课多个 `classTimeLoc`）正确转换为 `List<ParsedCsvCourse>`。
   - 测试 `compressWeekNumsToText`：
     - `[1, 2, 3, 4, 5, 6, 7, 8]` → `'1-8'`
     - `[1, 3, 5, 7, 9]` → `'1-9单'`
     - `[2, 4, 6, 8, 12, 13, 14]` → `'2-8双,12-14'`
   - 测试金智教务 `arrangedList` JSON（含 `weeksAndTeachers: "1-16周/张教授"` 与 `ZCBH` 位图）解析成功。
   - 测试树维教务 `activities` / `lessons` JSON 解析成功。
   - 测试强智教务带 `<font title="教师">`、`<font title="周次(节次)">` 和 `-----` 多课分隔的 HTML 表格解析成功。
   - 测试 `EduHtmlParser.compressHtmlForAi` 能从包含多个杂乱表格的 HTML 中挑出权重最高的课表 `<table>` 并保留 `title`, `rowspan`, `colspan` 属性。
2. **高校目录加载与搜索测试**：
   - 测试 `SchoolCatalog` 能正确搜索学校名称、识别 `url_valid` 并处理 `no-scheme` URL（自动补全 `https://` / `http://`）。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有现有测试与新增测试 100% 绿灯。
