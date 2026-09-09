import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Material 3 theme. Event colors come from the server (`color` fields);
/// this file defines the neutral shell, shared component styles and the
/// cross-platform font stack so CJK glyphs render consistently.
abstract class AppTheme {
  static const seed = Color(0xFF3F51B5);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  /// Deterministic family for a platform: Latin + CJK come from ONE family so
  /// no per-glyph fallback mixing happens (docs: consistent UI type).
  static String? _fontFamilyForPlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        return 'Microsoft YaHei'; // 微软雅黑 ships with Windows
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return 'PingFang SC';
      case TargetPlatform.android:
        return 'Noto Sans CJK SC';
      default:
        return null;
    }
  }

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final fontFamily = _fontFamilyForPlatform();
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        elevation: 0,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    );
    if (fontFamily == null) return base;
    // Spread the family over every text style so mixed scripts never fall
    // back to different fonts mid-string.
    final all = base.textTheme.apply(fontFamily: fontFamily);
    return base.copyWith(
      textTheme: all,
      primaryTextTheme: all,
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontFamily: fontFamily),
      ),
    );
  }

  // Semantic event colors (used when the entity has no explicit color).
  static const courseColor = Color(0xFF4A6FA5);
  static const scheduleColor = Color(0xFF26A69A);
  static const blockColor = Color(0xFF7E57C2);
  static const deadlineColor = Color(0xFFE53935);
  static const nowLineColor = Color(0xFFFF8A00);

  /// Maps a hex string from the server (`#RRGGBB` or `RRGGBB`) to a color.
  static Color? parseHex(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    final v = int.tryParse(h, radix: 16);
    if (v == null) return null;
    return Color(v);
  }
}
