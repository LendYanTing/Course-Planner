import '../core/error/api_exception.dart';
import '../core/time/user_time.dart';
import '../data/local/entities_snapshot.dart';
import '../data/local/view_models.dart';
import '../data/repo/entity_repo.dart';
import 'calendar.dart';
import 'course.dart';
import 'entities.dart';
import 'override.dart';
import 'schedule.dart';
import 'week_rule.dart';

/// Local-first series editing for course meetings and recurring schedules
/// (docs/plan phase-1-local-first Step 2).
///
/// The server used to own occurrence semantics (`POST /series/.../apply`);
/// this service reproduces the pieces the client needs directly on the local
/// mirror through [EntityRepo]:
///
/// * THIS scope → one `occurrence_override` row (`move` / `cancel`);
/// * THIS_AND_FUTURE → truncate the original series' week rule and create a
///   tail series carrying the edits;
/// * ALL → patch (or delete) the series entity itself.
///
/// Nothing here talks to the network: every write is a queued local operation
/// (`repo.localCreate/localUpdate/localDelete`), so the UI renders immediately
/// and the sync engine pushes in the background when cloud sync is on.
class LocalSeriesService {
  LocalSeriesService({required this.repo, required this.userTime});

  final EntityRepo repo;
  final UserTime userTime;

  /// Moves one occurrence of [seriesId] to [newStartUtc]..[newEndUtc].
  ///
  /// [originalStartUtc] is the start the UI currently displays for that
  /// occurrence. For an occurrence that was already moved it is the previous
  /// override's `replacementStartAt`, which is how an existing override is
  /// found again instead of creating a second one for the same occurrence.
  Future<void> moveOccurrence({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required DateTime originalStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    _requireSeriesType(seriesType);
    _ensureSameLocalDay(newStartUtc, newEndUtc);
    final slot = _locateOccurrence(
      snapshot,
      seriesType: seriesType,
      seriesId: seriesId,
      originalStartUtc: originalStartUtc,
    );
    await _writeThisOverride(
      slot: slot,
      seriesType: seriesType,
      seriesId: seriesId,
      action: OverrideAction.move,
      replacementStartAt: newStartUtc,
      replacementEndAt: newEndUtc,
    );
  }

  /// Cancels one occurrence of [seriesId] (the one displayed at
  /// [originalStartUtc]).
  Future<void> cancelOccurrence({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required DateTime originalStartUtc,
  }) async {
    _requireSeriesType(seriesType);
    final slot = _locateOccurrence(
      snapshot,
      seriesType: seriesType,
      seriesId: seriesId,
      originalStartUtc: originalStartUtc,
    );
    await _writeThisOverride(
      slot: slot,
      seriesType: seriesType,
      seriesId: seriesId,
      action: OverrideAction.cancel,
    );
  }

  /// Applies an edit at one of the three series scopes.
  ///
  /// [scope] is [SeriesScopes.thisOne], [SeriesScopes.thisAndFuture] or
  /// [SeriesScopes.all]; [operationType] is one of [SeriesOperations.move],
  /// [SeriesOperations.update], [SeriesOperations.cancel],
  /// [SeriesOperations.delete].
  ///
  /// * THIS writes the single-occurrence override addressed by
  ///   [occurrenceDateLocal] (the original rule date, matching how the
  ///   expander keys overrides).
  /// * THIS_AND_FUTURE splits at the week of [occurrenceDateLocal]; the tail
  ///   series carries [newWeekday] / [newPeriodStart] / [newPeriodEnd] /
  ///   [newWeekRule] / [newStartLocal] / [newEndLocal].
  /// * ALL patches the series entity.
  ///
  /// A cancel/delete at THIS_AND_FUTURE or ALL truncates or deletes the series
  /// itself, as the server did.
  Future<void> applySeriesEdit({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required String scope,
    required String occurrenceDateLocal,
    required String operationType,
    DateTime? replacementStartUtc,
    DateTime? replacementEndUtc,
    int? newWeekday,
    int? newPeriodStart,
    int? newPeriodEnd,
    WeekRule? newWeekRule,
    String? newStartLocal,
    String? newEndLocal,
    Map<String, dynamic> metadataPatch = const {},
  }) async {
    _requireSeriesType(seriesType);
    if (scope != SeriesScopes.thisOne &&
        scope != SeriesScopes.thisAndFuture &&
        scope != SeriesScopes.all) {
      throw const ApiException(
        code: ApiErrorCodes.invalidRequest,
        message: '未知的系列编辑范围',
      );
    }
    if (operationType != SeriesOperations.move &&
        operationType != SeriesOperations.update &&
        operationType != SeriesOperations.cancel &&
        operationType != SeriesOperations.delete) {
      throw const ApiException(
        code: ApiErrorCodes.invalidRequest,
        message: '未知的系列编辑操作',
      );
    }

    if (scope == SeriesScopes.thisOne) {
      await _applyThis(
        snapshot: snapshot,
        seriesType: seriesType,
        seriesId: seriesId,
        occurrenceDateLocal: occurrenceDateLocal,
        operationType: operationType,
        replacementStartUtc: replacementStartUtc,
        replacementEndUtc: replacementEndUtc,
        metadataPatch: metadataPatch,
      );
      return;
    }
    if (scope == SeriesScopes.thisAndFuture) {
      await _splitSeries(
        snapshot: snapshot,
        seriesType: seriesType,
        seriesId: seriesId,
        occurrenceDateLocal: occurrenceDateLocal,
        operationType: operationType,
        newWeekday: newWeekday,
        newPeriodStart: newPeriodStart,
        newPeriodEnd: newPeriodEnd,
        newWeekRule: newWeekRule,
        newStartLocal: newStartLocal,
        newEndLocal: newEndLocal,
        metadataPatch: metadataPatch,
      );
      return;
    }
    await _updateSeries(
      snapshot: snapshot,
      seriesType: seriesType,
      seriesId: seriesId,
      operationType: operationType,
      newWeekday: newWeekday,
      newPeriodStart: newPeriodStart,
      newPeriodEnd: newPeriodEnd,
      newWeekRule: newWeekRule,
      newStartLocal: newStartLocal,
      newEndLocal: newEndLocal,
      metadataPatch: metadataPatch,
    );
  }

  // ---- single occurrence (THIS) --------------------------------------------

  Future<void> _applyThis({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required String occurrenceDateLocal,
    required String operationType,
    DateTime? replacementStartUtc,
    DateTime? replacementEndUtc,
    required Map<String, dynamic> metadataPatch,
  }) async {
    final existing = _overrideForDate(
      snapshot,
      seriesType: seriesType,
      seriesId: seriesId,
      occurrenceDateLocal: occurrenceDateLocal,
    );
    final slot = (date: occurrenceDateLocal, override: existing);

    if (operationType == SeriesOperations.cancel ||
        operationType == SeriesOperations.delete) {
      // Addressing by date is enough: THIS scope never needs the displayed
      // start, the override is keyed by the occurrence's rule date.
      await _writeThisOverride(
        slot: slot,
        seriesType: seriesType,
        seriesId: seriesId,
        action: OverrideAction.cancel,
      );
      return;
    }
    if (operationType == SeriesOperations.update) {
      final metadata = _metadataChanges(metadataPatch);
      if (metadata.isEmpty) {
        throw const ApiException(
          code: ApiErrorCodes.invalidRequest,
          message: '修改单次日程需要提供变更内容',
        );
      }
      await _writeThisOverride(
        slot: slot,
        seriesType: seriesType,
        seriesId: seriesId,
        action: OverrideAction.update,
        metadata: metadata,
      );
      return;
    }
    if (replacementStartUtc == null || replacementEndUtc == null) {
      throw const ApiException(
        code: ApiErrorCodes.invalidRequest,
        message: '移动单次日程需要新的开始与结束时间',
      );
    }
    _ensureSameLocalDay(replacementStartUtc, replacementEndUtc);
    await _writeThisOverride(
      slot: slot,
      seriesType: seriesType,
      seriesId: seriesId,
      action: OverrideAction.move,
      replacementStartAt: replacementStartUtc,
      replacementEndAt: replacementEndUtc,
    );
  }

  /// Finds the override representing the occurrence displayed at
  /// [originalStartUtc].
  ///
  /// An already-moved occurrence is matched by its `replacementStartAt` (the
  /// displayed start); its original `occurrenceDateLocal` is reused so the
  /// expander still finds it. Otherwise the occurrence date is the local date
  /// of [originalStartUtc], and any override already stored for that date is
  /// updated in place.
  ({String date, OccurrenceOverride? override}) _locateOccurrence(
    EntitiesSnapshot snapshot, {
    required String seriesType,
    required String seriesId,
    required DateTime originalStartUtc,
  }) {
    final overrides = liveOverrides(
      snapshot,
      seriesType: seriesType,
    ).map((e) => e.value).where((o) => o.seriesId == seriesId).toList();

    for (final o in overrides) {
      final movedStart = o.replacementStartAt;
      if (movedStart != null && movedStart.isAtSameMomentAs(originalStartUtc)) {
        return (date: o.occurrenceDateLocal, override: o);
      }
    }

    final date = userTime.localDateString(
      userTime.localFromUtc(originalStartUtc),
    );
    return (
      date: date,
      override: _overrideForDate(
        snapshot,
        seriesType: seriesType,
        seriesId: seriesId,
        occurrenceDateLocal: date,
      ),
    );
  }

  OccurrenceOverride? _overrideForDate(
    EntitiesSnapshot snapshot, {
    required String seriesType,
    required String seriesId,
    required String occurrenceDateLocal,
  }) {
    for (final e in liveOverrides(snapshot, seriesType: seriesType)) {
      final o = e.value;
      if (o.seriesId == seriesId &&
          o.occurrenceDateLocal == occurrenceDateLocal) {
        return o;
      }
    }
    return null;
  }

  /// Creates or updates the one override row for [slot].
  Future<void> _writeThisOverride({
    required ({String date, OccurrenceOverride? override}) slot,
    required String seriesType,
    required String seriesId,
    required OverrideAction action,
    DateTime? replacementStartAt,
    DateTime? replacementEndAt,
    Map<String, dynamic>? metadata,
  }) async {
    final existing = slot.override;
    final changes = <String, dynamic>{
      'action': action.wire,
      'replacementStartAt': replacementStartAt,
      'replacementEndAt': replacementEndAt,
      if (metadata != null)
        'metadata': <String, dynamic>{...?existing?.metadata, ...metadata},
    };
    if (existing != null) {
      await repo.localUpdate(
        entityType: EntityTypes.override,
        entityId: existing.id,
        changes: changes,
      );
      return;
    }
    await repo.localCreate(
      entityType: EntityTypes.override,
      snapshot: {
        'seriesType': seriesType,
        'seriesId': seriesId,
        'occurrenceDateLocal': slot.date,
        'metadata': const <String, dynamic>{},
        ...changes,
      },
    );
  }

  // ---- whole series (ALL) ---------------------------------------------------

  Future<void> _updateSeries({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required String operationType,
    int? newWeekday,
    int? newPeriodStart,
    int? newPeriodEnd,
    WeekRule? newWeekRule,
    String? newStartLocal,
    String? newEndLocal,
    required Map<String, dynamic> metadataPatch,
  }) async {
    final deleting =
        operationType == SeriesOperations.cancel ||
        operationType == SeriesOperations.delete;

    if (seriesType == SeriesTypes.courseMeeting) {
      final meeting = _meeting(snapshot, seriesId);
      if (meeting == null) throw _notFound('课程安排不存在');
      if (deleting) {
        // Deleting the whole series removes the meeting, never the course.
        await repo.localDelete(
          entityType: EntityTypes.courseMeeting,
          entityId: meeting.id,
        );
        return;
      }
      final periodStart = newPeriodStart ?? meeting.periodStart;
      final periodEnd = newPeriodEnd ?? meeting.periodEnd;
      _ensurePeriodOrder(periodStart, periodEnd);
      final changes = <String, dynamic>{
        'weekday': ?newWeekday,
        'periodStart': ?newPeriodStart,
        'periodEnd': ?newPeriodEnd,
        if (newWeekRule != null) 'weekRule': newWeekRule.toJson(),
      };
      if (changes.isEmpty) return;
      await repo.localUpdate(
        entityType: EntityTypes.courseMeeting,
        entityId: meeting.id,
        changes: changes,
      );
      return;
    }

    final schedule = _schedule(snapshot, seriesId);
    if (schedule == null) throw _notFound('周期日程不存在');
    if (deleting) {
      await repo.localDelete(
        entityType: EntityTypes.recurringSchedule,
        entityId: schedule.id,
      );
      return;
    }
    if (newWeekday == null &&
        newPeriodStart == null &&
        newPeriodEnd == null &&
        newWeekRule == null &&
        newStartLocal == null &&
        newEndLocal == null &&
        metadataPatch.isEmpty) {
      return;
    }
    final rule = _patchedRule(
      schedule.rule,
      newWeekday: newWeekday,
      newPeriodStart: newPeriodStart,
      newPeriodEnd: newPeriodEnd,
      newWeekRule: newWeekRule,
      newStartLocal: newStartLocal,
      newEndLocal: newEndLocal,
    );
    if (newPeriodStart != null || newPeriodEnd != null) {
      _ensurePeriodOrder(
        rule.periodStart > 0 ? rule.periodStart : 0,
        rule.periodEnd > 0 ? rule.periodEnd : 0,
      );
    }
    final changes = <String, dynamic>{'rule': rule.toJson()};
    changes.addAll(_metadataChanges(metadataPatch));
    await repo.localUpdate(
      entityType: EntityTypes.recurringSchedule,
      entityId: schedule.id,
      changes: changes,
    );
  }

  // ---- this and future (split) ---------------------------------------------

  Future<void> _splitSeries({
    required EntitiesSnapshot snapshot,
    required String seriesType,
    required String seriesId,
    required String occurrenceDateLocal,
    required String operationType,
    int? newWeekday,
    int? newPeriodStart,
    int? newPeriodEnd,
    WeekRule? newWeekRule,
    String? newStartLocal,
    String? newEndLocal,
    required Map<String, dynamic> metadataPatch,
  }) async {
    final splitting =
        operationType == SeriesOperations.cancel ||
        operationType == SeriesOperations.delete;

    if (seriesType == SeriesTypes.courseMeeting) {
      final meeting = _meeting(snapshot, seriesId);
      if (meeting == null) throw _notFound('课程安排不存在');
      final calendar = _calendarOfMeeting(snapshot, meeting);
      if (calendar == null) throw _cannotLocateWeek();
      final week = _weekOf(calendar, occurrenceDateLocal);
      final base = meeting.weekRule.isEmpty
          ? WeekRule([WeekSegment(start: 1, end: calendar.totalWeeks)])
          : meeting.weekRule;
      if (week < 1 || week > calendar.totalWeeks || !base.matchesWeek(week)) {
        throw _cannotLocateWeek();
      }
      final oldRule = base.restrictBefore(week);
      // An explicit (non-empty) week rule replaces the tail's weeks entirely
      // (server `HasWeekRule` behaviour); an empty one means no tail.
      final WeekRule? tailRule = newWeekRule == null
          ? base.restrictFrom(week)
          : (newWeekRule.isEmpty ? null : newWeekRule);

      await _truncate(
        entityType: EntityTypes.courseMeeting,
        entityId: meeting.id,
        oldRule: oldRule,
      );
      if (splitting || tailRule == null) return;

      final periodStart = newPeriodStart ?? meeting.periodStart;
      final periodEnd = newPeriodEnd ?? meeting.periodEnd;
      _ensurePeriodOrder(periodStart, periodEnd);
      final tail = meeting.toJson()
        ..remove('id')
        ..remove('revision')
        ..['weekRule'] = tailRule.toJson()
        ..['weekday'] = newWeekday ?? meeting.weekday
        ..['periodStart'] = periodStart
        ..['periodEnd'] = periodEnd;
      await repo.localCreate(
        entityType: EntityTypes.courseMeeting,
        snapshot: tail,
      );
      return;
    }

    final schedule = _schedule(snapshot, seriesId);
    if (schedule == null) throw _notFound('周期日程不存在');
    final rule = schedule.rule;
    if (rule.kind != ScheduleRuleKind.byAcademicWeek) {
      // Only semester-based series have a week number to split at.
      throw _cannotLocateWeek();
    }
    final calendarId = rule.calendarId;
    final calendar = _calendar(snapshot, calendarId);
    if (calendar == null) throw _cannotLocateWeek();
    final week = _weekOf(calendar, occurrenceDateLocal);
    final base = (rule.weekRule == null || rule.weekRule!.isEmpty)
        ? WeekRule([WeekSegment(start: 1, end: calendar.totalWeeks)])
        : rule.weekRule!;
    if (week < 1 || week > calendar.totalWeeks || !base.matchesWeek(week)) {
      throw _cannotLocateWeek();
    }
    final oldRule = base.restrictBefore(week);
    // An explicit (non-empty) week rule replaces the tail's weeks entirely; an
    // empty one means "no weeks left", i.e. the tail is not created.
    final WeekRule? tailRule = newWeekRule == null
        ? base.restrictFrom(week)
        : (newWeekRule.isEmpty ? null : newWeekRule);

    await _truncate(
      entityType: EntityTypes.recurringSchedule,
      entityId: schedule.id,
      oldRule: oldRule,
      oldRuleForSchedule: rule,
    );
    if (splitting || tailRule == null) return;

    final tailRuleSpec = _patchedRule(
      rule,
      newWeekday: newWeekday,
      newPeriodStart: newPeriodStart,
      newPeriodEnd: newPeriodEnd,
      newWeekRule: tailRule,
      newStartLocal: newStartLocal,
      newEndLocal: newEndLocal,
    );
    final tail = schedule.toJson()
      ..remove('id')
      ..remove('revision')
      ..['rule'] = tailRuleSpec.toJson();
    tail.addAll(_metadataChanges(metadataPatch));
    await repo.localCreate(
      entityType: EntityTypes.recurringSchedule,
      snapshot: tail,
    );
  }

  /// Applies the truncated head rule, deleting the original series when no
  /// week remains before the split.
  Future<void> _truncate({
    required String entityType,
    required String entityId,
    required WeekRule? oldRule,
    ScheduleRule? oldRuleForSchedule,
  }) async {
    if (oldRule == null) {
      await repo.localDelete(entityType: entityType, entityId: entityId);
      return;
    }
    // A schedule keeps its week rule inside `rule`; a course meeting has the
    // week rule as a top-level field. Writing the other shape would send a
    // stray field on push.
    final changes = oldRuleForSchedule != null
        ? <String, dynamic>{
            'rule': _patchedRule(
              oldRuleForSchedule,
              newWeekRule: oldRule,
            ).toJson(),
          }
        : <String, dynamic>{'weekRule': oldRule.toJson()};
    await repo.localUpdate(
      entityType: entityType,
      entityId: entityId,
      changes: changes,
    );
  }

  // ---- helpers ---------------------------------------------------------------

  void _requireSeriesType(String seriesType) {
    if (seriesType != SeriesTypes.courseMeeting &&
        seriesType != SeriesTypes.recurringSchedule) {
      throw const ApiException(
        code: ApiErrorCodes.invalidRequest,
        message: '未知的系列类型',
      );
    }
  }

  /// Single occurrences must stay inside one local natural day (docs/api.md
  /// CROSS_MIDNIGHT_NOT_ALLOWED); the expander has no way to render splits.
  void _ensureSameLocalDay(DateTime startUtc, DateTime endUtc) {
    if (!endUtc.isAfter(startUtc) || !userTime.sameLocalDay(startUtc, endUtc)) {
      throw const ApiException(
        code: ApiErrorCodes.crossMidnight,
        message: '单个日程不能跨午夜',
      );
    }
  }

  void _ensurePeriodOrder(int periodStart, int periodEnd) {
    if (periodStart > 0 && periodEnd > 0 && periodEnd < periodStart) {
      throw const ApiException(
        code: ApiErrorCodes.invalidRequest,
        message: '结束节次不能早于开始节次',
      );
    }
  }

  ApiException _cannotLocateWeek() => const ApiException(
    code: ApiErrorCodes.invalidRequest,
    message: '无法定位所在周次',
  );

  ApiException _notFound(String message) =>
      ApiException(code: ApiErrorCodes.notFound, message: message);

  /// 1-based week of [localDate] within [calendar] (mirrors
  /// `EventExpander.weekOf`, kept local so the domain layer does not depend on
  /// the projection layer).
  int _weekOf(AcademicCalendar calendar, String localDate) {
    final first = userTime.parseLocalDate(calendar.firstDay);
    final date = userTime.parseLocalDate(localDate);
    if (first == null || date == null) return 0;
    final diff = date.difference(first).inDays;
    if (diff < 0) return 0;
    return diff ~/ 7 + 1;
  }

  CourseMeeting? _meeting(EntitiesSnapshot snapshot, String id) {
    for (final e in liveMeetings(snapshot)) {
      if (e.value.id == id) return e.value;
    }
    return null;
  }

  RecurringSchedule? _schedule(EntitiesSnapshot snapshot, String id) {
    for (final e in liveSchedules(snapshot)) {
      if (e.value.id == id) return e.value;
    }
    return null;
  }

  AcademicCalendar? _calendar(EntitiesSnapshot snapshot, String? id) {
    if (id == null) return null;
    for (final e in liveCalendars(snapshot)) {
      if (e.value.id == id) return e.value;
    }
    return null;
  }

  AcademicCalendar? _calendarOfMeeting(
    EntitiesSnapshot snapshot,
    CourseMeeting meeting,
  ) {
    for (final c in liveCourses(snapshot)) {
      if (c.value.id == meeting.courseId) {
        return _calendar(snapshot, c.value.calendarId);
      }
    }
    return null;
  }

  ScheduleRule _patchedRule(
    ScheduleRule rule, {
    int? newWeekday,
    int? newPeriodStart,
    int? newPeriodEnd,
    WeekRule? newWeekRule,
    String? newStartLocal,
    String? newEndLocal,
  }) {
    return ScheduleRule(
      kind: rule.kind,
      startLocal: newStartLocal ?? rule.startLocal,
      endLocal: newEndLocal ?? rule.endLocal,
      weekdays: newWeekday != null ? [newWeekday] : rule.weekdays,
      dateStart: rule.dateStart,
      dateEnd: rule.dateEnd,
      calendarId: rule.calendarId,
      weekRule: newWeekRule ?? rule.weekRule,
      periodStart: newPeriodStart ?? rule.periodStart,
      periodEnd: newPeriodEnd ?? rule.periodEnd,
    );
  }

  /// The series-level metadata fields an override/update may patch (same
  /// whitelist as the server `patchMetadata`).
  Map<String, dynamic> _metadataChanges(Map<String, dynamic> patch) {
    final out = <String, dynamic>{};
    for (final key in const ['title', 'color', 'notes']) {
      final value = patch[key];
      if (value is String) out[key] = value;
    }
    return out;
  }
}
