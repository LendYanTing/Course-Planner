/// Parses the CSV-style week column (docs/csv-import.md §Supported Week
/// Syntax) into a [WeekRule], mirroring the server parser so course forms
/// accept the same text (`1-5、7-11单、12-16双`).
library;

import '../../domain/week_rule.dart';

WeekRule? parseWeekRuleText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final normalized = text
      .replaceAll('、', ',')
      .replaceAll('，', ',')
      .replaceAll(' ', ',');
  final parts = normalized
      .split(',')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final segments = <WeekSegment>[];
  for (final part in parts) {
    var parity = WeekParity.all;
    var body = part;
    if (body.endsWith('单')) {
      parity = WeekParity.odd;
      body = body.substring(0, body.length - 1);
    } else if (body.endsWith('双')) {
      parity = WeekParity.even;
      body = body.substring(0, body.length - 1);
    }
    final dash = body.contains('-');
    int a, b;
    if (dash) {
      final p = body.split('-');
      a = int.tryParse(p[0]) ?? 0;
      b = p.length > 1 ? (int.tryParse(p[1]) ?? 0) : a;
    } else {
      a = int.tryParse(body) ?? 0;
      b = a;
    }
    if (a < 1 || b < a) return null;
    segments.add(WeekSegment(start: a, end: b, parity: parity));
  }
  if (segments.isEmpty) return null;
  return WeekRule(segments);
}
