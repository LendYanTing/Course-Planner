@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/api/auth_api.dart';
import 'package:course_planner/data/api/http_client.dart';
import 'package:course_planner/data/api/sync_api.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/sync.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/month_page.dart';
import 'package:course_planner/sync/expander.dart';
import 'package:course_planner/sync/sync_engine.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/host_sqlite.dart';

/// End-to-end pipeline test for the Flutter client against the real backend
/// (http://127.0.0.1:8080, account webdev/password123 with seeded data).
///
/// Two modes:
///  * live — login → full journal pull → offline mirror → projections, when
///    the backend is reachable from the Dart VM;
///  * recorded — replays `test/fixtures/live_backend/sync_changes.json`
///    (captured from that backend) through the same mirror/projection
///    pipeline, so parsing and offline semantics stay regression-checked even
///    in sandboxes where the test VM has no network.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  var backendUp = false;
  setUpAll(() async {
    try {
      final http = ApiHttp.create(onRefresh: () async => false);
      await AuthApi(http).serverTime();
      backendUp = true;
    } on Object catch (e) {
      // The harness network layer answers every Dart VM request with HTTP 400,
      // so expect this when sandboxed; the recorded fixture still runs.
      // ignore: avoid_print
      print('live backend unreachable from test VM: $e');
      backendUp = false;
    }
  });

  test('live backend: login → full pull → decode → projections', () async {
    final http = ApiHttp.create(onRefresh: () async => false);
    final auth = AuthApi(http);
    final session = await auth.login(username: 'webdev', password: 'password123');
    http.setAccessToken(session.accessToken);

    expect(session.accessToken, isNotEmpty);
    expect(session.user.timezone, 'Asia/Shanghai');

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = SyncStore(db);
    final engine = SyncEngine(db: db, store: store, api: SyncApi(http));
    try {
      final pulled = await engine.initialPull();
      expect(pulled, greaterThan(0));
      final meta = await store.meta();
      expect(meta!.lastServerCursor, greaterThan(0));
      await verifyMirrorAndProjections(store, session.user.timezone);
    } finally {
      await db.close();
    }
  }, skip: backendUp ? false : 'local backend unreachable from test VM');

  test('live backend: whole-month window projects and buckets by local day',
      () async {
    final http = ApiHttp.create(onRefresh: () async => false);
    final auth = AuthApi(http);
    final session = await auth.login(username: 'webdev', password: 'password123');
    http.setAccessToken(session.accessToken);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = SyncStore(db);
    final engine = SyncEngine(db: db, store: store, api: SyncApi(http));
    try {
      await engine.initialPull();
      final userTime = UserTime.tryCreate(session.user.timezone)!;

      // Exactly what MonthPage does: [1st of month, 1st of next month).
      final firstOfMonth = userTime.fromLocalParts(2026, 9, 1, 0, 0);
      final monthEnd = userTime.fromLocalParts(2026, 10, 1, 0, 0);
      final window = localWindowToUtc(userTime, firstOfMonth, monthEnd);
      final events = EventProjection(EventExpander(userTime))
          .project(await _snapshot(store), startUtc: window.start, endUtc: window.end)
          .events;

      expect(events, isNotEmpty,
          reason: 'September must project events (was empty before the fix)');

      final byDay = groupEventsByLocalDay(events, userTime);
      expect(byDay, isNotEmpty);
      // Keys must be the zero-padded form the grid looks up, not '2026-9-10'.
      expect(byDay.keys.every((k) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(k)), isTrue,
          reason: 'keys=${byDay.keys.take(5).toList()}');
      expect(byDay.containsKey('2026-09-10'), isTrue,
          reason: 'Sep 10 has classes in the seeded data');
      expect(byDay['2026-09-10'], isNotEmpty);
    } finally {
      await db.close();
    }
  }, skip: backendUp ? false : 'local backend unreachable from test VM');

  test('recorded backend: journal replay → decode → projection parity', () async {
    final dir = Directory('${Directory.current.path}/test/fixtures/live_backend');
    final journalRaw = await File('${dir.path}/sync_changes.json').readAsString();
    final journal = jsonDecode(journalRaw) as Map<String, dynamic>;
    final changes = (journal['changes'] as List)
        .map((e) => SyncChange.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(changes, isNotEmpty);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final store = SyncStore(db);
    try {
      for (final c in changes) {
        await store.upsertEntityRow(EntityRow(
          entityType: c.entityType,
          entityId: c.entityId,
          revision: c.revision,
          payload: Map<String, dynamic>.from(c.payload),
          updatedAt: c.createdAt,
          deletedAt: _deletedAt(c.payload),
        ));
      }
      await verifyMirrorAndProjections(store, 'Asia/Shanghai');

      // Server-side projection recorded next to the journal must be
      // reproduced by the local expander (same window).
      final evRaw = await File(
        '${dir.path}/events_2026-09-07_2026-10-05.json',
      ).readAsString();
      final serverEvents = (jsonDecode(evRaw) as List);
      expect(serverEvents, isNotEmpty);

      final rows = <EntityRow>[];
      for (final t in [
        EntityTypes.calendar,
        EntityTypes.course,
        EntityTypes.courseMeeting,
        EntityTypes.period,
        EntityTypes.recurringSchedule,
        EntityTypes.todo,
        EntityTypes.todoBlock,
        EntityTypes.override,
      ]) {
        rows.addAll(await store.entitiesOfType(t));
      }
      final snapshot = EntitiesSnapshot(
        rows: rows,
        pendingOps: const [],
        conflicts: const [],
      );
      final userTime = UserTime.tryCreate('Asia/Shanghai')!;
      final local = EventProjection(EventExpander(userTime)).project(
        snapshot,
        startUtc: DateTime.utc(2026, 9, 7),
        endUtc: DateTime.utc(2026, 10, 5),
      ).events;
      expect(local.any((e) => e.type.name == 'course'), isTrue,
          reason: 'offline local projection produced no course events');
      expect((local.length - serverEvents.length).abs() <= 6, isTrue,
          reason: 'server=${serverEvents.length} events vs local=${local.length}');

      // Month view regression, against real captured data: the whole-month
      // window [Sep 1, Oct 1) must project events and bucket them under the
      // zero-padded keys the day cells look up.
      final firstOfMonth = userTime.fromLocalParts(2026, 9, 1, 0, 0);
      final monthEnd = userTime.fromLocalParts(2026, 10, 1, 0, 0);
      final monthWindow = localWindowToUtc(userTime, firstOfMonth, monthEnd);
      final monthEvents = EventProjection(EventExpander(userTime)).project(
        snapshot,
        startUtc: monthWindow.start,
        endUtc: monthWindow.end,
      ).events;
      expect(monthEvents, isNotEmpty,
          reason: 'September must not project empty (was the month-view bug)');
      final byDay = groupEventsByLocalDay(monthEvents, userTime);
      expect(
        byDay.keys.every((k) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(k)),
        isTrue,
        reason: 'keys=${byDay.keys.take(5).toList()}',
      );
      expect(byDay['2026-09-10'], isNotEmpty,
          reason: 'seeded classes exist on Thu Sep 10');
    } finally {
      await db.close();
    }
  });
}

/// Asserts the offline mirror contains the seeded domain and that every row
/// decodes into typed models without throwing.
Future<void> verifyMirrorAndProjections(SyncStore store, String timezone) async {
  final calendars = await store.entitiesOfType(EntityTypes.calendar);
  final courses = await store.entitiesOfType(EntityTypes.course);
  final meetings = await store.entitiesOfType(EntityTypes.courseMeeting);
  final periods = await store.entitiesOfType(EntityTypes.period);
  expect(calendars, isNotEmpty, reason: 'seeded semester must be pulled');
  expect(courses, isNotEmpty);
  expect(meetings, isNotEmpty);
  expect(periods, isNotEmpty);

  final rows = <EntityRow>[
    ...calendars,
    ...courses,
    ...meetings,
    ...periods,
    ...await store.entitiesOfType(EntityTypes.recurringSchedule),
    ...await store.entitiesOfType(EntityTypes.todo),
    ...await store.entitiesOfType(EntityTypes.todoBlock),
    ...await store.entitiesOfType(EntityTypes.tag),
    ...await store.entitiesOfType(EntityTypes.category),
    ...await store.entitiesOfType(EntityTypes.override),
  ];
  final snapshot = EntitiesSnapshot(
    rows: rows,
    pendingOps: const [],
    conflicts: const [],
  );
  expect(liveCalendars(snapshot), isNotEmpty);
  expect(liveCourses(snapshot), isNotEmpty);
  expect(liveMeetings(snapshot), isNotEmpty);
  liveSchedules(snapshot);
  liveTodos(snapshot);
  liveBlocks(snapshot);
  liveTags(snapshot);
  liveCategories(snapshot);
  liveOverrides(snapshot);

  final userTime = UserTime.tryCreate(timezone)!;
  final events = EventProjection(EventExpander(userTime)).project(
    snapshot,
    startUtc: DateTime.utc(2026, 9, 7),
    endUtc: DateTime.utc(2026, 10, 5),
  ).events;
  expect(events, isNotEmpty);
  expect(events.any((e) => e.type.name == 'course'), isTrue,
      reason: 'seeded courses must project locally');
}

DateTime? _deletedAt(Map<String, dynamic> payload) {
  final v = payload['deletedAt'];
  if (v is String) return DateTime.tryParse(v)?.toUtc();
  return null;
}

/// Builds a snapshot from every mirrored entity type.
Future<EntitiesSnapshot> _snapshot(SyncStore store) async {
  final rows = <EntityRow>[];
  for (final t in EntityTypes.all) {
    rows.addAll(await store.entitiesOfType(t));
  }
  return EntitiesSnapshot(rows: rows, pendingOps: const [], conflicts: const []);
}
