/// Academic week rules (docs/domain-model.md §5, docs/csv-import.md).
///
/// Mirrors server `common/weekrule`: an ordered list of segments like
/// `1-5、7-11单、12-16双` normalised to `[{start,end,parity}]`.
library;

enum WeekParity {
  all('all'),
  odd('odd'),
  even('even');

  const WeekParity(this.wire);
  final String wire;

  static WeekParity fromWire(String? s) {
    switch (s) {
      case 'odd':
        return WeekParity.odd;
      case 'even':
        return WeekParity.even;
      default:
        return WeekParity.all;
    }
  }
}

class WeekSegment {
  const WeekSegment({required this.start, required this.end, this.parity = WeekParity.all});

  factory WeekSegment.fromJson(Map<String, dynamic> m) => WeekSegment(
        start: (m['start'] as num?)?.toInt() ?? 1,
        end: (m['end'] as num?)?.toInt() ?? 1,
        parity: WeekParity.fromWire(m['parity'] as String?),
      );

  final int start;
  final int end;
  final WeekParity parity;

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'parity': parity.wire};
}

/// A normalised segment list. An empty list means "every week".
class WeekRule {
  const WeekRule([this.segments = const []]);

  factory WeekRule.fromJson(Object? json) {
    if (json == null) return const WeekRule();
    if (json is List) {
      return WeekRule(json
          .whereType<Map>()
          .map((e) => WeekSegment.fromJson(Map<String, dynamic>.from(e)))
          .toList());
    }
    if (json is Map) {
      final wrapped = Map<String, dynamic>.from(json);
      final segs = wrapped['segments'];
      if (segs is List) {
        return WeekRule(segs
            .whereType<Map>()
            .map((e) => WeekSegment.fromJson(Map<String, dynamic>.from(e)))
            .toList());
      }
    }
    return const WeekRule();
  }

  final List<WeekSegment> segments;

  bool get isEmpty => segments.isEmpty;

  bool get isEveryWeek =>
      segments.isEmpty ||
      (segments.length == 1 &&
          segments.first.start == 1 &&
          segments.first.parity == WeekParity.all &&
          segments.first.end >= 60);

  /// Expands to the sorted week numbers covered, clamped to [totalWeeks].
  List<int> weeks(int totalWeeks) {
    if (totalWeeks < 1) return const [];
    final set = <int>{};
    for (final seg in segments) {
      final lo = seg.start < 1 ? 1 : seg.start;
      final hi = seg.end > totalWeeks ? totalWeeks : seg.end;
      for (var w = lo; w <= hi; w++) {
        switch (seg.parity) {
          case WeekParity.odd:
            if (w.isOdd) set.add(w);
          case WeekParity.even:
            if (w.isEven) set.add(w);
          case WeekParity.all:
            set.add(w);
        }
      }
    }
    final out = set.toList()..sort();
    return out;
  }

  bool matchesWeek(int w) {
    for (final seg in segments) {
      if (w < seg.start || w > seg.end) continue;
      switch (seg.parity) {
        case WeekParity.odd:
          if (w.isOdd) return true;
        case WeekParity.even:
          if (w.isEven) return true;
        case WeekParity.all:
          return true;
      }
    }
    return false;
  }

  /// Human-readable form for previews, e.g. `1-5、7-11单`.
  String describe() {
    if (segments.isEmpty) return 'all';
    return segments
        .map((s) {
          final buf = StringBuffer('${s.start}');
          if (s.end != s.start) buf.write('-${s.end}');
          if (s.parity == WeekParity.odd) buf.write('单');
          if (s.parity == WeekParity.even) buf.write('双');
          return buf.toString();
        })
        .join('、');
  }

  List<Map<String, dynamic>> toJson() => segments.map((s) => s.toJson()).toList();
}
