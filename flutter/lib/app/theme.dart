import 'package:flutter/material.dart';

/// Material 3 theme. Event colors are taken from the server (`color` fields);
/// this file only defines the neutral shell and shared component styles.
abstract class AppTheme {
  static const seed = Color(0xFF3F51B5);

  static ThemeData light() => _base(Brightness.light);

  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
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
