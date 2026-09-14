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

/// Which 周视图 mode is active: `timeline` (时间轴) or `grid` (课表).
/// Persisted so the toggle survives a restart.
class WeekViewModeController extends Notifier<String> {
  static const timeline = 'timeline';
  static const grid = 'grid';

  static const _key = 'week_view_mode';

  @override
  String build() {
    _restore();
    return timeline;
  }

  Future<void> _restore() async {
    try {
      final v = await ref.read(prefStoreProvider).read(_key);
      if (v == timeline || v == grid) state = v!;
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
