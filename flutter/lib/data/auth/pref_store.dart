import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small persistent key/value store for **non-synced UI preferences** (e.g. the
/// week view's timeline/grid mode). Backed by the same platform secure storage
/// already used for tokens; shares its lifecycle so no extra dependency or DB
/// migration is needed.
class PrefStore {
  PrefStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'cp_pref_';

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) => _storage.read(key: '$_prefix$key');

  Future<void> write(String key, String value) =>
      _storage.write(key: '$_prefix$key', value: value);
}
