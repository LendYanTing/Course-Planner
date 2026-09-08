import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/user_time.dart';
import '../data/db/app_database.dart';
import '../data/local/sync_store.dart';
import 'app_services.dart';
import 'session.dart';

/// The drift database singleton.
final dbProvider = Provider<AppDatabase>(
  (ref) => ref.watch(servicesProvider).db,
);

/// The local sync store (mirror + queue + conflicts + meta).
final syncStoreProvider = Provider<SyncStore>(
  (ref) => ref.watch(servicesProvider).store,
);

/// The immutable user timezone once signed in (server-provided, never the
/// device timezone; docs/datetime.md §3).
final userTimeProvider = Provider<UserTime?>((ref) {
  final state = ref.watch(sessionControllerProvider);
  final tz = state.profile?.timezone;
  if (tz == null || tz.isEmpty) return null;
  return UserTime.tryCreate(tz);
});
