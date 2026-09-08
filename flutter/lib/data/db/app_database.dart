import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'app_database.g.dart';

/// Single-row application meta: signed-in profile, sync cursor and the last
/// observed server clock (docs/datetime.md §8).
class AppMeta extends Table {
  IntColumn get id => integer()();
  TextColumn get userId => text().nullable()();
  TextColumn get username => text().nullable()();
  TextColumn get email => text().nullable()();

  /// IANA name of the immutable user timezone (server-provided).
  TextColumn get timezone => text().nullable()();

  IntColumn get lastServerCursor => integer().withDefault(const Constant(0))();

  /// Device time at the moment /meta/time last answered.
  DateTimeColumn get clockFetchedAt => dateTime().nullable()();

  /// Server-reported UTC instant at that moment.
  DateTimeColumn get clockServerUtc => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Offline mirror of server entities: one row per (entityType, entityId)
/// holding the canonical JSON snapshot (docs/architecture.md §2). Pending
/// local mutations are never folded into this table; they live in
/// [PendingOps] and are overlaid when rendering (docs/sync-protocol.md §5).
class Entities extends Table {
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get payload => text()();

  /// Server revision of the snapshot stored in [payload].
  IntColumn get revision => integer()();

  DateTimeColumn get updatedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {entityType, entityId};
}

/// The operation queue (docs/sync-protocol.md §4): every local mutation
/// appends one row here inside the same transaction that updates UI state.
class PendingOps extends Table {
  TextColumn get operationId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()(); // create | update | delete
  IntColumn get baseRevision => integer()();
  TextColumn get changes => text()(); // JSON of the changes map
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {operationId};
}

/// Server-reported field conflicts awaiting user resolution
/// (docs/sync-protocol.md §13). Keyed by the original operation id.
class ConflictOps extends Table {
  TextColumn get operationId => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get base => text()(); // JSON
  TextColumn get local => text()(); // JSON
  TextColumn get server => text()(); // JSON
  TextColumn get conflictingFields => text()(); // JSON list of field names
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {operationId};
}

@DriftDatabase(tables: [AppMeta, Entities, PendingOps, ConflictOps])
class AppDatabase extends _$AppDatabase {
  /// Opens (creating if needed) the on-device SQLite working copy.
  AppDatabase() : super(_open());

  /// Test/embedding hook: use an explicit [QueryExecutor] (e.g.
  /// `NativeDatabase.memory()`).
  AppDatabase.forTesting(super.executor);

  static QueryExecutor _open() => driftDatabase(name: 'course_planner');

  @override
  int get schemaVersion => 1;

  /// Row id for the singleton [AppMeta] row.
  static const int metaRowId = 1;
}
