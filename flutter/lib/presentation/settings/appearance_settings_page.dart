import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/media/wallpaper_picker.dart';
import '../../state/prefs.dart';
import '../adaptive/adaptive.dart';
import '../widgets/calendar_background.dart';

/// The eight curated theme seeds offered by the appearance page (phase 3).
/// Hex values match `ThemeConfig.seedColorHex`'s `#RRGGBB` format.
const _kSeedPresets = <({String hex, String label})>[
  (hex: '#3F51B5', label: '靛青'),
  (hex: '#26A69A', label: '薄荷'),
  (hex: '#EC407A', label: '樱粉'),
  (hex: '#FFA000', label: '琥珀'),
  (hex: '#7E57C2', label: '紫藤'),
  (hex: '#9CCC65', label: '青柠'),
  (hex: '#78909C', label: '岩灰'),
  (hex: '#29B6F6', label: '海蓝'),
];

/// 外观与课表定制 (`/settings/appearance`).
///
/// Collects every local-only look-and-feel preference: theme mode and seed
/// colour, the calendar wallpaper, the course-card geometry, the UI engine, the
/// bottom-bar material, the course-tile line budget, the month grid height and
/// the 上午/下午 boundary. Nothing here is synced to the server.
class AppearanceSettingsPage extends ConsumerWidget {
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(tileTextLinesProvider);
    final bottomBar = ref.watch(bottomBarStyleProvider);
    final variant = ref.watch(uiVariantProvider);
    final themeConfig = ref.watch(themeConfigProvider);
    final background = ref.watch(backgroundConfigProvider);
    final cardStyle = ref.watch(courseCardStyleProvider);

    return Scaffold(
      appBar: AppTopBar(title: '外观与课表定制'),
      body: ListView(
        // Keeps the last row clear of the system inset.
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          _PreviewCard(style: cardStyle, background: background),
          _themeSection(context, ref, themeConfig, background),
          _backgroundSection(context, ref, background),
          _courseSection(
            context,
            ref,
            cardStyle,
            lines: lines,
            bottomBar: bottomBar,
            variant: variant,
          ),
          _resetSection(context, ref),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live preview
// ---------------------------------------------------------------------------

/// A 3 × 2 mini timetable over the current wallpaper. Everything below it
/// writes to the same providers, so dragging a slider repaints this card.
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.style, required this.background});

  final CourseCardStyle style;
  final BackgroundConfig background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return AppCard(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Icon(Icons.visibility_outlined, size: 18, color: muted),
                const SizedBox(width: 8),
                Text(
                  '实时预览',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '拖动滑块即时生效',
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: ClipRRect(
              borderRadius:
                  BorderRadius.circular(context.tokens.cardRadiusSmall),
              child: SizedBox(
                height: 120,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CalendarBackground.previewFor(
                      context,
                      background,
                      height: 120,
                    ),
                    _MiniTimetable(style: style),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The preview's course grid: three columns, two period rows, two course blocks
/// whose alpha, radius, gap, text scale and background come from the live
/// preferences.
class _MiniTimetable extends StatelessWidget {
  const _MiniTimetable({required this.style});

  final CourseCardStyle style;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(style.borderRadius);
    final margin = EdgeInsets.all(style.margin);
    final textStyle = TextStyle(
      fontSize: 10 * style.fontScale,
      fontWeight: FontWeight.w600,
      height: 1.1,
    );

    Widget block(String label, Color color, Color onColor) => Container(
          margin: margin,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            // Same alpha treatment the real tiles use.
            color: color.withValues(alpha: style.opacity),
            borderRadius: radius,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle.copyWith(color: onColor),
          ),
        );

    Widget empty() => Container(
          margin: margin,
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: 0.18),
            borderRadius: radius,
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: block('高等数学', scheme.primary, scheme.onPrimary),
                ),
                Expanded(child: empty()),
                Expanded(child: empty()),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: empty()),
                Expanded(
                  child: block('大学英语', scheme.tertiary, scheme.onTertiary),
                ),
                Expanded(child: empty()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

Widget _themeSection(
  BuildContext context,
  WidgetRef ref,
  ThemeConfig config,
  BackgroundConfig background,
) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  final hasImage = background.imagePath?.isNotEmpty ?? false;

  return _SectionCard(
    title: '主题与取色',
    icon: Icons.palette_outlined,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<ThemeMode>(
            // The check icon would crowd the three Chinese labels on a phone.
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
              ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
              ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
            ],
            selected: {config.mode},
            onSelectionChanged: (selection) => ref
                .read(themeConfigProvider.notifier)
                .setMode(selection.first),
          ),
        ),
      ),
      SwitchListTile(
        value: config.useWallpaperMonet,
        onChanged: (value) =>
            ref.read(themeConfigProvider.notifier).setUseWallpaperMonet(value),
        secondary: const Icon(Icons.auto_fix_high),
        title: const Text('从背景壁纸自动取色'),
        subtitle: Text(
          hasImage ? '当前配色来自本地壁纸' : '设置本地背景图后生效',
          style: const TextStyle(fontSize: 11),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            Text('主题色', style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              config.seedColorHex,
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final preset in _kSeedPresets)
              _SeedSwatch(
                hex: preset.hex,
                label: preset.label,
                selected: config.seedColorHex == preset.hex,
                onTap: () => ref
                    .read(themeConfigProvider.notifier)
                    .setSeedHex(preset.hex),
              ),
          ],
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: TextButton.icon(
            onPressed: () => _pickCustomSeed(context, ref),
            icon: const Icon(Icons.colorize_outlined, size: 18),
            label: const Text('自定义色值'),
          ),
        ),
      ),
    ],
  );
}

Widget _backgroundSection(
  BuildContext context,
  WidgetRef ref,
  BackgroundConfig config,
) {
  final scheme = Theme.of(context).colorScheme;
  final muted = scheme.onSurfaceVariant;
  final hasImage = config.imagePath?.isNotEmpty ?? false;

  // SukiSU-style segmented card: one 2 dp-separated block per wallpaper row.
  return AppSegmentedColumn(
    title: '背景壁纸',
    titleIcon: Icons.wallpaper_outlined,
    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            _WallpaperChoice(
              key: const ValueKey('wallpaper-none'),
              label: '无背景',
              selected: !config.hasBackground,
              onTap: () => ref.read(backgroundConfigProvider.notifier).clear(),
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: Center(
                  child: Icon(Icons.block, size: 18, color: muted),
                ),
              ),
            ),
            for (final preset in kCalendarWallpaperPresets)
              _WallpaperChoice(
                key: ValueKey('wallpaper-preset-${preset.id}'),
                label: preset.label,
                selected: config.presetId == preset.id,
                onTap: () => ref
                    .read(backgroundConfigProvider.notifier)
                    .setPresetId(preset.id),
                child: DecoratedBox(
                  decoration:
                      CalendarBackground.presetDecoration(context, preset.id),
                ),
              ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          hasImage
              ? '当前使用本地图片，选择预设会替换它。'
              : '预设壁纸立即生效；也可以从相册选图，图片会复制到应用私有目录。',
          style: TextStyle(fontSize: 11, color: muted),
        ),
      ),
      _WallpaperImageActions(config: config),
      ExpansionTile(
        key: const ValueKey('wallpaper-advanced-path'),
        leading: const AppIconTile(icon: Icons.edit_note_outlined),
        title: const Text(
          '高级：手动输入图片路径',
          style: TextStyle(fontSize: 12),
        ),
        shape: const Border(),
        collapsedShape: const Border(),
        children: const [_LocalImagePathField()],
      ),
      _SliderTile(
        title: '背景模糊',
        valueLabel: '${config.blurSigma.round()}',
        value: config.blurSigma,
        min: BackgroundConfig.minBlurSigma,
        max: BackgroundConfig.maxBlurSigma,
        divisions: BackgroundConfig.maxBlurSigma.round(),
        sliderKey: const ValueKey('background-blur-slider'),
        hint: '高斯模糊越高，壁纸越朦胧，文字越清晰（预设渐变本身已是柔和的）。',
        onChanged: (value) =>
            ref.read(backgroundConfigProvider.notifier).setBlurSigma(value),
      ),
      _SliderTile(
        title: '遮罩浓度',
        valueLabel: '${(config.scrimOpacity * 100).round()}%',
        value: config.scrimOpacity,
        min: BackgroundConfig.minScrimOpacity,
        max: BackgroundConfig.maxScrimOpacity,
        divisions: 85,
        sliderKey: const ValueKey('background-scrim-slider'),
        hint: '遮罩越浓，背景越淡，课表文字对比度越高。',
        onChanged: (value) =>
            ref.read(backgroundConfigProvider.notifier).setScrimOpacity(value),
      ),
    ],
  );
}

/// The primary wallpaper action: pick from the gallery / a native file dialog,
/// plus the current private-image thumbnail and its clear button.
class _WallpaperImageActions extends ConsumerWidget {
  const _WallpaperImageActions({required this.config});

  final BackgroundConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final path = config.imagePath;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppIconTile(icon: Icons.add_photo_alternate_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  key: const ValueKey('wallpaper-pick-button'),
                  onPressed: () => _chooseWallpaperImage(context, ref),
                  icon: const Icon(
                    Icons.add_photo_alternate_outlined,
                    size: 18,
                  ),
                  label: const Text('从相册 / 本地选择图片'),
                ),
              ),
            ],
          ),
          if (path != null && path.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                _LocalWallpaperThumbnail(path: path),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '图片已复制到应用私有目录，重启后依然有效。',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('wallpaper-image-clear'),
                  onPressed: () =>
                      ref.read(backgroundConfigProvider.notifier).clear(),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清除图片'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 64 × 44 preview of the stored private wallpaper; a placeholder is shown when
/// the file disappears (cleared app data, uninstalled storage, …).
class _LocalWallpaperThumbnail extends StatelessWidget {
  const _LocalWallpaperThumbnail({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: 64,
      height: 44,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
    );
    final file = File(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        key: const ValueKey('wallpaper-image-thumbnail'),
        width: 64,
        height: 44,
        child: file.existsSync()
            ? Image.file(
                file,
                width: 64,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
              )
            : placeholder,
      ),
    );
  }
}

/// Opens the native picker and stores the returned private copy.
Future<void> _chooseWallpaperImage(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  // Captured before the await: the system dialog can outlive this page.
  final background = ref.read(backgroundConfigProvider.notifier);
  final picked = await ref.read(wallpaperPickerProvider).pickWallpaper();
  if (picked == null || picked.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('未选择图片或该平台不支持')),
    );
    return;
  }
  await background.setImagePath(picked);
  messenger.showSnackBar(const SnackBar(content: Text('已设置壁纸')));
}

Widget _courseSection(
  BuildContext context,
  WidgetRef ref,
  CourseCardStyle style, {
  required ({int title, int location}) lines,
  required BottomBarStyle bottomBar,
  required UiVariant variant,
}) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;

  return _SectionCard(
    title: '课程卡片与课表',
    icon: Icons.style_outlined,
    children: [
      _SliderTile(
        title: '卡片不透明度',
        valueLabel: '${(style.opacity * 100).round()}%',
        value: style.opacity,
        min: CourseCardStyle.minOpacity,
        max: CourseCardStyle.maxOpacity,
        divisions: 70,
        sliderKey: const ValueKey('card-opacity-slider'),
        hint: '半透明卡片在壁纸上呈磨砂效果。',
        onChanged: (value) =>
            ref.read(courseCardStyleProvider.notifier).setOpacity(value),
      ),
      _SliderTile(
        title: '卡片圆角',
        valueLabel: '${style.borderRadius.round()} dp',
        value: style.borderRadius,
        min: CourseCardStyle.minBorderRadius,
        max: CourseCardStyle.maxBorderRadius,
        divisions: 12,
        sliderKey: const ValueKey('card-radius-slider'),
        onChanged: (value) =>
            ref.read(courseCardStyleProvider.notifier).setBorderRadius(value),
      ),
      _SliderTile(
        title: '卡片间距',
        valueLabel: '${style.margin.toStringAsFixed(1)} dp',
        value: style.margin,
        min: CourseCardStyle.minMargin,
        max: CourseCardStyle.maxMargin,
        divisions: 35,
        sliderKey: const ValueKey('card-margin-slider'),
        onChanged: (value) =>
            ref.read(courseCardStyleProvider.notifier).setMargin(value),
      ),
      _SliderTile(
        title: '课程文字大小',
        valueLabel: '${(style.fontScale * 100).round()}%',
        value: style.fontScale,
        min: CourseCardStyle.minFontScale,
        max: CourseCardStyle.maxFontScale,
        divisions: 45,
        sliderKey: const ValueKey('card-font-scale-slider'),
        onChanged: (value) =>
            ref.read(courseCardStyleProvider.notifier).setFontScale(value),
      ),
      _SliderTile(
        title: '课表每节行高',
        valueLabel: '${style.rowHeight.round()} dp',
        value: style.rowHeight,
        min: CourseCardStyle.minRowHeight,
        max: CourseCardStyle.maxRowHeight,
        divisions: 46,
        sliderKey: const ValueKey('card-row-height-slider'),
        onChanged: (value) =>
            ref.read(courseCardStyleProvider.notifier).setRowHeight(value),
      ),
      const Divider(height: 1, indent: 16, endIndent: 16),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Text(
          '课表与底栏显示',
          style: theme.textTheme.bodySmall?.copyWith(
            color: muted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('界面风格引擎'),
        subtitle: Text(variant == UiVariant.hyperOS
            ? 'HyperOS 风格 · 超椭圆大圆角与弹簧动效'
            : 'Material Design 3 · 标准 Material 外观'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickUiVariant(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.blur_on_outlined),
        title: const Text('底栏外观'),
        subtitle: Text(
          '${_bottomBarStyleLabel(bottomBar)} · '
          '${_bottomBarStyleShortHint(bottomBar)}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickBottomBarStyle(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.format_line_spacing),
        title: const Text('课表文字行数'),
        subtitle: Text(
          '课程名称 ${lines.title} 行 · 上课地点 ${lines.location} 行',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickTileTextLines(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.calendar_view_month),
        title: const Text('月视图格子高度'),
        subtitle: Text(
          '${ref.watch(monthCellHeightProvider).round()} dp · 竖屏留白过多时调大',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickMonthCellHeight(context, ref),
      ),
      ListTile(
        leading: const Icon(Icons.wb_twilight),
        title: const Text('中午分界点'),
        subtitle: Text(
          '${formatMinuteOfDay(ref.watch(noonBoundaryProvider))} · '
          '课表中早于此时刻的节次算上午（仅本地）',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _pickNoonBoundary(context, ref),
      ),
    ],
  );
}

Widget _resetSection(BuildContext context, WidgetRef ref) {
  final theme = Theme.of(context);
  final muted = theme.colorScheme.onSurfaceVariant;
  return AppCard(
    padding: EdgeInsets.zero,
    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '主题模式与主题色、背景壁纸、课程卡片样式，以及课表/月视图/底栏显示偏好都会回到初始状态。课程、日程与待办数据不受影响。',
            style: TextStyle(fontSize: 11, color: muted),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: () => _resetAppearance(context, ref),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认外观'),
          ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

/// Card with an icon + title header and a list of rows beneath it.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}

/// One labelled slider with its current value on the right.
class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.sliderKey,
    this.hint,
  });

  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final Key? sliderKey;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: theme.textTheme.bodyMedium),
              ),
              Text(
                valueLabel,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
          Slider(
            key: sliderKey,
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            label: valueLabel,
            onChanged: onChanged,
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                hint!,
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Round clickable seed colour; the current one carries a check mark.
class _SeedSwatch extends StatelessWidget {
  const _SeedSwatch({
    required this.hex,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String hex;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = AppTheme.parseHex(hex) ?? scheme.primary;
    final onColor =
        color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return Tooltip(
      message: label,
      child: InkResponse(
        key: ValueKey('seed-swatch-${hex.replaceFirst('#', '')}'),
        onTap: onTap,
        radius: 22,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: selected
              ? Icon(Icons.check, size: 18, color: onColor)
              : null,
        ),
      ),
    );
  }
}

/// Thumbnail + label for one background choice.
class _WallpaperChoice extends StatelessWidget {
  const _WallpaperChoice({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 52,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 52,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: child,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Local wallpaper path editor. The controller mirrors the stored path so
/// "恢复默认外观" also clears the field.
class _LocalImagePathField extends ConsumerStatefulWidget {
  const _LocalImagePathField();

  @override
  ConsumerState<_LocalImagePathField> createState() =>
      _LocalImagePathFieldState();
}

class _LocalImagePathFieldState extends ConsumerState<_LocalImagePathField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(backgroundConfigProvider).imagePath ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    FocusScope.of(context).unfocus();
    final raw = _controller.text;
    final messenger = ScaffoldMessenger.of(context);
    // Captured before the await: the platform copy can outlive this page.
    final background = ref.read(backgroundConfigProvider.notifier);
    if (raw.trim().isEmpty) {
      await background.setImagePath(null);
      return;
    }
    // Typed paths are imported into the private folder first, so the same path
    // keeps working on Android's scoped storage and after the source moves.
    final imported =
        await ref.read(wallpaperPickerProvider).importFromFilePath(raw);
    if (!mounted) return;
    if (imported == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('找不到图片文件，或无法复制到应用目录')),
      );
      return;
    }
    await background.setImagePath(imported);
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(content: Text('已设置壁纸')));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(backgroundConfigProvider, (previous, next) {
      final path = next.imagePath ?? '';
      if (path != _controller.text) _controller.text = path;
    });

    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('wallpaper-path-field'),
                  controller: _controller,
                  decoration: const InputDecoration(
                    labelText: '本地图片路径',
                    hintText: r'C:\Pictures\wallpaper.jpg',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _apply(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: const ValueKey('wallpaper-path-apply'),
                onPressed: _apply,
                child: const Text('应用'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '应用后会复制到应用私有目录并替换预设壁纸；留空并应用可移除背景。',
            style: TextStyle(fontSize: 11, color: muted),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Validates a typed `#RRGGBB` / `RRGGBB` seed, then persists it. Invalid input
/// stays in the dialog with an inline error instead of silently doing nothing.
Future<void> _pickCustomSeed(BuildContext context, WidgetRef ref) async {
  final formKey = GlobalKey<FormState>();
  var draft = ref.read(themeConfigProvider).seedColorHex;

  void submit() {
    if (!(formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context, rootNavigator: true).pop(normalizeHexColor(draft));
  }

  final picked = await showAppDialog<String>(
    context: context,
    title: '自定义主题色',
    content: Form(
      key: formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            initialValue: draft,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: '色值',
              hintText: '#3F51B5',
            ),
            onChanged: (value) => draft = value,
            validator: (value) => normalizeHexColor(value) == null
                ? '请输入 #RRGGBB 或 RRGGBB 形式的色值'
                : null,
            onFieldSubmitted: (_) => submit(),
          ),
          const SizedBox(height: 8),
          const Text(
            '支持 #RRGGBB 或 RRGGBB；非法色值不会被保存。',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('应用')),
    ],
  );
  if (picked != null) {
    await ref.read(themeConfigProvider.notifier).setSeedHex(picked);
  }
}

/// Restores every appearance preference to its first-run value.
Future<void> _resetAppearance(BuildContext context, WidgetRef ref) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    title: '恢复默认外观',
    content: const Text(
      '主题模式与主题色、背景壁纸、课程卡片样式，以及课表/月视图/底栏显示偏好都会回到初始状态。课程、日程与待办数据不受影响。',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
        child: const Text('恢复'),
      ),
    ],
  );
  if (confirmed != true) return;

  await ref.read(courseCardStyleProvider.notifier).reset();

  final theme = ref.read(themeConfigProvider.notifier);
  await theme.setMode(ThemeMode.system);
  await theme.setSeedHex(ThemeConfig.defaultSeedHex);
  await theme.setUseWallpaperMonet(true);

  final background = ref.read(backgroundConfigProvider.notifier);
  await background.clear();
  await background.setBlurSigma(const BackgroundConfig().blurSigma);
  await background.setScrimOpacity(const BackgroundConfig().scrimOpacity);

  await ref.read(bottomBarStyleProvider.notifier).set(BottomBarStyle.liquidGlass);
  final lines = ref.read(tileTextLinesProvider.notifier);
  await lines.setTitle(TileTextLinesController.defaultTitle);
  await lines.setLocation(TileTextLinesController.defaultLocation);
  await ref
      .read(monthCellHeightProvider.notifier)
      .set(MonthCellHeightController.defaultDp);
  await ref
      .read(noonBoundaryProvider.notifier)
      .set(NoonBoundaryController.defaultMinutes);
}

/// Line budget for course tiles: long room names ("逸夫楼201-阶梯教室") need more
/// than one line, long course names more than two.
Future<void> _pickTileTextLines(BuildContext context, WidgetRef ref) async {
  var lines = ref.read(tileTextLinesProvider);
  final picked = await showAppDialog<({int title, int location})>(
    context: context,
    title: '课表文字行数',
    content: StatefulBuilder(
      builder: (ctx, setLocal) {
        Widget slider(String label, int value, ValueChanged<int> onChanged) => Column(
              children: [
                Text('$label：$value 行', style: const TextStyle(fontSize: 14)),
                Slider(
                  value: value.toDouble(),
                  min: TileTextLinesController.minLines.toDouble(),
                  max: TileTextLinesController.maxLines.toDouble(),
                  divisions: TileTextLinesController.maxLines -
                      TileTextLinesController.minLines,
                  label: '$value',
                  onChanged: (v) => setLocal(() => onChanged(v.round())),
                ),
              ],
            );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            slider('课程名称', lines.title,
                (v) => lines = (title: v, location: lines.location)),
            slider('上课地点', lines.location,
                (v) => lines = (title: lines.title, location: v)),
            const Text('地点较长的教室（如「逸夫楼201-阶梯教室」）可以调成 2 行。',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        );
      },
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('取消')),
      FilledButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(lines),
        child: const Text('保存'),
      ),
    ],
  );
  if (picked == null) return;
  final notifier = ref.read(tileTextLinesProvider.notifier);
  await notifier.setTitle(picked.title);
  await notifier.setLocation(picked.location);
}

/// Row-height picker for the month grid.
Future<void> _pickMonthCellHeight(BuildContext context, WidgetRef ref) async {
  var value = ref.read(monthCellHeightProvider);
  final picked = await showAppDialog<double>(
    context: context,
    title: '月视图格子高度',
    content: StatefulBuilder(
      builder: (ctx, setLocal) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${value.round()} dp', style: const TextStyle(fontSize: 14)),
          Slider(
            value: value.clamp(MonthCellHeightController.minDp,
                MonthCellHeightController.maxDp),
            min: MonthCellHeightController.minDp,
            max: MonthCellHeightController.maxDp,
            divisions: 13,
            label: '${value.round()}',
            onChanged: (v) => setLocal(() => value = v),
          ),
          const Text('格子越高，日期格里的条目显示得越完整；竖屏下方留白过多时调大即可。',
              style: TextStyle(fontSize: 11, color: Colors.grey)),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(value), child: const Text('保存')),
    ],
  );
  if (picked != null) await ref.read(monthCellHeightProvider.notifier).set(picked);
}

/// Chinese name of a bottom-bar material.
String _bottomBarStyleLabel(BottomBarStyle style) => switch (style) {
      BottomBarStyle.liquidGlass => '液态玻璃',
      BottomBarStyle.frostedBlur => '毛玻璃',
      BottomBarStyle.solidCapsule => '纯色胶囊',
    };

/// One-line note under the style name inside the picker.
String _bottomBarStyleDescription(BottomBarStyle style) => switch (style) {
      BottomBarStyle.liquidGlass => '实时高斯模糊 + 边缘折射与色散（Impeller 专属，其余平台自动降级）',
      BottomBarStyle.frostedBlur => '标准高斯模糊 + 高光描边，全平台可用',
      BottomBarStyle.solidCapsule => '无实时模糊，低功耗',
    };

/// Short hint for the settings row subtitle.
String _bottomBarStyleShortHint(BottomBarStyle style) => switch (style) {
      BottomBarStyle.liquidGlass => '不支持时自动用毛玻璃',
      BottomBarStyle.frostedBlur => '全平台可用',
      BottomBarStyle.solidCapsule => '低功耗',
    };

/// Bottom-bar material picker. Every option is listed on every device: the bar
/// itself falls back to frosted glass when shader filters are unavailable.
Future<void> _pickBottomBarStyle(BuildContext context, WidgetRef ref) async {
  final current = ref.read(bottomBarStyleProvider);
  final picked = await showAppDialog<BottomBarStyle>(
    context: context,
    title: '底栏外观',
    content: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final style in BottomBarStyle.values)
            ListTile(
              title: Text(_bottomBarStyleLabel(style)),
              subtitle: Text(
                _bottomBarStyleDescription(style),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: current == style ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context, rootNavigator: true).pop(style),
            ),
        ],
      ),
    ),
  );
  if (picked != null) await ref.read(bottomBarStyleProvider.notifier).set(picked);
}

/// Which visual engine the whole app renders with. The switch is immediate:
/// `MaterialApp.router` in `app/router.dart` watches [uiVariantProvider], so no
/// restart is needed.
Future<void> _pickUiVariant(BuildContext context, WidgetRef ref) async {
  final current = ref.read(uiVariantProvider);
  final picked = await showAppDialog<UiVariant>(
    context: context,
    title: '界面风格引擎',
    content: Builder(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final variant in UiVariant.values)
            ListTile(
              title: Text(variant == UiVariant.hyperOS
                  ? 'HyperOS 风格'
                  : 'Material Design 3'),
              subtitle: Text(
                variant == UiVariant.hyperOS
                    ? '超椭圆大圆角、细描边与弹簧动效'
                    : '标准 Material 外观，跟随系统阴影与配色',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: current == variant ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, variant),
            ),
        ],
      ),
    ),
  );
  if (picked != null) await ref.read(uiVariantProvider.notifier).set(picked);
}

/// Lets the user move the 上午/下午 boundary of the 课表 view. Purely local:
/// the server's period templates carry times but no notion of noon.
Future<void> _pickNoonBoundary(BuildContext context, WidgetRef ref) async {
  final current = ref.read(noonBoundaryProvider);
  const presets = <int>[11 * 60, 12 * 60, 13 * 60, 14 * 60, 14 * 60 + 30, 15 * 60];
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('中午分界点'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('课表中开始时刻早于此值的节次算上午，之后的算下午。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        for (final m in presets)
          ListTile(
            title: Text(formatMinuteOfDay(m)),
            trailing: current == m ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, m),
          ),
        ListTile(
          leading: const Icon(Icons.more_time),
          title: const Text('自定义…'),
          onTap: () async {
            final t = await showTimePicker(
              context: ctx,
              initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
            );
            if (t != null && ctx.mounted) {
              Navigator.pop(ctx, t.hour * 60 + t.minute);
            }
          },
        ),
      ],
    ),
  );
  if (picked != null) {
    await ref.read(noonBoundaryProvider.notifier).set(picked);
  }
}
