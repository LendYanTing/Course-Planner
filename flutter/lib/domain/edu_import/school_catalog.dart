/// Offline directory of Chinese university login pages (phase 10, Step 3).
///
/// Backed by `assets/edu/schools_manifest.json`, generated from the exported
/// 3570-school manifest. Each row keeps only the six fields the importer needs,
/// so the bundled index stays small and loads without any network access.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Asset path registered in `pubspec.yaml`.
const _assetPath = 'assets/edu/schools_manifest.json';

/// A login page URL without a scheme, e.g. `jw.ahu.edu.cn`.
final _hostLike = RegExp(r'^[a-zA-Z0-9._:\-\[\]]+$');

/// An absolute URL scheme such as `https://` or `vpn://`.
final _hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');

final _surroundingQuotes = RegExp(r'''^["']+|["']+$''');

/// One school row (or one of the eight vendor templates) from the catalog.
class SchoolEntry {
  const SchoolEntry({
    required this.name,
    required this.loginUrl,
    required this.type,
    required this.mode,
    required this.strategy,
    required this.parser,
  });

  factory SchoolEntry.fromJson(Map<String, dynamic> json) => SchoolEntry(
        name: _stringOf(json['n']),
        loginUrl: _stringOf(json['u']),
        type: _stringOf(json['t']),
        mode: _stringOf(json['m']),
        strategy: _stringOf(json['s']),
        parser: _stringOf(json['p']),
      );

  /// Display name, original spelling from the manifest.
  final String name;

  /// Raw login URL: may be empty, lack a scheme, or contain free text.
  final String loginUrl;

  /// Vendor / parser family, e.g. `zf`, `qz` or `shuwei_new`.
  final String type;

  /// `pc` when the desktop user agent is recommended, otherwise empty.
  final String mode;

  /// Recommended import path, e.g. `local-parser` or `ai-fallback`.
  final String strategy;

  /// Explicit parser name when the manifest has one.
  final String parser;

  /// Whether [normalizedUrl] yields an absolute URL with a host.
  bool get hasUsableUrl {
    final url = normalizedUrl;
    if (url.isEmpty) return false;
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasScheme && uri.host.isNotEmpty;
  }

  /// Whether this row is expected to need the built-in LLM fallback.
  bool get isAiFallback {
    final normalizedStrategy = strategy.trim().toLowerCase();
    if (normalizedStrategy == 'ai-fallback' ||
        normalizedStrategy == 'ai_fallback') {
      return true;
    }
    final normalizedParser = parser.trim().toLowerCase();
    return normalizedParser == 'parser_gpt' || normalizedParser == 'gpt';
  }

  /// Chinese label for the vendor badge in the picker.
  String get vendorLabel {
    if (isAiFallback) return 'AI 智能解析';
    final normalized = type.trim().toLowerCase();
    if (normalized == 'zf' ||
        normalized.startsWith('zf_') ||
        normalized == 'zfsoft') {
      return '正方教务';
    }
    if (normalized == 'qz' ||
        normalized.startsWith('qz') ||
        normalized.contains('_qz')) {
      return '强智教务';
    }
    if (normalized == 'jz' || normalized.startsWith('jinzhi')) {
      return '金智教务';
    }
    if (normalized.contains('shuwei') ||
        normalized == 'shu' ||
        normalized == 'shu2024' ||
        normalized.contains('eams')) {
      return '树维教务';
    }
    if (normalized.startsWith('kingo') || normalized == 'qingguo') {
      return '青果教务';
    }
    if (normalized.contains('chaoxing') ||
        normalized == 'xuexitong' ||
        normalized == 'cx') {
      return '超星学习通';
    }
    if (normalized == 'cf' ||
        normalized.startsWith('cf_') ||
        normalized.contains('chengfang')) {
      return '乘方教务';
    }
    return '教务系统';
  }

  /// [loginUrl] made openable: trimmed, quotes stripped, and a scheme added
  /// for host-only values such as `jw.ahu.edu.cn`. Free text stays untouched.
  String get normalizedUrl {
    var value = loginUrl.replaceAll(_surroundingQuotes, '').trim();
    if (value.isEmpty) return '';
    if (_hasScheme.hasMatch(value)) return value;
    if (value.startsWith('//')) return 'https:$value';
    final authority = value.split('/').first.split('?').first;
    final looksLikeHost =
        (authority.contains('.') || authority.contains(':')) &&
            _hostLike.hasMatch(authority);
    if (looksLikeHost) return 'https://$value';
    return value;
  }
}

/// Searchable view over the bundled school manifest.
class SchoolCatalog {
  SchoolCatalog._(this.all);

  /// Builds a catalog from an explicit list instead of the bundled asset.
  ///
  /// Used by widget tests and by the picker's empty fallback.
  factory SchoolCatalog.fromEntries(Iterable<SchoolEntry> entries) =>
      SchoolCatalog._(List<SchoolEntry>.unmodifiable(entries));

  /// Every manifest row in source order, duplicates included.
  final List<SchoolEntry> all;

  static const _featured = <SchoolEntry>[
    SchoolEntry(
      name: '正方教务',
      loginUrl: '',
      type: 'zf',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '强智教务',
      loginUrl: '',
      type: 'qz',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '金智教务',
      loginUrl: '',
      type: 'jinzhi',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '树维/EAMS 教务',
      loginUrl: '',
      type: 'shuwei',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '青果教务',
      loginUrl: '',
      type: 'kingo',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '超星/学习通',
      loginUrl: '',
      type: 'chaoxing',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '乘方教务',
      loginUrl: '',
      type: 'chengfang',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
    SchoolEntry(
      name: '其他/通用教务网页',
      loginUrl: '',
      type: 'generic',
      mode: '',
      strategy: 'template',
      parser: '',
    ),
  ];

  /// The eight vendor templates shown above the school list.
  List<SchoolEntry> get featured => _featured;

  static SchoolCatalog? _cached;
  static Future<SchoolCatalog>? _pending;

  /// Loads and caches the bundled manifest.
  ///
  /// A missing or malformed asset yields an empty catalog instead of throwing;
  /// the picker then simply offers [featured] and manual URL entry.
  static Future<SchoolCatalog> load({AssetBundle? bundle}) {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _pending ??= _loadFrom(bundle ?? rootBundle).then((catalog) {
      _cached = catalog;
      return catalog;
    });
  }

  static Future<SchoolCatalog> _loadFrom(AssetBundle bundle) async {
    try {
      final raw = await bundle.loadString(_assetPath);
      final decoded = jsonDecode(raw);
      if (decoded is! List) return SchoolCatalog._(const <SchoolEntry>[]);
      final entries = <SchoolEntry>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          entries.add(SchoolEntry.fromJson(item));
        } else if (item is Map) {
          entries.add(
            SchoolEntry.fromJson(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          );
        }
      }
      return SchoolCatalog._(entries);
    } catch (_) {
      return SchoolCatalog._(const <SchoolEntry>[]);
    }
  }

  /// Finds the first row whose [SchoolEntry.name] matches [name] exactly.
  SchoolEntry? byName(String name) {
    final target = name.trim();
    if (target.isEmpty) return null;
    for (final entry in all) {
      if (entry.name == target) return entry;
    }
    final lower = target.toLowerCase();
    for (final entry in all) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    return null;
  }

  /// Filters [all] by school name first, then by type, URL and parser name.
  ///
  /// Prefix matches rank above substring matches, which rank above metadata
  /// matches; ties prefer shorter names and then dictionary order. Duplicate
  /// rows collapse, and at most [limit] entries are returned.
  List<SchoolEntry> search(String query, {int limit = 80}) {
    if (limit <= 0) return const <SchoolEntry>[];
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) {
      return all.take(limit).toList(growable: false);
    }

    final ranked = <_RankedEntry>[];
    for (var index = 0; index < all.length; index++) {
      final entry = all[index];
      final name = entry.name.toLowerCase();
      int rank;
      if (name.startsWith(normalizedQuery)) {
        rank = 0;
      } else if (name.contains(normalizedQuery)) {
        rank = 1;
      } else if (_matchesMetadata(entry, normalizedQuery)) {
        rank = 2;
      } else {
        continue;
      }
      ranked.add(_RankedEntry(entry, rank, index));
    }

    ranked.sort((a, b) {
      if (a.rank != b.rank) return a.rank.compareTo(b.rank);
      final byLength = a.entry.name.length.compareTo(b.entry.name.length);
      if (byLength != 0) return byLength;
      final byName = a.entry.name.compareTo(b.entry.name);
      if (byName != 0) return byName;
      final byUrl = a.entry.loginUrl.compareTo(b.entry.loginUrl);
      if (byUrl != 0) return byUrl;
      return a.index.compareTo(b.index);
    });

    final results = <SchoolEntry>[];
    final seen = <String>{};
    for (final item in ranked) {
      final key = '${item.entry.name}\u0000${item.entry.normalizedUrl}'
          '\u0000${item.entry.type}\u0000${item.entry.parser}';
      if (!seen.add(key)) continue;
      results.add(item.entry);
      if (results.length >= limit) break;
    }
    return results;
  }

  static bool _matchesMetadata(SchoolEntry entry, String query) {
    return entry.type.toLowerCase().contains(query) ||
        entry.loginUrl.toLowerCase().contains(query) ||
        entry.parser.toLowerCase().contains(query) ||
        entry.vendorLabel.toLowerCase().contains(query);
  }
}

class _RankedEntry {
  const _RankedEntry(this.entry, this.rank, this.index);

  final SchoolEntry entry;
  final int rank;
  final int index;
}

String _stringOf(Object? value) => value is String ? value : '';

/// Loads the bundled school manifest once for the education-system picker.
final schoolCatalogProvider = FutureProvider<SchoolCatalog>(
  (ref) => SchoolCatalog.load(),
);
