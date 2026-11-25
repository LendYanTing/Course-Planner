# Phase 3：莫奈取色、多主题、背景自定义与课程卡片视觉调节

## 1. 阶段目标

对课表与全局视觉体验进行全方位升级，实现用户思维导图中「UI大改」的核心视觉特性：
1. **莫奈取色（Monet Dynamic Color）与多主题自定义**：
   - 支持 **3 种取色来源**：
     1. **壁纸莫奈取色**：当用户设置了自定义背景图时，自动从背景图提取 Material 3 `ColorScheme`（使用 Flutter 原生 `ColorScheme.fromImageProvider`），实现真正的「换张壁纸，整套 UI 自动跟着换配色」！
     2. **预设多主题色板**：提供 8 套精心调校的莫奈/莫兰迪主题色种子（靛青、薄荷、樱粉、琥珀、紫藤、青柠、岩灰、海蓝）以及自定义 HEX 选色。
     3. **亮色 / 暗色 / 跟随系统** 三态 `ThemeMode` 切换。
2. **背景自定义（壁纸 + 模糊 + 遮罩）**：
   - 支持在「日程页（课表/周/月）」设置自定义本地背景图片（拷贝到 App 文档目录持久化，无需额外第三方权限弹窗困扰）。
   - 支持调节 **背景高斯模糊度（0 ~ 25 sigma）** 与 **背景遮罩浓度（0% ~ 85%）**，保证任何花哨壁纸下课表文字都清晰易读。
3. **课程颜色差分算法**：
   - 告别单调重复的 10 色循环。实现基于 **HSL / Oklab 黄金角大色差分配算法** 的课程配色器：新建或导入课程时，自动挑选与当前学期已有课程色差最大的柔和莫兰迪/马卡龙色。
   - 在「课程管理」和「外观设置」中提供 **「一键重新分配本学期课程颜色」** 功能（支持「莫兰迪柔和」「高对比鲜明」「跟随当前主题色系」三种配色风格）。
4. **课程卡片透明度、大小、圆角与字号调整**：
   - 支持滑动实时调节并预览：
     - **课程卡片不透明度**（`0.30 ~ 1.00`，默认 `0.92`；搭配自定义背景壁纸时半透明磨砂效果极佳）
     - **课程卡片圆角**（`4 ~ 16 dp`，默认 `8 dp`）
     - **课程卡片外边距 / 间隙**（`1.0 ~ 4.0 dp`，默认 `1.5 dp`）
     - **课程文字大小缩放**（`0.85x ~ 1.30x`，默认 `1.0x`）
     - **课表单节行高**（`44 ~ 90 dp`，默认 `56 dp`）

---

## 2. 必读现有文件

动手前请先阅读以下文件：
- `flutter/lib/app/theme.dart` — 现有 `AppTheme` 与 `kPalette`
- `flutter/lib/app/router.dart` — `CoursePlannerApp` 的 `MaterialApp.router` 主题挂载点
- `flutter/lib/state/prefs.dart` — 本地 UI 偏好存储控制器
- `flutter/lib/presentation/calendar/grid_view.dart` — 课表视图与课程卡片 `_GridTile` 渲染
- `flutter/lib/presentation/calendar/week_page.dart` — 周时间轴视图与 `_PositionedEvent` 渲染
- `flutter/lib/presentation/settings/appearance_settings_page.dart` — Phase 2 创建的外观设置二级页
- `flutter/lib/presentation/settings/courses_page.dart` — 课程颜色与课程管理页

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/core/theme/course_palette.dart` — 课程颜色差分算法（大色差自动分配、3 种色板风格、一键重分配当前学期课程颜色）。
- `flutter/lib/presentation/widgets/calendar_background.dart` — 自定义背景图层组件（处理本地壁纸文件加载、高斯模糊 `ImageFilter.blur`、暗化/亮化遮罩）。
- `flutter/test/course_palette_test.dart` — 课程颜色差分算法与不撞色单元测试。
- `flutter/test/theme_and_prefs_test.dart` — 主题模式、莫奈取色、卡片样式参数持久化测试。

### 修改文件
- `flutter/lib/state/prefs.dart` — 新增主题与外观相关的 Notifier Providers：
  - `themeModeProvider` (`system` / `light` / `dark`)
  - `themeSeedModeProvider` (`preset` / `wallpaperMonet`)
  - `themeSeedColorProvider` (预设/自定义 `Color`)
  - `backgroundConfigProvider` (`imagePath`, `blurSigma`, `scrimOpacity`)
  - `courseCardStyleProvider` (`opacity`, `borderRadius`, `margin`, `fontScale`, `rowHeight`)
- `flutter/lib/app/theme.dart` — 重构 `AppTheme.light(...)` 与 `AppTheme.dark(...)`，支持传入动态 `ColorScheme` 或自定义 `seedColor`；当开启自定义背景时，让日程页内部 `Scaffold` 背景透明以透出壁纸。
- `flutter/lib/app/router.dart` — `CoursePlannerApp` 监听 `themeModeProvider`、`themeSeedColorProvider` 与壁纸派生出的 `wallpaperColorSchemeProvider`，动态更新 `MaterialApp.router` 的 `theme`、`darkTheme`、`themeMode`。
- `flutter/lib/presentation/calendar/week_page.dart`、`flutter/lib/presentation/calendar/grid_view.dart`、`flutter/lib/presentation/calendar/month_page.dart` — 接入 `CalendarBackground` 背景组件与 `courseCardStyleProvider`（应用卡片透明度、圆角、外边距、字号缩放、可调课表行高）。
- `flutter/lib/presentation/settings/appearance_settings_page.dart` — 完整实现可视化主题选色器、莫奈壁纸取色开关、背景图片选择与模糊/遮罩滑块、课程卡片实时预览与滑块调节。
- `flutter/lib/presentation/settings/courses_page.dart` & `flutter/lib/domain/local_csv_import.dart` — 新建课程或 CSV 批量导入课程时，自动调用 `CoursePalette.assignDistinctColors(...)` 分配大色差颜色；在 `CoursesPage` 顶栏增加「重新配色」按钮。

---

## 4. 详细设计与分步实施指南

### Step 1：在 `prefs.dart` 中定义主题、背景与卡片样式状态

1. **`CourseCardStyle` 数据结构与 Provider**：
   ```dart
   class CourseCardStyle {
     const CourseCardStyle({
       this.opacity = 0.92,
       this.borderRadius = 8.0,
       this.margin = 1.5,
       this.fontScale = 1.0,
       this.rowHeight = 56.0,
     });

     final double opacity;      // 0.30 .. 1.00
     final double borderRadius; // 4.0 .. 16.0
     final double margin;       // 0.5 .. 4.0
     final double fontScale;    // 0.85 .. 1.30
     final double rowHeight;    // 44.0 .. 90.0
     // 提供 copyWith、toJson、fromJson
   }
   ```
   使用单个 JSON key `'course_card_style'` 存储在 `prefStoreProvider` 中，避免拆成过多零散 key。

2. **`BackgroundConfig` 数据结构与 Provider**：
   ```dart
   class BackgroundConfig {
     const BackgroundConfig({
       this.imagePath,
       this.blurSigma = 0.0,
       this.scrimOpacity = 0.25,
     });

     final String? imagePath;   // 本地沙盒内的背景图绝对路径，null 表示无背景图
     final double blurSigma;    // 0.0 .. 25.0
     final double scrimOpacity; // 0.0 .. 0.85
     bool get hasImage => imagePath != null && imagePath!.isNotEmpty;
   }
   ```

3. **`ThemeConfig` 数据结构与 Provider**：
   ```dart
   class ThemeConfig {
     const ThemeConfig({
       this.mode = ThemeMode.system,
       this.useWallpaperMonet = true,
       this.seedColorHex = '#3F51B5',
     });

     final ThemeMode mode;
     final bool useWallpaperMonet; // 开启后，若有背景图则自动从背景图提取莫奈配色
     final String seedColorHex;
   }
   ```
   - 提供 `wallpaperColorSchemeProvider`（`FutureProvider.family<ColorScheme?, (String?, Brightness)>`）：当 `useWallpaperMonet && background.hasImage` 且文件存在时，使用 Flutter 内置的 `ColorScheme.fromImageProvider(provider: FileImage(File(path)), brightness: brightness)` 提取莫奈色板；失败或未设置背景图时回退到 `ColorScheme.fromSeed(seedColor: parseHex(seedColorHex), brightness: brightness)`。
   - **优点**：完全使用 Flutter Material 3 官方原生的 `ColorScheme.fromImageProvider`（内部即 Google Material You 的 QuantizerCelebi + Score 莫奈取色算法），**无需引入容易编译冲突的第三方 C++ 插件**，在 Windows 和 Android 上 100% 稳定一致！

---

### Step 2：实现课程颜色差分算法 (`flutter/lib/core/theme/course_palette.dart`)

1. **三套色板风格 (`CoursePaletteStyle`)**：
   - `morandi`（莫兰迪柔和，默认）：饱和度适中、明度舒适，16 个色相均匀分布的精选色值。
   - `vibrant`（清新高对比）：色彩鲜明活泼，适合半透明背景。
   - `monetHarmony`（莫奈同色系差分）：围绕当前主题 `seedColor` 的色相，通过黄金角（`137.5°`）旋转结合明度/饱和度微调，生成与当前壁纸/主题高度和谐但彼此色差明显的颜色。
2. **颜色差分分配函数**：
   ```dart
   class CoursePalette {
     /// 为一门新课程挑选与 [existingColors] 色差最大的颜色
     static String pickDistinctColor(
       Iterable<String?> existingColors, {
       CoursePaletteStyle style = CoursePaletteStyle.morandi,
       Color? themeSeed,
     });

     /// 为一组课程批量分配互不撞色（且相邻星期/节次尽量高对比）的颜色
     static Map<String, String> assignColorsForCourses(
       List<Course> courses, {
       CoursePaletteStyle style = CoursePaletteStyle.morandi,
       Color? themeSeed,
     });
   }
   ```
   - 算法原理：计算候选颜色与已使用颜色在 HSL/RGB 空间的最小距离，优先选择最小色差最大的候选色；当课程数量超过预设池大小时，使用黄金分割角 `(index * 137.508) % 360` 动态生成新色相，确保即使一个学期有 20 门课也不会出现两门课颜色糊在一起的情况。

---

### Step 3：实现自定义背景组件与卡片视觉渲染

1. **新建 `flutter/lib/presentation/widgets/calendar_background.dart`**：
   - 封装 `CalendarBackground({required Widget child})`：
   - 当 `backgroundConfigProvider.hasImage` 且文件存在时：
     - 底层绘制 `Image.file(File(config.imagePath!), fit: BoxFit.cover)`；
     - 叠加 `BackdropFilter(filter: ImageFilter.blur(sigmaX: config.blurSigma, sigmaY: config.blurSigma))`（仅当 `blurSigma > 0.1` 时启用 `BackdropFilter`，为 0 时跳过以节省 GPU 开销）；
     - 叠加一层半透明遮罩 `Container(color: Theme.of(context).colorScheme.surface.withValues(alpha: config.scrimOpacity))`（亮色模式下为白透遮罩，暗色模式下为黑透遮罩，确保文字对比度）；
     - 顶层放置 `child`（此时将日程页的网格底色与表头底色设为半透明）。
2. **关于背景图片选择**：
   - 为了不引入繁重的原生文件选择器插件（或兼容 Windows + Android），提供两种零摩擦选图方式：
     1. 支持输入/粘贴本地图片路径，或在 Windows/Android 上调用轻量文件选择（如项目未引入 `file_picker` / `image_picker`，可先检查 `pubspec.yaml`；若在离线环境不便 `pub get` 新包，可通过纯 Dart / 平台 MethodChannel 或内置几张高质量渐变/几何纹理壁纸 + 本地路径导入，若环境允许也可支持粘贴路径/相册读取）。
     2. **特别要求**：内置 **4 套精美矢量/Shader 预设动态壁纸**（如「晨曦极光」「莫奈睡莲渐变」「深海星云」「极简网格」），让用户即便不导入外部图片，也能一键体验绝美的背景壁纸与莫奈取色效果！同时支持选择本地图片文件。
3. **升级 `grid_view.dart` 与 `week_page.dart` 的课程卡片渲染**：
   - 读取 `ref.watch(courseCardStyleProvider)`：
     - `GridViewContent` 的单节行高不再写死 `static const double rowHeight = 54`，而是使用 `cardStyle.rowHeight`。
     - 课程卡片背景色透明度使用 `cardStyle.opacity`（例如 `baseColor.withValues(alpha: cardStyle.opacity)`）。
     - 卡片圆角使用 `BorderRadius.circular(cardStyle.borderRadius)`。
     - 卡片外边距使用 ` EdgeInsets.all(cardStyle.margin)`。
     - 课程名称与上课地点字号乘以 `cardStyle.fontScale`。

---

### Step 4：完善「外观与个性化」设置页 (`appearance_settings_page.dart`)

在 `AppearanceSettingsPage` 中提供直观的分区与**顶部实时迷你课表预览卡片**：
1. **顶部实时预览区**：放一个 3 列 × 2 节的迷你课表卡片预览，用户拖动下方的透明度、圆角、字号、主题色滑块时，顶部预览实时变化。
2. **主题与莫奈取色区**：
   - 亮暗模式切换：`跟随系统 | 浅色 | 深色`（`SegmentedButton`）。
   - 「从背景壁纸自动莫奈取色」开关（`SwitchListTile`）。
   - 8 个预设主题色圆点选择器（点击即切换全局 `seedColor`）。
3. **背景自定义区**：
   - 选择预设壁纸（4 套内置渐变/艺术壁纸 + 无壁纸 + 自定义本地图片文件）。
   - 滑块：背景模糊度（`0 ~ 25`）、背景遮罩浓度（`0% ~ 85%`）。
4. **课程卡片与课表调节区**：
   - 一键操作：「重新分配当前学期课程颜色」（弹出底部菜单选择 `莫兰迪柔和` / `高对比鲜明` / `莫奈同色系`，确认后批量更新当前学期所有课程颜色）。
   - 滑块：卡片不透明度、卡片圆角、卡片间距、字体大小缩放、课表每节行高、课表文字显示行数、月视图格子高度、中午分界点、底栏材质。
   - 底部提供「恢复默认外观」按钮。

---

## 5. 测试与验收标准

1. **课程颜色差分测试 (`flutter/test/course_palette_test.dart`)**：
   - 测试连续为 12 门课程分配颜色，验证生成的 12 个 HEX 颜色互不相同且相邻色差大于阈值。
   - 测试 `assignColorsForCourses` 在三种色板风格下均能稳定输出合法 `#RRGGBB` 颜色。
2. **主题与卡片样式持久化测试 (`flutter/test/theme_and_prefs_test.dart`)**：
   - 测试修改 `ThemeConfig`、`BackgroundConfig`、`CourseCardStyle` 后，重新读取 `PrefStore` 状态能够完整还原。
   - 测试课表视图 `GridViewContent` 在自定义 `rowHeight`（如 `72.0`）和 `fontScale`（如 `1.2`）下能正常布局且不发生 `RenderFlex overflowed`。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试全部通过。
