import 'package:course_planner/agent/local_agent_tools.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/override.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

/// Phase 5 Step 2: the local MCP-equivalent tools read the offline mirror and
/// stage all writes into one change set that is applied atomically.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  late AppDatabase db;
  late SyncStore store;
  late EntityRepo repo;
  late LocalAgentTools tools;
  late String calendarId;
  late String courseId;
  late String meetingId;
  late String today;
  late String tomorrow;
  late String deadline;

  setUp(() async {
    final nowLocal = ut.localFromUtc(DateTime.now().toUtc());
    final monday = ut.localDateAfter(nowLocal, -(nowLocal.weekday - 1));
    today = ut.localDateString(nowLocal);
    tomorrow = ut.localDateString(ut.localDateAfter(nowLocal, 1));
    deadline = '${ut.localDateString(ut.localDateAfter(nowLocal, 2))} 18:00';

    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
    repo = EntityRepo(db, store);

    // The active semester starts on Monday of the current week, so "today" is
    // always in week 1 regardless of when the test runs.
    calendarId = await repo.localCreate(
      entityType: EntityTypes.calendar,
      snapshot: {
        'name': '2026 秋',
        'firstDay': ut.localDateString(monday),
        'totalWeeks': 16,
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 1,
        'startLocal': '08:00',
        'endLocal': '08:45',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 2,
        'startLocal': '08:55',
        'endLocal': '09:40',
      },
    );
    courseId = await repo.localCreate(
      entityType: EntityTypes.course,
      snapshot: {
        'calendarId': calendarId,
        'name': '高等数学',
        'location': '12-209',
      },
    );
    meetingId = await repo.localCreate(
      entityType: EntityTypes.courseMeeting,
      snapshot: {
        'courseId': courseId,
        'weekday': nowLocal.weekday,
        'periodStart': 1,
        'periodEnd': 2,
        'weekRule': const WeekRule([WeekSegment(start: 1, end: 16)]).toJson(),
      },
    );

    tools = LocalAgentTools(repo: repo, store: store, userTime: ut);
  });

  tearDown(() async {
    await db.close();
  });

  /// 1 Todo with 2 embedded blocks + 1 moved course occurrence = 4 items.
  Future<Map<String, dynamic>> proposeFour() => tools.call('propose_changes', {
    'changes': [
      {
        'kind': 'create_todo',
        'title': '生化大作业',
        'type': 'project',
        'priority': 'high',
        'deadlineLocal': deadline,
        'blocks': [
          {
            'startLocal': '$today 19:00',
            'endLocal': '$today 20:00',
            'blockNote': '查阅文献',
          },
          {
            'startLocal': '$today 20:00',
            'endLocal': '$today 21:00',
            'blockNote': '数据分析',
          },
        ],
      },
      {
        'kind': 'move_course_occurrence',
        'seriesType': 'course_meeting',
        'seriesId': meetingId,
        'occurrenceDateLocal': today,
        'newStartLocal': '$today 16:00',
        'newEndLocal': '$today 17:40',
      },
    ],
  });

  test('read tools return the snapshot data', () async {
    final now = await tools.call('get_current_time', {});
    expect(now['error'], isNull);
    expect(now['timezone'], 'Asia/Shanghai');
    expect(
      now['weekdayIndex'],
      ut.localFromUtc(DateTime.now().toUtc()).weekday,
    );
    final semester = now['semester'] as Map;
    expect(semester['name'], '2026 秋');
    expect(semester['currentWeek'], 1);
    expect(
      now['localDateTime'],
      matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')),
    );

    final calendar = await tools.call('get_calendar', {});
    final calendars = calendar['calendars'] as List;
    expect(calendars, hasLength(1));
    expect(calendar['activeCalendarId'], calendarId);
    expect((calendars.single as Map)['periods'], hasLength(2));

    final courses = await tools.call('get_courses', {});
    final courseList = courses['courses'] as List;
    expect(courseList, hasLength(1));
    final meetings = (courseList.single as Map)['meetings'] as List;
    expect(meetings, hasLength(1));
    expect((meetings.single as Map)['startLocal'], '08:00');
    expect((meetings.single as Map)['endLocal'], '09:40');

    final schedule = await tools.call('get_schedule', {
      'fromLocal': today,
      'toLocal': today,
    });
    final events = schedule['events'] as List;
    expect(events, hasLength(1));
    expect((events.single as Map)['type'], 'course');
    expect((events.single as Map)['title'], '高等数学');

    final free = await tools.call('get_free_slots', {
      'fromLocal': today,
      'toLocal': today,
    });
    final slots = free['freeSlots'] as List;
    expect(slots, hasLength(1));
    expect((slots.single as Map)['dateLocal'], today);
    expect((slots.single as Map)['displayStartLocal'], '09:40');
    expect((slots.single as Map)['displayEndLocal'], '22:30');
    expect((slots.single as Map)['durationMinutes'], 770);

    final todos = await tools.call('get_todos', {});
    expect(todos['todos'], isEmpty);

    final tags = await tools.call('get_tags_and_categories', {});
    expect(tags['tags'], isEmpty);
    expect(tags['categories'], isEmpty);
  });

  test('propose_changes stages 4 items without writing anything', () async {
    final result = await proposeFour();

    expect(result['error'], isNull);
    expect(result['count'], 4);
    expect(tools.pendingChangeSet, isNotNull);
    expect(tools.pendingChangeSet!.length, 4);
    expect(tools.pendingChangeSet!.hasConflicts, isFalse);
    expect(tools.pendingChangeSet!.items.map((i) => i.kind), [
      'create_todo',
      'create_todo_block',
      'create_todo_block',
      'move_course_occurrence',
    ]);
    expect(
      tools.pendingChangeSet!.items.first.summary,
      contains('+ [待办] 生化大作业'),
    );
    expect(tools.pendingChangeSet!.items[1].summary, contains('[时间块]'));
    expect(tools.pendingChangeSet!.items.last.summary, contains('[调课] 高等数学'));

    // Nothing reached the mirror yet.
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);
    expect(await store.entitiesOfType(EntityTypes.todoBlock), isEmpty);
    expect(await store.entitiesOfType(EntityTypes.override), isEmpty);
  });

  test('discardPendingChangeSet drops the staged writes', () async {
    await proposeFour();
    tools.discardPendingChangeSet();

    expect(tools.pendingChangeSet, isNull);
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);
    expect(await store.entitiesOfType(EntityTypes.todoBlock), isEmpty);
    expect(await store.entitiesOfType(EntityTypes.override), isEmpty);
  });

  test(
    'applyPendingChangeSet writes Todo, blocks and override together',
    () async {
      await proposeFour();
      await tools.applyPendingChangeSet();

      expect(tools.pendingChangeSet, isNull);
      expect(await store.entitiesOfType(EntityTypes.todo), hasLength(1));
      expect(await store.entitiesOfType(EntityTypes.todoBlock), hasLength(2));
      final overrides = await store.entitiesOfType(EntityTypes.override);
      expect(overrides, hasLength(1));
      expect(overrides.single.payload['seriesType'], SeriesTypes.courseMeeting);
      expect(overrides.single.payload['seriesId'], meetingId);
      expect(overrides.single.payload['occurrenceDateLocal'], today);
      expect(overrides.single.payload['action'], OverrideAction.move.wire);

      final snap = await tools.snapshot();
      final todo = liveTodos(snap).single.value;
      final blocks = liveBlocks(snap).map((e) => e.value).toList();
      expect(blocks, hasLength(2));
      expect(blocks.every((b) => b.todoId == todo.id), isTrue);
      expect(blocks.map((b) => b.blockNote), containsAll(['查阅文献', '数据分析']));

      // The move is visible to the projection via the read tool.
      final schedule = await tools.call('get_schedule', {
        'fromLocal': today,
        'toLocal': today,
      });
      final events = schedule['events'] as List;
      expect(
        events.any(
          (e) =>
              (e as Map)['type'] == 'course' &&
              (e['displayStart'] as String).endsWith('16:00'),
        ),
        isTrue,
      );
    },
  );

  test('a block over a course is staged with a conflict warning', () async {
    final result = await tools.call('propose_changes', {
      'changes': [
        {
          'kind': 'create_todo',
          'title': '冲突测试',
          'blocks': [
            {'startLocal': '$today 08:30', 'endLocal': '$today 09:00'},
          ],
        },
      ],
    });

    expect(result['error'], isNull);
    expect(result['hasConflicts'], isTrue);
    final pending = tools.pendingChangeSet!;
    expect(pending.hasConflicts, isTrue);
    expect(pending.items.last.conflictWarning, contains('与课程「高等数学」时间冲突'));
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);
  });

  test('invalid proposals error out and leave no pending change set', () async {
    // Cross-midnight block.
    final crossMidnight = await tools.call('propose_changes', {
      'changes': [
        {
          'kind': 'create_todo',
          'title': '熬夜任务',
          'blocks': [
            {'startLocal': '$today 23:00', 'endLocal': '$tomorrow 01:00'},
          ],
        },
      ],
    });
    expect(crossMidnight['error'], isA<String>());
    expect(tools.pendingChangeSet, isNull);
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);

    // Unknown kind.
    final unknown = await tools.call('propose_changes', {
      'changes': [
        {'kind': 'destroy_universe'},
      ],
    });
    expect(unknown['error'], isA<String>());
    expect(tools.pendingChangeSet, isNull);

    // Missing id.
    final missingId = await tools.call('propose_changes', {
      'changes': [
        {'kind': 'delete_todo'},
      ],
    });
    expect(missingId['error'], isA<String>());
    expect(tools.pendingChangeSet, isNull);
  });

  test('a later invalid proposal keeps an already staged change set', () async {
    await proposeFour();
    expect(tools.pendingChangeSet!.length, 4);

    final invalid = await tools.call('propose_changes', {
      'changes': [
        {'kind': 'delete_todo'},
      ],
    });

    expect(invalid['error'], isA<String>());
    expect(tools.pendingChangeSet, isNotNull);
    expect(tools.pendingChangeSet!.length, 4);
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);
  });
}
