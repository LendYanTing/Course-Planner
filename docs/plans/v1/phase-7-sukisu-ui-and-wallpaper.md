# Phase 7：借鉴 SukiSU Ultra 的 UI 体系重构、课表可读性修复与安卓原生壁纸选图

## 1. 阶段目标与问题诊断

当前版本虽然实现了基础的莫奈取色和壁纸图层，但存在 3 个严重的视觉与体验缺陷：
1. **UI 还是原生 Flutter MD 线框感，且主题色没有应用到背景与卡片**：
   - 在 `flutter/lib/app/theme.dart` 的 `_hyperScheme` 中，所有 `surface`、`surfaceContainer`、`scaffoldBackgroundColor` 被硬编码写死成了纯白 `#FFFFFF` / 纯黑 `#000000` / 死灰 `#1C1C1E`，**导致无论选什么主题色或莫奈壁纸，页面背景和卡片全都是死黑/死白，完全丢失了 SukiSU Ultra 标志性的「主题色浸润背景（Tonal Surface）+ 分段圆角卡片（Segmented Card）」质感**。
   - 全局 `inputDecorationTheme` 写死了 `OutlineInputBorder()`，导致输入框、下拉框全都是生硬的 1px 直角/细线框。
2. **课表星期数与网格在深色/浅色及任何主题下都极难看清**：
   - `flutter/lib/presentation/calendar/grid_view.dart` 第 309、319 行把 `12月` 和 `周一 ~ 周日` 的文字颜色写成了 `colors.outline`（原本用于画细边框的低对比度暗灰色 `#48484A`），字号仅 `11px` 且无托底背景，在深色模式或壁纸上几乎隐形！
   - `grid_view.dart` 第 464、465、510 行在深色模式下依然硬编码了浅色模式专用的 `#EDF4FF`（浅蓝）、`#FFF2E4`（浅橙）和 `Colors.black45`（黑色半透明文字），导致深色模式下课表配色严重违和。
3. **背景图在 Android 端完全不可用**：
   - `appearance_settings_page.dart` 的 `_LocalImagePathField` 竟然让用户在手机上手输 `C:\Pictures\wallpaper.jpg` 绝对路径，既没有调用 Android 系统相册/文件选择器，也没有把选中的图片 URI 拷贝到 App 私有目录，在 Android Scoped Storage 下完全无法使用。

本阶段将**借鉴 SukiSU-Nova / SukiSU Ultra 的设计语言与实现方式**（用 Flutter 原生复刻其视觉与机制，不直接照搬 Kotlin 代码），彻底解决上述 3 大问题。

---

## 2. 借鉴 SukiSU Ultra 的核心 UI 设计原则

在 SukiSU Ultra (`manager/app/src/main/java/com/sukisu/nova/ui/`) 中，高级感来自以下 5 个核心设计机制：

1. **主题色浸润全身（Tonal Surface Hierarchy）**：
   - 页面背景（`Scaffold.backgroundColor`）**绝不是死黑或死白**，而是使用 `colorScheme.surfaceContainer`（带有主题色冷暖倾向的柔和背景色；仅当用户单独开启「纯黑 AMOLED 深色模式」时才变为 `#000000`）。
   - 卡片与列表项容器使用 `colorScheme.surfaceBright`（浅色模式下明亮柔和，深色模式下比背景高一阶的莫奈色调容器）或 `colorScheme.surfaceContainerLow`。
   - 当设置了自定义背景图时，卡片颜色通过 `backgroundAwareColor` 自动乘以卡片透明度（如 `0.75 ~ 0.90`），使设置页、待办页、弹窗的卡片也能呈现出通透的磨砂层次。
2. **分段圆角列表容器（`SegmentedColumn` & `SegmentedListItem`）**：
   - 一组设置项或表单项不再是用 `Divider` 分割的传统 `Card`，而是**分段连接卡片**：
     - 组内**第一项**顶部为大圆角 `24dp`、底部为小圆角 `6dp`；
     - 组内**中间项**四角均为小圆角 `6dp`；
     - 组内**最后一项**顶部为小圆角 `6dp`、底部为大圆角 `24dp`；
     - 若组内**只有一项**，四角均为 `24dp`；
     - 相邻两项之间留出 **`2dp` 的微间隙**（透出底下的 `surfaceContainer` 背景色），点击时带有 **`0.97` 弹簧按压缩放反馈**！
3. **圆角撞色图标块（`IconTile`）**：
   - 列表项左侧的图标不再是干瘪的灰白色裸 Icon，而是放在一个 **`36×36 dp`、圆角 `12dp`、底色为 `colorScheme.secondaryContainer`、图标颜色为 `colorScheme.onSecondaryContainer`** 的精致色块中。
4. **胶囊悬浮滑块（`CapsuleSlider`）**：
   - 滑块轨道高度为 `8dp`（圆角胶囊），激活段为 `colorScheme.primary`，未激活段为 `colorScheme.primary.withValues(alpha: 0.20)`；
   - 滑块圆钮（Thumb）为 `24dp` 圆形，**内部填充 `colorScheme.surfaceContainerLowest`，外圈 `2dp` `colorScheme.primary` 描边环**，拖动时带 `40dp` 的半透明光晕（Halo）与微放大动效。
5. **无边框填充式输入框（Filled Borderless Input）**：
   - 废除全局 `OutlineInputBorder()` 细线框，所有输入框默认使用 `filled: true`、`fillColor: colorScheme.surfaceContainerHighest`、`border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none)`，聚焦时仅用 `1.5dp` 的 `colorScheme.primary` 圆角描边。

---

## 3. 涉及文件清单

### 新增文件
- `flutter/lib/presentation/adaptive/app_segmented.dart` — 实现 SukiSU 风格的 `AppSegmentedColumn`、`AppSegmentedItem`、`AppSegmentedSwitchItem`、`AppIconTile`。
- `flutter/lib/presentation/adaptive/app_capsule_slider.dart` — 实现 SukiSU 风格的 `AppCapsuleSlider`（8dp 胶囊轨道 + 24dp 空心描边圆钮）。
- `flutter/lib/core/media/wallpaper_picker.dart` — 跨平台（Android MethodChannel + Windows 文件选择）壁纸选图并拷贝到 App 私有 `backgrounds/` 目录的服务。
- `flutter/test/sukisu_ui_components_test.dart` — 测试 `AppSegmentedColumn`、`AppIconTile`、`AppCapsuleSlider`、课表星期头高对比度渲染与壁纸选图服务。

### 修改文件
- `flutter/lib/app/theme.dart` — 重构 `_hyperScheme` 与 `_base`：保留 `ColorScheme.fromSeed` / `fromImageProvider` 生成的莫奈 tonal surfaces（`surfaceContainer` 作为 `scaffoldBackgroundColor`，`surfaceBright` / `surfaceContainerLow` 作为卡片色），替换全局 `inputDecorationTheme` 为圆角无框填充风格，配置 `SliderThemeData` 为 SukiSU 胶囊空心圆钮风格。
- `flutter/lib/presentation/adaptive/adaptive.dart` & `flutter/lib/presentation/adaptive/app_card.dart` — 导出新增组件，`AppCard` 默认使用主题感知的 `surfaceBright` / `surfaceContainerLow` 并移除刺眼的白色硬边。
- `flutter/lib/presentation/calendar/grid_view.dart` & `flutter/lib/presentation/calendar/week_page.dart` — 彻底修复星期栏（`12月`、`周一 ~ 周日`、日期数字）和课表网格在深色/浅色模式及壁纸下的对比度与配色。
- `flutter/android/app/src/main/AndroidManifest.xml` — 增加 `READ_MEDIA_IMAGES` 与 `READ_EXTERNAL_STORAGE` 权限声明。
- `flutter/android/app/src/main/kotlin/com/trysting/courseplanner/MainActivity.kt` — 新增 `course_planner/media` MethodChannel（`pickWallpaper` 方法：调起系统图片选择器，将 `content://` URI 流拷贝到 `filesDir/backgrounds/wallpaper_<ts>.jpg` 并返回私有路径）。
- `flutter/lib/presentation/settings/appearance_settings_page.dart` & `flutter/lib/presentation/settings/settings_page.dart` — 全面应用 `AppSegmentedColumn`、`AppIconTile`、`AppCapsuleSlider`；把壁纸设置区的路径输入框替换为「从相册 / 本地选择图片」按钮 + 缩略图预览 + 移除按钮（保留桌面端/测试用的路径输入折叠项或测试 Key 兼容）。

---

## 4. 详细设计与分步实施指南

### Step 1：重构 `flutter/lib/app/theme.dart`（让主题色真正浸润背景与组件）

1. **修复 `_hyperScheme`（不要抹杀莫奈 Tonal Surface！）**：
   - 删除原本在 `_hyperScheme` 中把 `surface`、`surfaceContainer`、`surfaceContainerLow`、`surfaceContainerHigh` 全部写死为 `#FFFFFF` 或 `#1C1C1E` 的代码！
   - 改为基于 `seeded`（由 `ColorScheme.fromSeed` 或 `ColorScheme.fromImageProvider` 生成的莫奈色板）进行微调：
     - **浅色模式**：
       - `scaffoldBackgroundColor`: `seeded.surfaceContainer`（带有莫奈主题色调的柔和底色，而非死灰 `#F2F3F5`）
       - 卡片/分段项底色：`seeded.surfaceBright`（或 `Color.lerp(Colors.white, seeded.primary, 0.03)!`）
     - **深色模式**：
       - `scaffoldBackgroundColor`: `seeded.surfaceContainerLowest`（或带有深邃莫奈色调的 `Color.lerp(const Color(0xFF0E1015), seeded.primary, 0.07)!`）
       - 卡片/分段项底色：`seeded.surfaceContainerHigh`（带有明显主题色倾向的深色卡片，与底色形成清晰的 tonal 对比！）
   - `AppStyleTokens.hyperOS` 的 `borderColor` 调整为极柔和的 `seeded.outlineVariant.withValues(alpha: 0.28)`（`borderWidth: 0.5`），不再在深色卡片四周画突兀的白圈。

2. **升级全局 `InputDecorationTheme` 与 `ChipTheme`、`SliderTheme`**：
   - **`InputDecorationTheme`**：
     ```dart
     inputDecorationTheme: InputDecorationTheme(
       filled: true,
       fillColor: effective.surfaceContainerHighest.withValues(alpha: 0.65),
       isDense: true,
       contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
       border: OutlineInputBorder(
         borderRadius: BorderRadius.circular(16),
         borderSide: BorderSide.none,
       ),
       enabledBorder: OutlineInputBorder(
         borderRadius: BorderRadius.circular(16),
         borderSide: BorderSide.none,
       ),
       focusedBorder: OutlineInputBorder(
         borderRadius: BorderRadius.circular(16),
         borderSide: BorderSide(color: effective.primary, width: 1.5),
       ),
     ),
     ```
   - **`ChipThemeData`**：
     - 去掉默认 `FilterChip` / `ChoiceChip` / `ActionChip` 刺眼的 `outline` 边框（`side: BorderSide.none`），未选中时底色为 `effective.surfaceContainerHighest.withValues(alpha: 0.7)`，选中时底色为 `effective.secondaryContainer` 或 `effective.primaryContainer`，圆角 `BorderRadius.circular(12)`。
   - **自定义 Hollow Ring Slider Thumb (`_HollowRingSliderThumbShape`)**：
     - 在 `theme.dart` 中实现一个 `SliderComponentShape`，绘制 SukiSU 标志性的 **`24dp` 外径、`surfaceContainerLowest` 实心圆底 + `2.5dp` `primary` 描边环** 的滑块圆钮，轨道高度 `trackHeight: 8.0`，`activeTrackColor: effective.primary`，`inactiveTrackColor: effective.primary.withValues(alpha: 0.18)`。这样全应用所有 `Slider` 自动拥有 SukiSU 的 `CapsuleSlider` 外观！

---

### Step 2：实现 SukiSU 风格 `AppSegmentedColumn` 与 `AppIconTile` (`flutter/lib/presentation/adaptive/app_segmented.dart`)

复刻 SukiSU `SegmentedList.kt` 的核心视觉组件：

1. **`AppIconTile`**：
   ```dart
   class AppIconTile extends StatelessWidget {
     const AppIconTile({
       super.key,
       required this.icon,
       this.backgroundColor,
       this.iconColor,
     });

     final IconData icon;
     final Color? backgroundColor;
     final Color? iconColor;

     @override
     Widget build(BuildContext context) {
       final scheme = Theme.of(context).colorScheme;
       return Container(
         width: 36,
         height: 36,
         alignment: Alignment.center,
         decoration: BoxDecoration(
           color: backgroundColor ?? scheme.secondaryContainer,
           borderRadius: BorderRadius.circular(12),
         ),
         child: Icon(
           icon,
           size: 20,
           color: iconColor ?? scheme.onSecondaryContainer,
         ),
       );
     }
   }
   ```

2. **`AppSegmentedColumn`**：
   - 接收 `String? title`、`IconData? titleIcon`、`EdgeInsetsGeometry margin`、`List<Widget> children`。
   - 顶部若有 `title`，渲染 `Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.primary)))`。
   - 内部遍历 `children`（共 `count` 项）：
     - 第 `i` 项的 `BorderRadius`：
       - `topRadius = (i == 0) ? const Radius.circular(24) : const Radius.circular(6)`
       - `bottomRadius = (i == count - 1) ? const Radius.circular(24) : const Radius.circular(6)`
     - 每一项包裹在 `ClipRSuperellipse(borderRadius: ...)` + `Material(color: scheme.surfaceBright)`（深色模式下为 `scheme.surfaceContainerHigh`）中，相邻两项之间插入 `const SizedBox(height: 2)`！
   - 将 `SettingsPage` 和 `AppearanceSettingsPage` 中的分组卡片升级为 `AppSegmentedColumn` + `AppIconTile`，立刻呈现出纯正的 SukiSU 视觉层次！

---

### Step 3：彻底修复课表星期栏与网格可读性 (`grid_view.dart` & `week_page.dart`)

1. **修复 `GridViewContent._weekHeader` (`flutter/lib/presentation/calendar/grid_view.dart` 第 296-344 行)**：
   - 外层包裹一个高可读性的托底容器：
     ```dart
     final isDark = Theme.of(context).brightness == Brightness.dark;
     final headerBg = widget.hasBackground
         ? colors.surfaceContainer.withValues(alpha: isDark ? 0.78 : 0.85)
         : colors.surfaceContainer;
     ```
   - **左侧月份文字（如 `12月`）**：
     - 字号 `12`，`fontWeight: FontWeight.w700`，颜色使用 **`colors.primary`**（不再使用看不清的 `colors.outline`！）。
   - **星期文字（`周一` ~ `周日`）**：
     - 字号 `11.5`，`fontWeight: FontWeight.w600`，当天为 `colors.primary`，其余天使用 **`colors.onSurface.withValues(alpha: 0.88)`**（绝不再用 `colors.outline`！）。
   - **日期数字（`7` ~ `13`）**：
     - 容器大小 `24×24`，字号 `12`，`fontWeight: FontWeight.w700`；
     - 当天（`_isToday`）：背景 `colors.primary` 圆圈，文字 `colors.onPrimary`；
     - 非当天：文字 `colors.onSurface`。

2. **修复 `_GridCanvasState.build` 中的硬编码浅色网格与黑色文字 (`grid_view.dart` 第 430-530 行)**：
   - 检查当前 `final isDark = Theme.of(context).brightness == Brightness.dark;`：
   - **上午 / 下午行背景色 (`morningColor` / `afternoonColor`)**：
     - 当 `!widget.hasBackground && !isDark`（浅色无壁纸默认状态）：为了兼容现有 `grid_view_widget_test.dart` 对默认浅色行颜色的断言（如有），保持上午 `const Color(0xFFEDF4FF)`、下午 `const Color(0xFFFFF2E4)`（或与 `colors.primaryContainer` 柔和混合）；
     - 当 **`isDark`（深色模式）** 时：上午使用 `Color.lerp(colors.surfaceContainerLow, colors.primary, 0.08)!`，下午使用 `Color.lerp(colors.surfaceContainer, colors.tertiary, 0.08)!`；
     - 当 `widget.hasBackground` 时：乘以 `alpha: isDark ? 0.55 : 0.45`，既能透出壁纸又能保証网格与左侧节次栏清晰可读！
   - **左侧节次栏（第 1 节 `08:00`）**：
     - 节次序号（`1`, `2`...）：上午用 `isDark ? colors.primary : const Color(0xFF3A6FB0)`，下午用 `isDark ? colors.tertiary : const Color(0xFFE07B39)`；
     - 节次开始时间（`08:00`, `08:50`）：颜色改为 **`colors.onSurfaceVariant`**（字号 `10`, `FontWeight.w500`），**彻底删除原本在深色模式下完全看不清的 `Colors.black45`**！

3. **同步修复 `week_page.dart` 中 `_WeekHeader` 与 `_DayHeader`（时间轴周视图）**：
   - 将 `_DayHeader` 中的 `color: Colors.grey` 改为 `colors.onSurface.withValues(alpha: 0.85)` + `FontWeight.w600`；
   - 将 `weekGutterLabel` 的 `colors.outline` 改为 `colors.primary` + `FontWeight.w700`；
   - 当 `hasBackground` 为 `true` 时，为 `_WeekHeader` 添加 `colors.surfaceContainer.withValues(alpha: 0.78)` 半透明托底。

---

### Step 4：实现 Android / Windows 原生壁纸选图并拷贝到私有目录

借鉴 SukiSU `ImageStorage.kt` 的 `stageUri` + `replace` 机制：

1. **在 `flutter/android/app/src/main/AndroidManifest.xml` 中增加权限声明**（放在 `RECORD_AUDIO` 下方）：
   ```xml
   <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>
   <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
   ```
2. **在 `flutter/android/app/src/main/kotlin/com/trysting/courseplanner/MainActivity.kt` 中新增 `course_planner/media` MethodChannel**：
   - 常量：` MEDIA_CHANNEL_NAME = "course_planner/media"`，`PICK_WALLPAPER_REQUEST_CODE = 4303`。
   - 处理 `"pickWallpaper"` 方法：
     ```kotlin
     private fun pickWallpaper(result: MethodChannel.Result) {
         if (pendingWallpaperResult != null) {
             result.error("busy", "正在选择图片", null)
             return
         }
         val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
             type = "image/*"
             addCategory(Intent.CATEGORY_OPENABLE)
         }
         pendingWallpaperResult = result
         try {
             @Suppress("DEPRECATION")
             startActivityForResult(Intent.createChooser(intent, "选择背景壁纸"), PICK_WALLPAPER_REQUEST_CODE)
         } catch (e: Exception) {
             pendingWallpaperResult = null
             result.error("pick_failed", e.message ?: "无法打开系统相册", null)
         }
     }
     ```
   - 在 `onActivityResult` 中处理 `PICK_WALLPAPER_REQUEST_CODE`：
     - 当 `resultCode == Activity.RESULT_OK` 且 `data?.data != null` 时：
     - 创建私有目录 `val dir = File(filesDir, "backgrounds").apply { mkdirs() }`；
     - 创建目标文件 `val target = File(dir, "wallpaper_${System.currentTimeMillis()}.jpg")`；
     - 使用 `contentResolver.openInputStream(uri)?.use { input -> target.outputStream().use { output -> input.copyTo(output) } }` 将图片流复制到私有文件；
     - 删除 `dir` 下旧的 `wallpaper_*` 文件；
     - 调用 `result.success(target.absolutePath)` 返回该私有文件的绝对路径！（若用户取消则返回 `result.success(null)`）。
   - **为什么这样最稳**：Android 的 `ACTION_GET_CONTENT` 会由系统文件选择器自动临时授予所选 `Uri` 的读取流权限，复制到 `filesDir/backgrounds/` 后变成 App 自己的私有文件，重启应用后依然 100% 可读，且 `ColorScheme.fromImageProvider(FileImage(File(path)))` 可以直接从中提取莫奈主题色！

3. **新建 `flutter/lib/core/media/wallpaper_picker.dart`**：
   - 封装 `WallpaperPickerService`：
     - 在 **Android** 上：调用 `MethodChannel('course_planner/media').invokeMethod<String>('pickWallpaper')`。
     - 在 **Windows** 上：调用 PowerShell 单行脚本拉起系统原生 `System.Windows.Forms.OpenFileDialog`（筛选 `*.jpg;*.jpeg;*.png;*.webp`），选中后将图片拷贝到 `getApplicationSupportDirectory()/backgrounds/wallpaper_<ts>.ext` 并返回新路径！
     - 提供 `importFromFilePath(String rawPath)`：当用户手动输入或测试传入路径时，若文件存在，也将其复制到私有 `backgrounds/` 目录并返回。

4. **升级 `flutter/lib/presentation/settings/appearance_settings_page.dart` 的壁纸设置区**：
   - 在预设壁纸下方，放置显著的 **「从相册 / 本地选择图片」** 主按钮（`FilledButton.tonalIcon(icon: Icon(Icons.add_photo_alternate_outlined), label: Text('从相册 / 本地选择图片'))`）和 **「清除图片」** 按钮（当已选本地图片时显示）。
   - 将原本的 `_LocalImagePathField`（`ValueKey('wallpaper-path-field')` 和 `ValueKey('wallpaper-path-apply')`）收纳进一个紧凑的 `ExpansionTile(title: Text('高级：手动输入图片路径', style: TextStyle(fontSize: 12)))`（或者保留在下方但弱化为辅助项），确保现有的 widget 测试依然能找到 `wallpaper-path-field` Key，同时真实用户在 Android 和 Windows 上点一下「从相册 / 本地选择图片」就能直接选图并触发莫奈取色！

---

## 5. 测试与验收标准

1. **检查现有测试 100% 兼容**：
   - `flutter/test/theme_and_prefs_test.dart`、`flutter/test/grid_view_widget_test.dart` 中的所有断言必须保持通过。
2. **新增 `flutter/test/sukisu_ui_components_test.dart`**：
   - 测试 `AppSegmentedColumn` 在 1 项、2 项、3 项时分别生成正确的首尾 `24dp` 与中间 `6dp` 圆角及 `2dp` 间距。
   - 测试课表 `GridViewContent` 在深色模式（`ThemeData.dark()`）和有背景图（`hasBackground: true`）下，星期头（`周一`~`周日`）与节次时间文字不使用 `colors.outline` 或 `Colors.black45`。
   - 测试 `WallpaperPickerService`（通过注入 mock channel handler）在选中图片后能正确更新 `backgroundConfigProvider.imagePath`。
3. **运行全量检查**：
   ```bash
   cd flutter
   flutter analyze
   flutter test
   ```
   确保 0 error，所有测试全部通过。
