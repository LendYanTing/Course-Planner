/// Course colour differencing: picks the colour that is farthest (in CIE76
/// ΔE, i.e. Lab-space Euclidean distance) from the colours already in use.
///
/// Three curated families are available so a semester can be re-coloured with
/// one tap (docs/plans/v1/phase-3-theme-and-visuals.md §Step 2):
///
/// * [CoursePaletteStyle.morandi] — 16 soft, low-saturation pastels with evenly
///   spaced hues (the default).
/// * [CoursePaletteStyle.vibrant] — 16 vivid, high-contrast hues.
/// * [CoursePaletteStyle.monetHarmony] — rotates the golden angle from the
///   active theme seed hue, so colours stay harmonious with the rest of the UI
///   while remaining clearly distinguishable.
///
/// When more colours are needed than the curated pool holds, new hues are
/// generated with the golden angle (`(index * 137.508) % 360`) plus alternating
/// lightness bands, so 20+ courses still stay apart.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../domain/course.dart';

/// Colour family used when assigning course colours.
enum CoursePaletteStyle { morandi, vibrant, monetHarmony }

/// Stateless course colour allocator. Pure Dart on top of [Color]: no I/O, no
/// cached state, so callers can use it from domain code and tests alike.
abstract final class CoursePalette {
  /// Hue step (degrees) of the golden angle; used to grow the pool beyond the
  /// curated colours and, in [CoursePaletteStyle.monetHarmony], to rotate away
  /// from the theme seed hue.
  static const double goldenAngle = 137.508;

  /// Size of each curated pool; extra colours are generated on demand.
  static const int paletteSize = 16;

  /// Seed used by [CoursePaletteStyle.monetHarmony] when the caller passes no
  /// [themeSeed]. Mirrors `AppTheme.seed`; duplicated here so this file stays
  /// independent of the app/theme layer.
  static const Color defaultSeed = Color(0xFF3F51B5);

  static final RegExp _hexPattern = RegExp(r'^[0-9a-fA-F]{6}$');

  /// Picks the candidate colour with the largest minimum CIE76 ΔE to
  /// [existingColors].
  ///
  /// Invalid or empty entries in [existingColors] are ignored. The result is
  /// always an uppercase `#RRGGBB` string.
  static String pickDistinctColor(
    Iterable<String?> existingColors, {
    CoursePaletteStyle style = CoursePaletteStyle.morandi,
    Color? themeSeed,
  }) {
    final used = <_Lab>[];
    for (final raw in existingColors) {
      final hex = _normalizeHex(raw);
      if (hex == null) continue;
      used.add(_Lab.fromHex(hex));
    }

    final seed = themeSeed ?? defaultSeed;
    final candidates = _candidates(style, seed, used.length);

    var best = candidates.first;
    var bestScore = -1.0;
    for (final hex in candidates) {
      final lab = _Lab.fromHex(hex);
      var score = double.infinity;
      for (final other in used) {
        final d = _distanceLab(lab, other);
        if (d < score) score = d;
      }
      // Strict `>` keeps the earliest candidate on ties, so the output is
      // deterministic for a given input order.
      if (score > bestScore) {
        bestScore = score;
        best = hex;
      }
    }
    return best;
  }

  /// Assigns one distinct colour per course, in input order.
  ///
  /// Existing course colours are deliberately not treated as "already used":
  /// a full re-assignment should produce a clean spread. The keys of the
  /// returned map are course ids.
  static Map<String, String> assignColorsForCourses(
    Iterable<Course> courses, {
    CoursePaletteStyle style = CoursePaletteStyle.morandi,
    Color? themeSeed,
  }) {
    final used = <String>[];
    final out = <String, String>{};
    for (final course in courses) {
      final hex = pickDistinctColor(used, style: style, themeSeed: themeSeed);
      used.add(hex);
      out[course.id] = hex;
    }
    return out;
  }

  /// Stable palette colour for an entity that has none stored (courses added
  /// before the colour palette existed, or a mirror written by an older
  /// client). The same label always maps to the same slot, and different
  /// labels spread over the 16 evenly spaced hues, so a timetable never renders
  /// as one flat colour again. "重新配色" still writes real values.
  static String colorForLabel(
    String label, {
    CoursePaletteStyle style = CoursePaletteStyle.morandi,
  }) {
    final slot = _stableHash(label) % paletteSize;
    final hue = slot * (360.0 / paletteSize);
    return switch (style) {
      CoursePaletteStyle.morandi => _hexFromHsl(hue, 0.34, 0.62),
      CoursePaletteStyle.vibrant => _hexFromHsl(hue, 0.82, 0.55),
      CoursePaletteStyle.monetHarmony => _hexFromHsl(hue, 0.50, 0.64),
    };
  }

  /// FNV-1a over the UTF-16 code units: deterministic across launches (unlike
  /// `String.hashCode`, which is not guaranteed to be stable).
  static int _stableHash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  /// CIE76 colour difference (ΔE) between two hex colours, in Lab space.
  ///
  /// Invalid input yields `0.0` instead of throwing, which keeps the allocator
  /// total when stored data is malformed.
  @visibleForTesting
  static double distance(String a, String b) {
    final ha = _normalizeHex(a);
    final hb = _normalizeHex(b);
    if (ha == null || hb == null) return 0;
    return _distanceLab(_Lab.fromHex(ha), _Lab.fromHex(hb));
  }

  /// Hue (degrees, `[0, 360)`) of a hex colour; `0` when the input is invalid.
  @visibleForTesting
  static double hueOf(String hex) {
    final normalized = _normalizeHex(hex);
    if (normalized == null) return 0;
    return _hueOfRgb(_rgbOfHex(normalized));
  }

  // ---- candidate generation ------------------------------------------------

  static List<String> _candidates(
    CoursePaletteStyle style,
    Color seed,
    int minimum,
  ) {
    final out = <String>[];
    final seen = <String>{};

    void add(double hue, double saturation, double lightness) {
      final hex = _hexFromHsl(hue, saturation, lightness);
      // Rounding can collapse neighbouring HSL values; keep the pool unique.
      if (seen.add(hex)) out.add(hex);
    }

    final seedHue = _hueOfRgb(_rgbOfColor(seed));

    for (var i = 0; i < paletteSize; i++) {
      switch (style) {
        case CoursePaletteStyle.morandi:
          // Saturation 30/40%, lightness 60/68%: soft, paper-like pastels.
          add(
            (i * 22.5 + 15) % 360,
            i.isEven ? 0.30 : 0.40,
            i % 4 < 2 ? 0.68 : 0.60,
          );
        case CoursePaletteStyle.vibrant:
          // Vivid mid-tones; the luma band keeps text legible on top.
          add(
            (i * 22.5 + 8) % 360,
            i.isEven ? 0.78 : 0.92,
            i % 4 < 2 ? 0.52 : 0.62,
          );
        case CoursePaletteStyle.monetHarmony:
          add(
            (seedHue + i * goldenAngle) % 360,
            i.isEven ? 0.46 : 0.54,
            i % 4 < 2 ? 0.62 : 0.70,
          );
      }
    }

    // Overshoot the curated pool with golden-angle hues. Two lightness bands
    // far apart from the pool's own bands keep ΔE large even where the hue is
    // close to an existing colour.
    var extra = 0;
    while (out.length < minimum + 8) {
      final i = paletteSize + extra;
      final hue = switch (style) {
        CoursePaletteStyle.monetHarmony => (seedHue + i * goldenAngle) % 360,
        _ => (i * goldenAngle + 15) % 360,
      };
      final saturation = switch (style) {
        CoursePaletteStyle.morandi => i.isEven ? 0.30 : 0.42,
        CoursePaletteStyle.vibrant => i.isEven ? 0.82 : 0.95,
        CoursePaletteStyle.monetHarmony => i.isEven ? 0.44 : 0.58,
      };
      final lightness = switch (style) {
        CoursePaletteStyle.morandi => i % 4 < 2 ? 0.50 : 0.80,
        CoursePaletteStyle.vibrant => i % 4 < 2 ? 0.45 : 0.66,
        CoursePaletteStyle.monetHarmony => i % 4 < 2 ? 0.55 : 0.75,
      };
      add(hue, saturation, lightness);
      extra++;
    }
    return out;
  }

  // ---- colour conversion helpers ------------------------------------------

  /// Accepts `#RRGGBB` or `RRGGBB`; returns uppercase `#RRGGBB` or `null`.
  static String? _normalizeHex(String? raw) {
    if (raw == null) return null;
    var h = raw.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length != 6 || !_hexPattern.hasMatch(h)) return null;
    return '#${h.toUpperCase()}';
  }

  static String _hexFromHsl(double hue, double saturation, double lightness) {
    final rgb = _hslToRgb(hue, saturation, lightness);
    final hex = (rgb.r << 16) | (rgb.g << 8) | rgb.b;
    return '#${hex.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  /// Standard HSL → sRGB conversion, `hue` in degrees, `s`/`l` in `[0, 1]`.
  static ({int r, int g, int b}) _hslToRgb(
    double hue,
    double saturation,
    double lightness,
  ) {
    final s = saturation.clamp(0.0, 1.0);
    final l = lightness.clamp(0.0, 1.0);
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = (((hue % 360) + 360) % 360) / 60.0;
    final x = c * (1 - ((hp % 2) - 1).abs());
    var r = 0.0;
    var g = 0.0;
    var b = 0.0;
    if (hp < 1) {
      r = c;
      g = x;
    } else if (hp < 2) {
      r = x;
      g = c;
    } else if (hp < 3) {
      g = c;
      b = x;
    } else if (hp < 4) {
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    final m = l - c / 2;
    int channel(double value) =>
        ((value + m) * 255).round().clamp(0, 255).toInt();
    return (r: channel(r), g: channel(g), b: channel(b));
  }

  static ({int r, int g, int b}) _rgbOfHex(String hex) {
    final value = int.parse(hex.substring(1), radix: 16);
    return (r: (value >> 16) & 0xFF, g: (value >> 8) & 0xFF, b: value & 0xFF);
  }

  static ({int r, int g, int b}) _rgbOfColor(Color color) => (
        r: (color.r * 255).round(),
        g: (color.g * 255).round(),
        b: (color.b * 255).round(),
      );

  /// Hue of an sRGB triple in degrees, `[0, 360)`. Greys report `0`.
  static double _hueOfRgb(({int r, int g, int b}) rgb) {
    final r = rgb.r / 255.0;
    final g = rgb.g / 255.0;
    final b = rgb.b / 255.0;
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final delta = maxC - minC;
    if (delta == 0) return 0;
    final double hue;
    if (maxC == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (maxC == g) {
      hue = 60 * ((b - r) / delta + 2);
    } else {
      hue = 60 * ((r - g) / delta + 4);
    }
    final normalized = hue % 360;
    return normalized < 0 ? normalized + 360 : normalized;
  }

  // ---- CIE76 -----------------------------------------------------------------

  /// CIE L*a*b* coordinates (D65 white point, 2° observer).
  static _Lab _labOfRgb(({int r, int g, int b}) rgb) {
    final r = _linearize(rgb.r / 255.0);
    final g = _linearize(rgb.g / 255.0);
    final b = _linearize(rgb.b / 255.0);
    final x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047;
    final y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    final z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883;
    final fx = _labCurve(x);
    final fy = _labCurve(y);
    final fz = _labCurve(z);
    return _Lab(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
  }

  static double _linearize(double channel) => channel <= 0.04045
      ? channel / 12.92
      : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

  static double _labCurve(double t) => t > 0.008856
      ? math.pow(t, 1 / 3).toDouble()
      : 7.787 * t + 16 / 116;

  /// Euclidean distance in Lab space (CIE76 ΔE).
  static double _distanceLab(_Lab a, _Lab b) {
    final dl = a.l - b.l;
    final da = a.a - b.a;
    final db = a.b - b.b;
    return math.sqrt(dl * dl + da * da + db * db);
  }
}

/// Minimal Lab triple with a hex-entry constructor.
class _Lab {
  const _Lab(this.l, this.a, this.b);

  factory _Lab.fromHex(String hex) => CoursePalette._labOfRgb(
        CoursePalette._rgbOfHex(hex),
      );

  final double l;
  final double a;
  final double b;
}
