/// Tolerant readers over decoded JSON maps (`Map<String, dynamic>`).
library;

String readString(Map<String, dynamic> m, String key, {String fallback = ''}) {
  final v = m[key];
  if (v is String) return v;
  return fallback;
}

String? readStringOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is String) return v;
  return null;
}

int readInt(Map<String, dynamic> m, String key, {int fallback = 0}) {
  final v = m[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

int? readIntOrNull(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool readBool(Map<String, dynamic> m, String key, {bool fallback = false}) {
  final v = m[key];
  if (v is bool) return v;
  return fallback;
}

Map<String, dynamic> readMap(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is Map) return Map<String, dynamic>.from(v);
  return const {};
}

List<dynamic> readList(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) return v;
  return const [];
}

List<String> readStringList(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) {
    return v.whereType<String>().toList();
  }
  return const [];
}

List<int> readIntList(Map<String, dynamic> m, String key) {
  final v = m[key];
  if (v is List) {
    return v
        .map((e) => e is num ? e.toInt() : (e is String ? int.tryParse(e) : null))
        .whereType<int>()
        .toList();
  }
  return const [];
}

/// Parses a UTC RFC3339 string into a UTC [DateTime], or returns null.
DateTime? parseUtc(String? value) {
  if (value == null || value.isEmpty) return null;
  final dt = DateTime.tryParse(value);
  if (dt == null) return null;
  return dt.toUtc();
}

/// Serializes a UTC [DateTime] as RFC3339 (e.g. `2026-09-08T01:00:00Z`),
/// matching how the server formats instants (`time.RFC3339`).
String formatUtc(DateTime dt) {
  final u = dt.toUtc();
  final ms = u.millisecond;
  final base =
      '${u.year.toString().padLeft(4, '0')}-'
      '${u.month.toString().padLeft(2, '0')}-'
      '${u.day.toString().padLeft(2, '0')}T'
      '${u.hour.toString().padLeft(2, '0')}:'
      '${u.minute.toString().padLeft(2, '0')}:'
      '${u.second.toString().padLeft(2, '0')}';
  return ms == 0 ? '$base' 'Z' : '$base.${ms.toString().padLeft(3, '0')}' 'Z';
}
