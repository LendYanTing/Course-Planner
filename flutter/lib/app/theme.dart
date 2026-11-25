import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';
import 'adaptive_page.dart';

/// Shape, surface and motion tokens for one UI engine. Widgets read them with
/// [AppStyleTokens.of] instead of branching on [UiVariant] themselves.
class AppStyleTokens extends ThemeExtension<AppStyleTokens> {
  const AppStyleTokens({
    required this.variant,
    required this.cardRadius,
    required this.cardRadiusSmall,
    required this.dialogRadius,
    required this.sheetRadius,
    required this.pillRadius,
    required this.buttonRadius,
    required this.useElevation,
    required this.cardElevation,
    required this.borderColor,
    required this.borderWidth,
    required this.groupSurface,
    required this.motionCurve,
    required this.spring,
    required this.topBarBlur,
    required this.topBarCenterTitle,
  });

  /// Engine these tokens describe.
  final UiVariant variant;

  // Shape, in logical pixels.
  final double cardRadius;
  final double cardRadiusSmall;
  final double dialogRadius;
  final double sheetRadius;
  final double pillRadius;
  final double buttonRadius;

  /// Surfaces: true when shadows are used instead of hairline borders.
  final bool useElevation;
  final double cardElevation;
  final Color borderColor;
  final double borderWidth;

  /// Background of a grouped list/section; null means "use the plain surface".
  final Color? groupSurface;

  /// Motion.
  final Curve motionCurve;
  final SpringDescription spring;

  /// Top bar behaviour.
  final bool topBarBlur;
  final bool topBarCenterTitle;

  /// Material 3 baseline. Brightness-dependent colours are filled in by
  /// [AppTheme] with [copyWith]; the transparent placeholder keeps the
  /// instance `const`.
  static const AppStyleTokens material3 = AppStyleTokens(
    variant: UiVariant.material3,
    cardRadius: 12,
    cardRadiusSmall: 8,
    dialogRadius: 28,
    sheetRadius: 28,
    pillRadius: 999,
    buttonRadius: 20,
    useElevation: true,
    cardElevation: 1,
    borderColor: Color(0x00000000),
    borderWidth: 0,
    groupSurface: null,
    motionCurve: Curves.easeInOutCubicEmphasized,
    spring: _spring,
    topBarBlur: false,
    topBarCenterTitle: false,
  );

  /// HyperOS: larger rounded corners, hairline borders instead of shadows and
  /// pill-shaped buttons. Colours are filled in by [AppTheme] per brightness.
  static const AppStyleTokens hyperOS = AppStyleTokens(
    variant: UiVariant.hyperOS,
    cardRadius: 20,
    cardRadiusSmall: 14,
    dialogRadius: 28,
    sheetRadius: 28,
    pillRadius: 999,
    buttonRadius: 999,
    useElevation: false,
    cardElevation: 0,
    borderColor: Color(0x00000000),
    borderWidth: 0.6,
    groupSurface: null,
    motionCurve: _hyperMotionCurve,
    spring: _spring,
    topBarBlur: true,
    topBarCenterTitle: false,
  );

  /// The tokens in effect for [context], falling back to Material 3 when the
  /// theme carries no extension (e.g. a bare [MaterialApp] in a test).
  static AppStyleTokens of(BuildContext context) =>
      Theme.of(context).extension<AppStyleTokens>() ?? material3;

  /// A [Curve] that follows the analytic step response of [spring]. The
  /// response is normalised so it maps 0 → 0 and 1 → 1 exactly while keeping
  /// the visible overshoot of a lightly damped spring.
  static Curve springCurve(SpringDescription spring) => _SpringCurve(spring);

  @override
  AppStyleTokens copyWith({
    UiVariant? variant,
    double? cardRadius,
    double? cardRadiusSmall,
    double? dialogRadius,
    double? sheetRadius,
    double? pillRadius,
    double? buttonRadius,
    bool? useElevation,
    double? cardElevation,
    Color? borderColor,
    double? borderWidth,
    Color? groupSurface,
    Curve? motionCurve,
    SpringDescription? spring,
    bool? topBarBlur,
    bool? topBarCenterTitle,
  }) {
    return AppStyleTokens(
      variant: variant ?? this.variant,
      cardRadius: cardRadius ?? this.cardRadius,
      cardRadiusSmall: cardRadiusSmall ?? this.cardRadiusSmall,
      dialogRadius: dialogRadius ?? this.dialogRadius,
      sheetRadius: sheetRadius ?? this.sheetRadius,
      pillRadius: pillRadius ?? this.pillRadius,
      buttonRadius: buttonRadius ?? this.buttonRadius,
      useElevation: useElevation ?? this.useElevation,
      cardElevation: cardElevation ?? this.cardElevation,
      borderColor: borderColor ?? this.borderColor,
      borderWidth: borderWidth ?? this.borderWidth,
      groupSurface: groupSurface ?? this.groupSurface,
      motionCurve: motionCurve ?? this.motionCurve,
      spring: spring ?? this.spring,
      topBarBlur: topBarBlur ?? this.topBarBlur,
      topBarCenterTitle: topBarCenterTitle ?? this.topBarCenterTitle,
    );
  }

  @override
  AppStyleTokens lerp(ThemeExtension<AppStyleTokens>? other, double t) {
    if (other is! AppStyleTokens) return this;
    final from = t < 0.5;
    return AppStyleTokens(
      variant: from ? variant : other.variant,
      cardRadius: _lerpDouble(cardRadius, other.cardRadius, t),
      cardRadiusSmall: _lerpDouble(cardRadiusSmall, other.cardRadiusSmall, t),
      dialogRadius: _lerpDouble(dialogRadius, other.dialogRadius, t),
      sheetRadius: _lerpDouble(sheetRadius, other.sheetRadius, t),
      pillRadius: _lerpDouble(pillRadius, other.pillRadius, t),
      buttonRadius: _lerpDouble(buttonRadius, other.buttonRadius, t),
      useElevation: from ? useElevation : other.useElevation,
      cardElevation: _lerpDouble(cardElevation, other.cardElevation, t),
      borderColor: Color.lerp(borderColor, other.borderColor, t) ?? borderColor,
      borderWidth: _lerpDouble(borderWidth, other.borderWidth, t),
      groupSurface: Color.lerp(groupSurface, other.groupSurface, t),
      motionCurve: from ? motionCurve : other.motionCurve,
      spring: from ? spring : other.spring,
      topBarBlur: from ? topBarBlur : other.topBarBlur,
      topBarCenterTitle: from ? topBarCenterTitle : other.topBarCenterTitle,
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppStyleTokens &&
        other.variant == variant &&
        other.cardRadius == cardRadius &&
        other.cardRadiusSmall == cardRadiusSmall &&
        other.dialogRadius == dialogRadius &&
        other.sheetRadius == sheetRadius &&
        other.pillRadius == pillRadius &&
        other.buttonRadius == buttonRadius &&
        other.useElevation == useElevation &&
        other.cardElevation == cardElevation &&
        other.borderColor == borderColor &&
        other.borderWidth == borderWidth &&
        other.groupSurface == groupSurface &&
        other.motionCurve == motionCurve &&
        other.spring == spring &&
        other.topBarBlur == topBarBlur &&
        other.topBarCenterTitle == topBarCenterTitle;
  }

  @override
  int get hashCode => Object.hash(
        variant,
        cardRadius,
        cardRadiusSmall,
        dialogRadius,
        sheetRadius,
        pillRadius,
        buttonRadius,
        useElevation,
        cardElevation,
        borderColor,
        borderWidth,
        groupSurface,
        motionCurve,
        spring,
        topBarBlur,
        topBarCenterTitle,
      );
}

const SpringDescription _spring =
    SpringDescription(mass: 1, stiffness: 360, damping: 26);
const Curve _hyperMotionCurve = _SpringCurve(_spring);

/// Damped-spring curve: a normalised analytic step response, sampled every
/// frame instead of a lookup table. Falling back to a linear curve for
/// degenerate springs keeps it total.
class _SpringCurve extends Curve {
  const _SpringCurve(this.spring);

  final SpringDescription spring;

  @override
  double transformInternal(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final mass = spring.mass <= 0 ? 1.0 : spring.mass;
    final stiffness = spring.stiffness <= 0 ? 1.0 : spring.stiffness;
    final damping = spring.damping < 0 ? 0.0 : spring.damping;
    final omega0 = math.sqrt(stiffness / mass);
    final zeta = damping / (2 * math.sqrt(stiffness * mass));
    // Six time constants: the residual displacement is <0.3% of the travel,
    // so normalising by the end value does not change the feel.
    final duration = zeta <= 0
        ? 1.0
        : (6.0 / (zeta * omega0)).clamp(0.15, 2.0).toDouble();
    final end = _step(duration, omega0, zeta);
    if (!end.isFinite || end <= 0) return t;
    final value = _step(t * duration, omega0, zeta) / end;
    if (!value.isFinite) return t;
    return value;
  }

  /// Step response of `x'' + 2ζω₀x' + ω₀²x = ω₀²` from rest at x = 0.
  static double _step(double s, double omega0, double zeta) {
    if (zeta < 1) {
      final omegaD = omega0 * math.sqrt(1 - zeta * zeta);
      final decay = math.exp(-zeta * omega0 * s);
      return 1 -
          decay *
              (math.cos(omegaD * s) +
                  (zeta * omega0 / omegaD) * math.sin(omegaD * s));
    }
    if (zeta == 1) {
      final decay = math.exp(-omega0 * s);
      return 1 - decay * (1 + omega0 * s);
    }
    final root = omega0 * math.sqrt(zeta * zeta - 1);
    final r1 = -zeta * omega0 + root;
    final r2 = -zeta * omega0 - root;
    return 1 -
        (r2 * math.exp(r1 * s) - r1 * math.exp(r2 * s)) / (r2 - r1);
  }
}

/// Material 3 / HyperOS theme pair. Event colours come from the server
/// (`color` fields); this file defines the neutral shell, shared component
/// styles and the cross-platform font stack so CJK glyphs render consistently.
abstract class AppTheme {
  static const seed = Color(0xFF3F51B5);

  /// [scheme] replaces the seeded scheme (Monet / user-picked seed); the
  /// tokens, font stack and component styles are unchanged.
  static ThemeData light([
    UiVariant variant = UiVariant.material3,
    ColorScheme? scheme,
  ]) =>
      _base(Brightness.light, variant, scheme);

  static ThemeData dark([
    UiVariant variant = UiVariant.material3,
    ColorScheme? scheme,
  ]) =>
      _base(Brightness.dark, variant, scheme);

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

  static ThemeData _base(
    Brightness brightness,
    UiVariant variant, [
    ColorScheme? scheme,
  ]) {
    final isHyper = variant == UiVariant.hyperOS;
    final seeded = scheme ??
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    final effective = isHyper ? _hyperScheme(seeded, brightness) : seeded;
    final tokens = isHyper
        ? AppStyleTokens.hyperOS.copyWith(
            borderColor: brightness == Brightness.light
                ? Colors.white.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.10),
            groupSurface: brightness == Brightness.light
                ? const Color(0xFFF7F8FA)
                : const Color(0xFF141416),
          )
        : AppStyleTokens.material3;
    final fontFamily = _fontFamilyForPlatform();
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: effective,
      scaffoldBackgroundColor: isHyper
          ? (brightness == Brightness.light
              ? const Color(0xFFF2F3F5)
              : const Color(0xFF000000))
          : effective.surface,
      appBarTheme: isHyper
          ? AppBarTheme(
              centerTitle: tokens.topBarCenterTitle,
              backgroundColor: Colors.transparent,
              elevation: 0,
              scrolledUnderElevation: 0,
              titleTextStyle: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: effective.onSurface,
              ),
            )
          : AppBarTheme(
              centerTitle: false,
              backgroundColor: effective.surface,
              elevation: 0,
            ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      cardTheme: CardThemeData(
        color: effective.surfaceContainerLow,
        elevation: tokens.cardElevation,
        surfaceTintColor: isHyper ? Colors.transparent : null,
        shape: _cardShape(tokens),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: effective.surfaceContainerHigh,
        elevation: isHyper ? 0 : 6,
        shape: isHyper
            ? RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(tokens.dialogRadius),
              )
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(tokens.dialogRadius),
              ),
      ),
      bottomSheetTheme: isHyper
          ? BottomSheetThemeData(
              backgroundColor: effective.surface,
              elevation: 0,
              showDragHandle: false,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(tokens.sheetRadius),
              ),
            )
          : BottomSheetThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(tokens.sheetRadius),
                ),
              ),
            ),
      pageTransitionsTheme: isHyper
          ? const PageTransitionsTheme(
              builders: <TargetPlatform, PageTransitionsBuilder>{
                TargetPlatform.android: HyperOsPageTransitionsBuilder(),
                TargetPlatform.fuchsia: HyperOsPageTransitionsBuilder(),
                TargetPlatform.linux: HyperOsPageTransitionsBuilder(),
                TargetPlatform.windows: HyperOsPageTransitionsBuilder(),
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
                TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
              },
            )
          : null,
      extensions: <ThemeExtension<dynamic>>[tokens],
    );
    if (fontFamily == null) return base;
    // Spread the family over every text style so mixed scripts never fall
    // back to different fonts mid-string.
    final all = base.textTheme.apply(fontFamily: fontFamily);
    return base.copyWith(
      textTheme: all,
      primaryTextTheme: all,
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle:
            base.appBarTheme.titleTextStyle?.copyWith(fontFamily: fontFamily),
      ),
    );
  }

  /// HyperOS surface ladder: a grey canvas with white sheets in light mode and
  /// a black canvas with near-black cards in dark mode. Accent colours still
  /// come from the seeded scheme.
  static ColorScheme _hyperScheme(ColorScheme scheme, Brightness brightness) {
    if (brightness == Brightness.light) {
      return scheme.copyWith(
        surface: const Color(0xFFFFFFFF),
        surfaceDim: const Color(0xFFE6E7EA),
        surfaceBright: const Color(0xFFFFFFFF),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFFFFFFF),
        surfaceContainer: const Color(0xFFF7F8FA),
        surfaceContainerHigh: const Color(0xFFFFFFFF),
        surfaceContainerHighest: const Color(0xFFEDEEF1),
        outline: const Color(0xFFC9CBD1),
        outlineVariant: const Color(0xFFE1E3E8),
      );
    }
    return scheme.copyWith(
      surface: const Color(0xFF1C1C1E),
      surfaceDim: const Color(0xFF000000),
      surfaceBright: const Color(0xFF2C2C2E),
      surfaceContainerLowest: const Color(0xFF000000),
      surfaceContainerLow: const Color(0xFF1C1C1E),
      surfaceContainer: const Color(0xFF1C1C1E),
      surfaceContainerHigh: const Color(0xFF242426),
      surfaceContainerHighest: const Color(0xFF2C2C2E),
      outline: const Color(0xFF48484A),
      outlineVariant: const Color(0xFF38383A),
    );
  }

  static ShapeBorder _cardShape(AppStyleTokens tokens) {
    final radius = BorderRadius.circular(tokens.cardRadius);
    if (tokens.variant == UiVariant.hyperOS) {
      return RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: tokens.borderColor, width: tokens.borderWidth),
      );
    }
    return RoundedRectangleBorder(borderRadius: radius);
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

/// Seeded scheme for a user-picked `#RRGGBB` seed, used when Monet is off or
/// has no wallpaper to work with. Cached per seed+brightness so the root widget
/// does not re-run the quantizer on every rebuild.
final seedColorSchemeProvider =
    Provider.family<ColorScheme, ({String hex, Brightness brightness})>(
  (ref, arg) => ColorScheme.fromSeed(
    seedColor: AppTheme.parseHex(arg.hex) ?? AppTheme.seed,
    brightness: arg.brightness,
  ),
);

/// Material You scheme extracted from the wallpaper at `path`.
///
/// The extraction is Flutter's own [ColorScheme.fromImageProvider], i.e. the
/// Material Color Utilities `QuantizerCelebi` + `Score` pipeline (the same one
/// the `dynamic_color` package wraps), so no extra dependency or native plugin
/// is involved and Windows/Android behave identically.
///
/// Returns null when there is no readable image (missing file, unsupported
/// format, decode failure); callers then fall back to
/// [seedColorSchemeProvider]. Results are cached per path+brightness while
/// something watches this provider (the app root does).
final wallpaperColorSchemeProvider = FutureProvider.autoDispose
    .family<ColorScheme?, ({String path, Brightness brightness})>(
        (ref, arg) async {
  try {
    final file = File(arg.path);
    if (!await file.exists()) return null;
    return await ColorScheme.fromImageProvider(
      provider: FileImage(file),
      brightness: arg.brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
  } on Object {
    // Missing, unreadable or undecodable file: the seed scheme stays in use.
    return null;
  }
});
