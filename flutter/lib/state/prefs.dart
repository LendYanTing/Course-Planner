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
