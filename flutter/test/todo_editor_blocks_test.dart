import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/sync.dart';
import 'package:course_planner/domain/todo.dart';
import 'package:course_planner/presentation/adaptive/adaptive.dart';
import 'package:course_planner/presentation/todo/todo_blocks_sheet.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';
import 'helpers/memory_prefs.dart';
import 'helpers/week_page_harness.dart' show FakeSession;

/// The editor's schedule section: a one-off owns exactly one inline window, a
/// project delegates to TodoBlocksSheet, and the list rows expose one confirmed
/// delete action plus honest priority / block / pending marks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  // 2026-09-07 10:00–11:00 Asia/Shanghai (+08) == 02:00–03:00Z.
  final blockStart = ut.utcFromLocalParts(2026, 9, 7, 10, 0);
  final blockEnd = ut.utcFromLocalParts(2026, 9, 7, 11, 0);

  Todo oneOffTodo() => const Todo(
        id: 't-one',
        title: '买菜',
        type: TodoType.oneOff,
        priority: TodoPriority.normal,
        status: TodoStatus.todo,
        revision: 1,
      );

  Todo projectTodo() => const Todo(
        id: 't-proj',
        title: '大作业',
        type: TodoType.project,
        priority: TodoPriority.high,
        status: TodoStatus.todo,
        revision: 1,
      );

  TodoBlock oneBlock() => TodoBlock(
        id: 'b-one',
        todoId: 't-one',
        startAt: blockStart,
        endAt: blockEnd,
        blockNote: '查文献',
        status: BlockStatus.scheduled,
        revision: 1,
      );

  TodoBlock projectBlock(String id, int day) => TodoBlock(
        id: id,
        todoId: 't-proj',
        startAt: ut.utcFromLocalParts(2026, 9, day, 10, 0),
        endAt: ut.utcFromLocalParts(2026, 9, day, 11, 0),
        status: BlockStatus.scheduled,
        revision: 1,
      );

  EntityRow todoRow(
    String id,
    String title, {
    String type = 'one_off',
    String priority = 'normal',
    String status = 'todo',
  }) =>
      EntityRow(
        entityType: EntityTypes.todo,
        entityId: id,
        revision: 1,
        payload: {
          'id': id,
          'title': title,
          'type': type,
          'status': status,
          'priority': priority,
          'createdAt': '2026-09-01T00:00:00Z',
          'revision': 1,
        },
      );

  EntityRow blockRow(TodoBlock b, {String status = 'scheduled'}) => EntityRow(
        entityType: EntityTypes.todoBlock,
        entityId: b.id,
        revision: 1,
        payload: {
          'id': b.id,
          'todoId': b.todoId,
          'startAt': b.startAt.toIso8601String(),
          'endAt': b.endAt.toIso8601String(),
          'status': status,
          'revision': 1,
          if (b.blockNote != null) 'blockNote': b.blockNote,
        },
      );

  late AppDatabase db;
  late SyncStore store;
  late EntityRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
    repo = EntityRepo(db, store);
  });

  tearDown(() async {
    await db.close();
  });

  // Direct queries (not the stream APIs) so the assertions do not depend on
  // drift's stream debounce timers inside a widget test.
  Future<EntitiesSnapshot> mirror() async => EntitiesSnapshot(
        rows: [
          ...await store.entitiesOfType(EntityTypes.todo),
          ...await store.entitiesOfType(EntityTypes.todoBlock),
        ],
        pendingOps: await store.pendingOps(),
        conflicts: await store.conflicts(),
      );

  Future<void> pumpEditor(
    WidgetTester tester, {
    Todo? existing,
    List<TodoBlock> existingBlocks = const [],
    EntitiesSnapshot? snapshot,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(_FakeServices(repo)),
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          sessionControllerProvider.overrideWith(FakeSession.new),
          userTimeProvider.overrideWithValue(ut),
          snapshotProvider.overrideWith(
            (ref) => Stream.value(
              snapshot ??
                  const EntitiesSnapshot(
                    rows: [],
                    pendingOps: [],
                    conflicts: [],
                  ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                        body: TodoEditorSheet(
                          existing: existing,
                          tags: const [],
                          categories: const [],
                          existingBlocks: existingBlocks,
                        ),
                      ),
                    ),
                  ),
                  child: const Text('打开编辑器'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();
  }

  /// Lets a real (in-memory drift) write finish outside the fake-async zone,
  /// then renders the result. Editing a todo talks to the repository, whose
  /// futures are real async work.
  Future<void> settleWrites(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    // The bottom capsule, so a scrolled editor does not hide the target.
    final save = find.widgetWithText(FilledButton, '保存').last;
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await settleWrites(tester);
  }

  group('editor: existing blocks', () {
    testWidgets('existing one-off loads its window inline without add/remove',
        (tester) async {
      await pumpEditor(
        tester,
        existing: oneOffTodo(),
        existingBlocks: [oneBlock()],
      );

      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isTrue);
      expect(find.textContaining('10:00'), findsOneWidget);
      // The stored block note is loaded into the inline note field.
      final noteField = tester.widget<TextField>(find.byType(TextField).last);
      expect(noteField.controller?.text, '查文献');
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('添加执行时间段'), findsNothing);
      expect(find.byIcon(Icons.event), findsOneWidget);
    });

    testWidgets('editing the window updates the stored block on save',
        (tester) async {
      await store.upsertEntityRow(blockRow(oneBlock()));
      await pumpEditor(
        tester,
        existing: oneOffTodo(),
        existingBlocks: [oneBlock()],
      );

      // 10:00 + 2h = 12:00 Shanghai == 04:00Z.
      await tester.ensureVisible(find.text('2小时'));
      await tester.tap(find.text('2小时'));
      await tester.pump();
      await tapSave(tester);

      final blocks = liveBlocks(await mirror(), todoId: 't-one');
      expect(blocks, hasLength(1));
      expect(blocks.single.value.endAt, DateTime.utc(2026, 9, 7, 4, 0));

      final ops = await store.pendingOps();
      final updates = ops.where(
        (o) => o.entityType == EntityTypes.todoBlock && o.operation == SyncOperations.update,
      );
      expect(updates, hasLength(1));
      expect(updates.single.entityId, 'b-one');
      expect(ops.where((o) => o.operation == SyncOperations.create), isEmpty);
    });

    testWidgets('new one-off gets exactly one inline window, no second one',
        (tester) async {
      await pumpEditor(tester);

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();

      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isTrue);
      expect(find.byIcon(Icons.event), findsOneWidget);
      expect(find.text('添加执行时间段'), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('switching an existing one-off off asks, then deletes its block',
        (tester) async {
      await store.upsertEntityRow(blockRow(oneBlock()));
      await pumpEditor(
        tester,
        existing: oneOffTodo(),
        existingBlocks: [oneBlock()],
      );

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();

      expect(find.text('关闭排入日程时间表？'), findsOneWidget);
      expect(find.textContaining('1 个时间块'), findsOneWidget);

      // Cancelling leaves the switch on and the block in place.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isTrue);
      expect(await store.pendingOps(), isEmpty);
      expect(liveBlocks(await mirror(), todoId: 't-one'), hasLength(1));

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await settleWrites(tester);

      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isFalse);
      expect(liveBlocks(await mirror(), todoId: 't-one'), isEmpty);
      final ops = await store.pendingOps();
      expect(
        ops.where((o) => o.entityType == EntityTypes.todoBlock && o.operation == SyncOperations.delete),
        hasLength(1),
      );
    });

    testWidgets('existing project links to TodoBlocksSheet', (tester) async {
      final blocks = [
        projectBlock('b-p1', 8),
        projectBlock('b-p2', 9),
      ];
      final snapshot = EntitiesSnapshot(
        rows: [
          todoRow('t-proj', '大作业', type: 'project', priority: 'high'),
          for (final b in blocks) blockRow(b),
        ],
        pendingOps: const [],
        conflicts: const [],
      );
      await pumpEditor(
        tester,
        existing: projectTodo(),
        existingBlocks: blocks,
        snapshot: snapshot,
      );

      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isTrue);
      expect(find.text('编辑时间块'), findsOneWidget);
      expect(find.text('已安排 2 个时间块'), findsOneWidget);

      await tester.tap(find.text('编辑时间块'));
      await tester.pumpAndSettle();

      expect(find.byType(TodoBlocksSheet), findsOneWidget);
      expect(find.text('时间块 · 大作业'), findsOneWidget);
    });

    testWidgets('a new project still drafts several inline windows and turns '
        'off when the last one is removed', (tester) async {
      await pumpEditor(tester);

      await tester.ensureVisible(find.text('标签与更多'));
      await tester.tap(find.text('标签与更多'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, '项目'));
      await tester.tap(find.widgetWithText(ChoiceChip, '项目'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(AppSwitch));
      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(find.text('添加执行时间段'), findsOneWidget);

      await tester.ensureVisible(find.text('添加执行时间段'));
      await tester.tap(find.text('添加执行时间段'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加执行时间段'));
      await tester.tap(find.text('添加执行时间段'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.event), findsNWidgets(2));

      await tester.ensureVisible(find.byIcon(Icons.close).first);
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.event), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.event), findsNothing);
      expect(tester.widget<AppSwitch>(find.byType(AppSwitch)).value, isFalse);
    });
  });

  group('list rows', () {
    Future<void> pumpPage(
      WidgetTester tester,
      EntitiesSnapshot snapshot, {
      Map<String, String>? prefs,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            servicesProvider.overrideWithValue(_FakeServices(repo)),
            prefStoreProvider.overrideWithValue(MemoryPrefs(prefs)),
            sessionControllerProvider.overrideWith(FakeSession.new),
            userTimeProvider.overrideWithValue(ut),
            snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          ],
          child: const MaterialApp(home: TodoPage()),
        ),
      );
      await tester.pumpAndSettle();
    }

    EntitiesSnapshot withTodos(List<EntityRow> rows, {List<PendingOperation> pending = const []}) =>
        EntitiesSnapshot(rows: rows, pendingOps: pending, conflicts: const []);

    testWidgets('a row has one delete icon and the action asks first',
        (tester) async {
      final snapshot = withTodos([todoRow('t1', '唯一任务')]);
      await pumpPage(tester, snapshot);

      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.more_time), findsNothing);
      // The AppBar still has its own overflow menu; the row must not.
      final row = find
          .ancestor(of: find.text('唯一任务'), matching: find.byType(InkWell))
          .first;
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.more_vert)),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('删除任务？'), findsOneWidget);
      expect(find.text('删除后无法恢复。'), findsOneWidget);

      // Cancel keeps the todo and queues nothing.
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await store.pendingOps(), isEmpty);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await settleWrites(tester);

      final ops = await store.pendingOps();
      expect(
        ops.where((o) => o.entityType == EntityTypes.todo && o.operation == SyncOperations.delete),
        hasLength(1),
      );
    });

    testWidgets('all four priorities render distinct pills', (tester) async {
      final snapshot = withTodos([
        todoRow('p-urgent', '急事', priority: 'urgent'),
        todoRow('p-high', '要事', priority: 'high'),
        todoRow('p-normal', '常事', priority: 'normal'),
        todoRow('p-low', '闲事', priority: 'low'),
      ]);
      await pumpPage(tester, snapshot);

      expect(find.text('紧急'), findsOneWidget);
      expect(find.text('高'), findsOneWidget);
      expect(find.text('普通'), findsOneWidget);
      expect(find.text('低'), findsOneWidget);
    });

    testWidgets('block counts only appear for projects with more than one block',
        (tester) async {
      final snapshot = withTodos([
        todoRow('t-one', '一次性'),
        blockRow(oneBlock()),
        todoRow('t-proj', '项目', type: 'project'),
        blockRow(projectBlock('b-p1', 8), status: 'completed'),
        blockRow(projectBlock('b-p2', 9)),
      ]);
      await pumpPage(tester, snapshot);

      expect(find.text('0/1 块'), findsNothing);
      expect(find.text('0 块已完成/1'), findsNothing);
      expect(find.text('1 块已完成/2'), findsOneWidget);
    });

    testWidgets('pending cloud icon is hidden while cloud sync is off',
        (tester) async {
      final pending = [
        PendingOperation(
          operationId: 'op-1',
          entityType: EntityTypes.todo,
          entityId: 't-pending',
          operation: SyncOperations.update,
          baseRevision: 1,
          changes: const {'title': '待上传任务'},
          createdAt: DateTime.utc(2026, 9, 1),
        ),
      ];
      final snapshot = withTodos(
        [todoRow('t-pending', '待上传任务')],
        pending: pending,
      );
      await pumpPage(tester, snapshot);

      expect(find.text('待上传任务'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_upload_outlined), findsNothing);
    });

    testWidgets('pending cloud icon appears when cloud sync is on',
        (tester) async {
      final pending = [
        PendingOperation(
          operationId: 'op-1',
          entityType: EntityTypes.todo,
          entityId: 't-pending',
          operation: SyncOperations.update,
          baseRevision: 1,
          changes: const {'title': '待上传任务'},
          createdAt: DateTime.utc(2026, 9, 1),
        ),
      ];
      final snapshot = withTodos(
        [todoRow('t-pending', '待上传任务')],
        pending: pending,
      );
      await pumpPage(tester, snapshot, prefs: {'sync_enabled': 'true'});

      expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    });
  });
}

/// Minimal [AppServices] stand-in: the todo UI only needs the repository.
/// Every other member throws if touched, so an accidental dependency fails
/// loudly.
class _FakeServices implements AppServices {
  _FakeServices(this.repo);

  @override
  final EntityRepo repo;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
