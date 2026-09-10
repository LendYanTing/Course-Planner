import 'package:course_planner/data/auth/pref_store.dart';

/// In-memory [PrefStore] for widget tests: widgets that read local preferences
/// (week mode, noon boundary, active semester, month row height) would
/// otherwise need the full service graph, whose real store writes to platform
/// secure storage.
class MemoryPrefs extends PrefStore {
  MemoryPrefs([Map<String, String>? initial]) : _values = {...?initial};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
