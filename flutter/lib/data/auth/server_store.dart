import 'dart:convert';

import 'pref_store.dart';

/// A server this install has connected to before.
class KnownServer {
  const KnownServer({required this.baseUrl, this.username});

  final String baseUrl;
  final String? username;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        if (username != null && username!.isNotEmpty) 'username': username,
      };

  static KnownServer? fromJson(Map<String, dynamic> m) {
    final url = m['baseUrl'];
    if (url is! String || url.isEmpty) return null;
    final user = m['username'];
    return KnownServer(baseUrl: url, username: user is String ? user : null);
  }
}

/// Remembers which servers the user has signed in to and which one is active.
/// Backed by [PrefStore] (no DB migration needed).
class ServerStore {
  ServerStore(this._prefs);

  static const _knownKey = 'known_servers';
  static const _activeKey = 'active_server';
  static const _dataKey = 'data_server';

  final PrefStore _prefs;

  Future<List<KnownServer>> known() async {
    final raw = await _prefs.read(_knownKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((m) => KnownServer.fromJson(m.cast<String, dynamic>()))
          .whereType<KnownServer>()
          .toList();
    } on Object {
      return const [];
    }
  }

  /// Adds/updates [baseUrl] in the known list (most recent first).
  Future<void> remember(String baseUrl, {String? username}) async {
    final current = [...await known()];
    current.removeWhere((s) => s.baseUrl == baseUrl);
    current.insert(0, KnownServer(baseUrl: baseUrl, username: username));
    await _prefs.write(
      _knownKey,
      jsonEncode(current.map((s) => s.toJson()).toList()),
    );
  }

  Future<String?> activeBaseUrl() => _prefs.read(_activeKey);

  Future<void> setActive(String baseUrl) => _prefs.write(_activeKey, baseUrl);

  /// Which server the **local database** currently mirrors. Lets startup tell
  /// "my cached data belongs to this server" from "the active server changed
  /// but the local data is still the previous one's" (the latter must never be
  /// pushed upstream).
  Future<String?> dataServer() => _prefs.read(_dataKey);

  Future<void> setDataServer(String baseUrl) => _prefs.write(_dataKey, baseUrl);

  Future<void> forget(String baseUrl) async {
    final current = [...await known()]..removeWhere((s) => s.baseUrl == baseUrl);
    await _prefs.write(
      _knownKey,
      jsonEncode(current.map((s) => s.toJson()).toList()),
    );
  }
}
