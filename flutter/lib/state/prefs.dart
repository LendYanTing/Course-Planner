import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/auth/pref_store.dart';
import 'app_services.dart';

/// Local-only UI preferences (never synced, never sent to the server).
///
/// Overridable in tests so widgets can be pumped without the full service
/// graph (the real store writes to platform secure storage).
final prefStoreProvider = Provider<PrefStore>(
  (ref) => ref.watch(servicesProvider).prefStore,
);

/// Which 日程 view mode is active: `timeline` (时间轴), `grid` (课表) or
/// `month` (月视图). Persisted so the toggle survives a restart.
class WeekViewModeController extends Notifier<String> {
  static const timeline = 'timeline';
  static const grid = 'grid';
  static const month = 'month';

  static const _key = 'week_view_mode';

  @override
  String build() {
    _restore();
    // Existing installs and tests expect the timeline first; the 日程 page's
    // segmented switcher covers the other two modes.
    return timeline;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v == timeline || v == grid || v == month) state = v!;
    } on Object {
      // Best effort: keep the default mode.
    }
  }

  Future<void> set(String mode) async {
    state = mode;
    try {
      await ref.read(prefStoreProvider).write(_key, mode);
    } on Object {
      // Best effort.
    }
  }
}

final weekViewModeProvider =
    NotifierProvider<WeekViewModeController, String>(WeekViewModeController.new);

/// Minute-of-day that splits 上午/下午 in the 课表 view.
///
/// The server has no such setting (semester period templates carry times but no
/// notion of noon), so this is a local preference. Default 12:00; users in
/// western China often treat ~14:00 as the start of the afternoon while a
/// 12:00 class still counts as morning.
class NoonBoundaryController extends Notifier<int> {
  static const defaultMinutes = 12 * 60;

  static const _key = 'noon_boundary_minutes';

  @override
  int build() {
    _restore();
    return defaultMinutes;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      final n = v == null ? null : int.tryParse(v);
      if (n != null && n >= 0 && n <= 24 * 60) state = n;
    } on Object {
      // Best effort: keep the default boundary.
    }
  }

  Future<void> set(int minutes) async {
    state = minutes.clamp(0, 24 * 60);
    try {
      await ref.read(prefStoreProvider).write(_key, '$state');
    } on Object {
      // Best effort.
    }
  }
}

final noonBoundaryProvider =
    NotifierProvider<NoonBoundaryController, int>(NoonBoundaryController.new);

/// `HH:mm` label for a minute-of-day.
String formatMinuteOfDay(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// Row height (dp) of the month grid. On a tall portrait phone the default
/// leaves a lot of dead space under the calendar, so the user can grow the
/// cells to fill the screen.
class MonthCellHeightController extends Notifier<double> {
  static const defaultDp = 66.0;
  static const minDp = 56.0;
  static const maxDp = 160.0;

  static const _key = 'month_cell_height';

  @override
  double build() {
    _restore();
    return defaultDp;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      final n = v == null ? null : double.tryParse(v);
      if (n != null && n >= minDp && n <= maxDp) state = n;
    } on Object {
      // Best effort: keep the default height.
    }
  }

  Future<void> set(double dp) async {
    state = dp.clamp(minDp, maxDp);
    try {
      await ref.read(prefStoreProvider).write(_key, '$state');
    } on Object {
      // Best effort.
    }
  }
}

final monthCellHeightProvider =
    NotifierProvider<MonthCellHeightController, double>(MonthCellHeightController.new);

/// How many completed todos the history page renders (0 = all). Persisted.
class CompletedHistoryLimitController extends Notifier<int> {
  static const _key = 'completed_history_limit';
  static const defaultLimit = 100;
  static const choices = [50, 100, 200, 500, 0];

  @override
  int build() {
    _restore();
    return defaultLimit;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      final n = v == null ? null : int.tryParse(v);
      // Only values the chips offer are valid; anything else stays at 100.
      if (n != null && choices.contains(n)) state = n;
    } on Object {
      // Best effort: keep the default limit.
    }
  }

  Future<void> set(int value) async {
    state = choices.contains(value) ? value : defaultLimit;
    try {
      await ref.read(prefStoreProvider).write(_key, '$state');
    } on Object {
      // Best effort.
    }
  }
}

final completedHistoryLimitProvider =
    NotifierProvider<CompletedHistoryLimitController, int>(
  CompletedHistoryLimitController.new,
);

/// Semester shown by the 课表 (Grid) view. Chosen in 设置 → 学期管理, so the
/// grid itself carries no picker.
class ActiveSemesterController extends Notifier<String?> {
  static const _key = 'active_semester_id';

  @override
  String? build() {
    _restore();
    return null;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null && v.isNotEmpty) state = v;
    } on Object {
      // Best effort: the grid falls back to the first usable semester.
    }
  }

  Future<void> set(String? id) async {
    state = (id == null || id.isEmpty) ? null : id;
    try {
      await ref.read(prefStoreProvider).write(_key, state ?? '');
    } on Object {
      // Best effort.
    }
  }
}

final activeSemesterProvider =
    NotifierProvider<ActiveSemesterController, String?>(ActiveSemesterController.new);

/// Whether course / recurring tiles can be moved in the 课表 view. The switch
/// moved into the week-navigation row, so its state is persisted here instead
/// of living in the page.
class CourseEditableController extends Notifier<bool> {
  static const _key = 'course_editable';

  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null) state = v == 'true';
    } on Object {
      // Best effort: courses stay locked by default.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref.read(prefStoreProvider).write(_key, '$value');
    } on Object {
      // Best effort.
    }
  }
}

final courseEditableInCourseViewProvider =
    NotifierProvider<CourseEditableController, bool>(CourseEditableController.new);

/// How many lines a course/schedule tile gives to its title and to its
/// location. Long room names ("逸夫楼201-阶梯教室") do not fit on one line, so
/// both are adjustable.
class TileTextLinesController
    extends Notifier<({int title, int location})> {
  static const defaultTitle = 2;
  static const defaultLocation = 1;
  static const minLines = 1;
  static const maxLines = 4;

  static const _titleKey = 'tile_title_lines';
  static const _locationKey = 'tile_location_lines';

  static ({int title, int location}) get defaults =>
      (title: defaultTitle, location: defaultLocation);

  @override
  ({int title, int location}) build() {
    _restore();
    return defaults;
  }

  Future<void> _restore() async {
    try {
      final prefs = ref.read(prefStoreProvider);
      final t = int.tryParse(await prefs.read(_titleKey) ?? '');
      final l = int.tryParse(await prefs.read(_locationKey) ?? '');
      state = (
        title: _clamp(t ?? defaultTitle),
        location: _clamp(l ?? defaultLocation),
      );
    } on Object {
      // Best effort: keep the defaults.
    }
  }

  Future<void> setTitle(int lines) async {
    state = (title: _clamp(lines), location: state.location);
    await _write(_titleKey, state.title);
  }

  Future<void> setLocation(int lines) async {
    state = (title: state.title, location: _clamp(lines));
    await _write(_locationKey, state.location);
  }

  static int _clamp(int v) => v.clamp(minLines, maxLines);

  Future<void> _write(String key, int value) async {
    try {
      await ref.read(prefStoreProvider).write(key, '$value');
    } on Object {
      // Best effort.
    }
  }
}

final tileTextLinesProvider =
    NotifierProvider<TileTextLinesController, ({int title, int location})>(
  TileTextLinesController.new,
);

/// Material style of the floating bottom navigation bar.
enum BottomBarStyle {
  /// Liquid glass: real-time refraction via `ImageFilter.shader`. Impeller only
  /// (`ImageFilter.isShaderFilterSupported`); the bar falls back to
  /// [frostedBlur] on platforms that cannot render shader filters.
  liquidGlass,

  /// Standard frosted glass: `ImageFilter.blur` plus a highlight border.
  /// Available on every platform.
  frostedBlur,

  /// Flat floating capsule: no offscreen blur, so it is the cheapest to draw.
  solidCapsule,
}

/// Which material the floating bottom bar uses. Local-only; the bar itself
/// degrades unsupported styles instead of failing.
class BottomBarStyleController extends Notifier<BottomBarStyle> {
  static const _key = 'bottom_bar_style';

  @override
  BottomBarStyle build() {
    _restore();
    return BottomBarStyle.liquidGlass;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null) {
        state = BottomBarStyle.values.firstWhere(
          (s) => s.name == v,
          orElse: () => BottomBarStyle.liquidGlass,
        );
      }
    } on Object {
      // Best effort: keep the default style.
    }
  }

  Future<void> set(BottomBarStyle style) async {
    state = style;
    try {
      await ref.read(prefStoreProvider).write(_key, style.name);
    } on Object {
      // Best effort.
    }
  }
}

final bottomBarStyleProvider =
    NotifierProvider<BottomBarStyleController, BottomBarStyle>(
  BottomBarStyleController.new,
);

/// Visual engine of the whole app.
enum UiVariant { material3, hyperOS }

/// Which visual engine the app renders with. Local-only: the server has no
/// notion of styling. Defaults to [UiVariant.material3] so an existing install
/// keeps its current look until the user switches.
class UiVariantController extends Notifier<UiVariant> {
  static const _key = 'ui_variant';

  @override
  UiVariant build() {
    _restore();
    return UiVariant.material3;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null) {
        state = UiVariant.values.firstWhere(
          (e) => e.name == v,
          orElse: () => UiVariant.material3,
        );
      }
    } on Object {
      // Best effort: keep the default engine.
    }
  }

  Future<void> set(UiVariant variant) async {
    state = variant;
    try {
      await ref.read(prefStoreProvider).write(_key, variant.name);
    } on Object {
      // Best effort.
    }
  }
}

final uiVariantProvider =
    NotifierProvider<UiVariantController, UiVariant>(UiVariantController.new);

/// Whether the app talks to a server at all. Cloud sync is opt-in: a fresh
/// install (and every no-account local session) stays fully local until the
/// user signs in to a server.
class SyncEnabledController extends Notifier<bool> {
  static const _key = 'sync_enabled';

  @override
  bool build() {
    _restore();
    return false;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null) state = v == 'true';
    } on Object {
      // Best effort: stay local-only.
    }
  }

  Future<void> set(bool enabled) async {
    state = enabled;
    try {
      await ref.read(prefStoreProvider).write(_key, '$enabled');
    } on Object {
      // Best effort.
    }
  }
}

final syncEnabledProvider =
    NotifierProvider<SyncEnabledController, bool>(SyncEnabledController.new);

/// Whether the AI assistant keeps its tab in the bottom bar. Local-only: the
/// agent stays reachable from 设置 → 内置 AI 助手 when the tab is hidden, and the
/// route itself is never removed (only its nav entry).
class AgentTabEnabledController extends Notifier<bool> {
  static const _key = 'agent_tab_enabled';

  @override
  bool build() {
    _restore();
    return true;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null) state = v == 'true';
    } on Object {
      // Best effort: keep the tab visible.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref.read(prefStoreProvider).write(_key, '$value');
    } on Object {
      // Best effort.
    }
  }
}

final agentTabEnabledProvider =
    NotifierProvider<AgentTabEnabledController, bool>(
  AgentTabEnabledController.new,
);

/// IANA timezone used while no account is signed in (the server normally owns
/// this value, but a local session has no server to ask).
class LocalTimezoneController extends Notifier<String> {
  static const defaultTimezone = 'Asia/Shanghai';

  static const _key = 'local_timezone';

  @override
  String build() {
    _restore();
    return defaultTimezone;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v != null && v.isNotEmpty) state = v;
    } on Object {
      // Best effort: keep the default timezone.
    }
  }

  Future<void> set(String timezone) async {
    state = timezone;
    try {
      await ref.read(prefStoreProvider).write(_key, timezone);
    } on Object {
      // Best effort.
    }
  }
}

final localTimezoneProvider =
    NotifierProvider<LocalTimezoneController, String>(LocalTimezoneController.new);

/// Normalises a user-typed colour (`#RRGGBB` or `RRGGBB`) to upper-case
/// `#RRGGBB`. Returns null when the input is not a six-digit hex colour, so
/// callers can keep the previous value instead of persisting garbage.
String? normalizeHexColor(String? raw) {
  if (raw == null) return null;
  final h = raw.trim().replaceFirst('#', '');
  if (h.length != 6) return null;
  if (int.tryParse(h, radix: 16) == null) return null;
  return '#${h.toUpperCase()}';
}

/// Theme mode, seed colour and the Monet (wallpaper-derived scheme) toggle.
///
/// One JSON blob under [ThemeConfigController._key] instead of three scattered
/// keys; the appearance page edits the whole record through `copyWith`.
class ThemeConfig {
  const ThemeConfig({
    this.mode = ThemeMode.system,
    this.useWallpaperMonet = true,
    this.seedColorHex = defaultSeedHex,
  });

  /// Indigo 500, matching `AppTheme.seed` so an untouched install keeps its
  /// current look.
  static const defaultSeedHex = '#3F51B5';

  final ThemeMode mode;

  /// When on and a background image is set, the scheme is extracted from the
  /// wallpaper; otherwise [seedColorHex] drives the scheme.
  final bool useWallpaperMonet;

  /// `#RRGGBB` seed for `ColorScheme.fromSeed`.
  final String seedColorHex;

  ThemeConfig copyWith({
    ThemeMode? mode,
    bool? useWallpaperMonet,
    String? seedColorHex,
  }) {
    return ThemeConfig(
      mode: mode ?? this.mode,
      useWallpaperMonet: useWallpaperMonet ?? this.useWallpaperMonet,
      seedColorHex: seedColorHex ?? this.seedColorHex,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'useWallpaperMonet': useWallpaperMonet,
        'seedColorHex': seedColorHex,
      };

  static ThemeConfig fromJson(Map<String, dynamic> m) {
    const fallback = ThemeConfig();
    final mode = m['mode'];
    final monet = m['useWallpaperMonet'];
    return ThemeConfig(
      mode: mode is String
          ? ThemeMode.values.firstWhere(
              (e) => e.name == mode,
              orElse: () => fallback.mode,
            )
          : fallback.mode,
      useWallpaperMonet:
          monet is bool ? monet : fallback.useWallpaperMonet,
      seedColorHex: normalizeHexColor(
            m['seedColorHex'] is String ? m['seedColorHex'] as String : null,
          ) ??
          fallback.seedColorHex,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeConfig &&
          other.mode == mode &&
          other.useWallpaperMonet == useWallpaperMonet &&
          other.seedColorHex == seedColorHex;

  @override
  int get hashCode => Object.hash(mode, useWallpaperMonet, seedColorHex);
}

/// Persists [ThemeConfig]. Local-only, like the other preference controllers.
class ThemeConfigController extends Notifier<ThemeConfig> {
  static const _key = 'theme_config';

  @override
  ThemeConfig build() {
    _restore();
    return const ThemeConfig();
  }

  Future<void> _restore() async {
    try {
      final raw = await ref.read(prefStoreProvider).read(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = ThemeConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } on Object {
      // Best effort: keep the defaults.
    }
  }

  Future<void> _persist() async {
    try {
      await ref
          .read(prefStoreProvider)
          .write(_key, jsonEncode(state.toJson()));
    } on Object {
      // Best effort.
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    await _persist();
  }

  Future<void> setUseWallpaperMonet(bool enabled) async {
    state = state.copyWith(useWallpaperMonet: enabled);
    await _persist();
  }

  /// Ignores malformed input (keeping the current seed) instead of persisting
  /// a colour the theme cannot parse.
  Future<void> setSeedHex(String hex) async {
    final normalized = normalizeHexColor(hex);
    if (normalized == null) return;
    state = state.copyWith(seedColorHex: normalized);
    await _persist();
  }
}

final themeConfigProvider =
    NotifierProvider<ThemeConfigController, ThemeConfig>(
  ThemeConfigController.new,
);

/// Custom calendar background: either a local image file or one of the built-in
/// gradient presets, plus blur and scrim strength.
class BackgroundConfig {
  const BackgroundConfig({
    this.imagePath,
    this.presetId,
    this.blurSigma = 0.0,
    this.scrimOpacity = 0.25,
  });

  static const minBlurSigma = 0.0;
  static const maxBlurSigma = 25.0;
  static const minScrimOpacity = 0.0;
  static const maxScrimOpacity = 0.85;

  /// Absolute path of a local image file; null when no custom image is set.
  /// Mutually exclusive with [presetId].
  final String? imagePath;

  /// Id of a built-in gradient wallpaper; null when none is selected.
  /// Mutually exclusive with [imagePath].
  final String? presetId;

  /// Gaussian blur sigma, 0 (sharp) .. 25 (heavily blurred).
  final double blurSigma;

  /// Opacity of the readability scrim above the wallpaper, 0 .. 0.85.
  final double scrimOpacity;

  /// Whether any background is configured. Does not touch the file system:
  /// the render layer decides whether [imagePath] actually exists.
  bool get hasBackground =>
      (imagePath?.isNotEmpty ?? false) || (presetId?.isNotEmpty ?? false);

  BackgroundConfig copyWith({
    String? imagePath,
    String? presetId,
    double? blurSigma,
    double? scrimOpacity,
  }) {
    return BackgroundConfig(
      imagePath: imagePath ?? this.imagePath,
      presetId: presetId ?? this.presetId,
      blurSigma: blurSigma ?? this.blurSigma,
      scrimOpacity: scrimOpacity ?? this.scrimOpacity,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'imagePath': imagePath,
        'presetId': presetId,
        'blurSigma': blurSigma,
        'scrimOpacity': scrimOpacity,
      };

  static BackgroundConfig fromJson(Map<String, dynamic> m) {
    const fallback = BackgroundConfig();
    final image = m['imagePath'];
    final preset = m['presetId'];
    final blur = m['blurSigma'];
    final scrim = m['scrimOpacity'];
    return BackgroundConfig(
      imagePath: image is String && image.isNotEmpty ? image : null,
      presetId: preset is String && preset.isNotEmpty ? preset : null,
      blurSigma: blur is num
          ? blur.toDouble().clamp(minBlurSigma, maxBlurSigma).toDouble()
          : fallback.blurSigma,
      scrimOpacity: scrim is num
          ? scrim
              .toDouble()
              .clamp(minScrimOpacity, maxScrimOpacity)
              .toDouble()
          : fallback.scrimOpacity,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackgroundConfig &&
          other.imagePath == imagePath &&
          other.presetId == presetId &&
          other.blurSigma == blurSigma &&
          other.scrimOpacity == scrimOpacity;

  @override
  int get hashCode =>
      Object.hash(imagePath, presetId, blurSigma, scrimOpacity);
}

/// Persists [BackgroundConfig]. Local-only: an absolute path means nothing on
/// another device, and the server has no notion of wallpapers.
class BackgroundConfigController extends Notifier<BackgroundConfig> {
  static const _key = 'background_config';

  @override
  BackgroundConfig build() {
    _restore();
    return const BackgroundConfig();
  }

  Future<void> _restore() async {
    try {
      final raw = await ref.read(prefStoreProvider).read(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = BackgroundConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } on Object {
      // Best effort: keep "no background".
    }
  }

  Future<void> _persist() async {
    try {
      await ref
          .read(prefStoreProvider)
          .write(_key, jsonEncode(state.toJson()));
    } on Object {
      // Best effort.
    }
  }

  /// Picks a local image; clears [BackgroundConfig.presetId] because the two
  /// sources are mutually exclusive. An empty path clears the image.
  Future<void> setImagePath(String? path) async {
    final trimmed = path?.trim();
    state = BackgroundConfig(
      imagePath: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      presetId: null,
      blurSigma: state.blurSigma,
      scrimOpacity: state.scrimOpacity,
    );
    await _persist();
  }

  /// Picks a built-in gradient; clears [BackgroundConfig.imagePath] for the
  /// same reason. An empty id clears the preset.
  Future<void> setPresetId(String? id) async {
    final trimmed = id?.trim();
    state = BackgroundConfig(
      imagePath: null,
      presetId: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      blurSigma: state.blurSigma,
      scrimOpacity: state.scrimOpacity,
    );
    await _persist();
  }

  /// Drops both the image and the preset, keeping blur/scrim for the next pick.
  Future<void> clear() async {
    state = BackgroundConfig(
      blurSigma: state.blurSigma,
      scrimOpacity: state.scrimOpacity,
    );
    await _persist();
  }

  Future<void> setBlurSigma(double sigma) async {
    state = state.copyWith(
      blurSigma: sigma
          .clamp(BackgroundConfig.minBlurSigma, BackgroundConfig.maxBlurSigma)
          .toDouble(),
    );
    await _persist();
  }

  Future<void> setScrimOpacity(double opacity) async {
    state = state.copyWith(
      scrimOpacity: opacity
          .clamp(
            BackgroundConfig.minScrimOpacity,
            BackgroundConfig.maxScrimOpacity,
          )
          .toDouble(),
    );
    await _persist();
  }
}

final backgroundConfigProvider =
    NotifierProvider<BackgroundConfigController, BackgroundConfig>(
  BackgroundConfigController.new,
);

/// Visual knobs of a course tile in the 课表/周视图, all live-adjustable from the
/// appearance page. The defaults reproduce the hard-coded values they replace.
class CourseCardStyle {
  const CourseCardStyle({
    this.opacity = 0.92,
    this.borderRadius = 8.0,
    this.margin = 1.5,
    this.fontScale = 1.0,
    this.rowHeight = 54.0,
  });

  static const minOpacity = 0.30;
  static const maxOpacity = 1.0;
  static const minBorderRadius = 4.0;
  static const maxBorderRadius = 16.0;
  static const minMargin = 0.5;
  static const maxMargin = 4.0;
  static const minFontScale = 0.85;
  static const maxFontScale = 1.30;
  static const minRowHeight = 44.0;
  static const maxRowHeight = 90.0;

  /// Tile background alpha, 0.30 .. 1.00.
  final double opacity;

  /// Tile corner radius (dp), 4 .. 16.
  final double borderRadius;

  /// Gap around a tile (dp), 0.5 .. 4.
  final double margin;

  /// Title/location text multiplier, 0.85 .. 1.30.
  final double fontScale;

  /// Height of one period row (dp), 44 .. 90.
  final double rowHeight;

  CourseCardStyle copyWith({
    double? opacity,
    double? borderRadius,
    double? margin,
    double? fontScale,
    double? rowHeight,
  }) {
    return CourseCardStyle(
      opacity: opacity ?? this.opacity,
      borderRadius: borderRadius ?? this.borderRadius,
      margin: margin ?? this.margin,
      fontScale: fontScale ?? this.fontScale,
      rowHeight: rowHeight ?? this.rowHeight,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'opacity': opacity,
        'borderRadius': borderRadius,
        'margin': margin,
        'fontScale': fontScale,
        'rowHeight': rowHeight,
      };

  static CourseCardStyle fromJson(Map<String, dynamic> m) {
    const fallback = CourseCardStyle();
    double read(String key, double fallbackValue, double min, double max) {
      final v = m[key];
      if (v is! num) return fallbackValue;
      return v.toDouble().clamp(min, max).toDouble();
    }

    return CourseCardStyle(
      opacity: read('opacity', fallback.opacity, minOpacity, maxOpacity),
      borderRadius: read(
        'borderRadius',
        fallback.borderRadius,
        minBorderRadius,
        maxBorderRadius,
      ),
      margin: read('margin', fallback.margin, minMargin, maxMargin),
      fontScale:
          read('fontScale', fallback.fontScale, minFontScale, maxFontScale),
      rowHeight:
          read('rowHeight', fallback.rowHeight, minRowHeight, maxRowHeight),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CourseCardStyle &&
          other.opacity == opacity &&
          other.borderRadius == borderRadius &&
          other.margin == margin &&
          other.fontScale == fontScale &&
          other.rowHeight == rowHeight;

  @override
  int get hashCode =>
      Object.hash(opacity, borderRadius, margin, fontScale, rowHeight);
}

/// Persists [CourseCardStyle]. Every setter clamps to its documented range so
/// a slider overshoot can never produce an unreadable tile.
class CourseCardStyleController extends Notifier<CourseCardStyle> {
  static const _key = 'course_card_style';

  @override
  CourseCardStyle build() {
    _restore();
    return const CourseCardStyle();
  }

  Future<void> _restore() async {
    try {
      final raw = await ref.read(prefStoreProvider).read(_key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = CourseCardStyle.fromJson(Map<String, dynamic>.from(decoded));
      }
    } on Object {
      // Best effort: keep the defaults.
    }
  }

  Future<void> _persist() async {
    try {
      await ref
          .read(prefStoreProvider)
          .write(_key, jsonEncode(state.toJson()));
    } on Object {
      // Best effort.
    }
  }

  Future<void> setOpacity(double value) async {
    state = state.copyWith(
      opacity: value
          .clamp(CourseCardStyle.minOpacity, CourseCardStyle.maxOpacity)
          .toDouble(),
    );
    await _persist();
  }

  Future<void> setBorderRadius(double value) async {
    state = state.copyWith(
      borderRadius: value
          .clamp(
            CourseCardStyle.minBorderRadius,
            CourseCardStyle.maxBorderRadius,
          )
          .toDouble(),
    );
    await _persist();
  }

  Future<void> setMargin(double value) async {
    state = state.copyWith(
      margin: value
          .clamp(CourseCardStyle.minMargin, CourseCardStyle.maxMargin)
          .toDouble(),
    );
    await _persist();
  }

  Future<void> setFontScale(double value) async {
    state = state.copyWith(
      fontScale: value
          .clamp(CourseCardStyle.minFontScale, CourseCardStyle.maxFontScale)
          .toDouble(),
    );
    await _persist();
  }

  Future<void> setRowHeight(double value) async {
    state = state.copyWith(
      rowHeight: value
          .clamp(CourseCardStyle.minRowHeight, CourseCardStyle.maxRowHeight)
          .toDouble(),
    );
    await _persist();
  }

  /// Restores every knob to its default (the appearance page's 恢复默认).
  Future<void> reset() async {
    state = const CourseCardStyle();
    await _persist();
  }
}

final courseCardStyleProvider =
    NotifierProvider<CourseCardStyleController, CourseCardStyle>(
  CourseCardStyleController.new,
);
