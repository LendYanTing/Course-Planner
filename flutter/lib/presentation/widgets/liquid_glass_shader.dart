import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Loads and parameterizes `shaders/liquid_glass.frag`, the liquid-glass
/// ImageFilter used by the floating bottom bar.
///
/// Uniform layout of the shader (float indices, sampler indices are separate):
/// 0,1 `uSize` and sampler 0 `uTexture` are both written by the engine when the
/// filter runs; this class only fills 2 `uCornerRadius`, 3 `uBezelWidth`,
/// 4 `uRefractStrength`, 5 `uChromaticAberration`, 6..9 `uTintColor` and
/// 10..13 `uBarRect`.
abstract final class LiquidGlassShader {
  /// Asset key declared under `flutter: shaders:` in pubspec.yaml.
  static const String asset = 'shaders/liquid_glass.frag';

  /// Created once so repeated [ensureLoaded] calls share a single load.
  static Future<ui.FragmentProgram?>? _programFuture;

  static ui.FragmentProgram? _program;

  /// Whether the current backend supports `ImageFilter.shader`
  /// (true on Impeller only).
  static bool get filtersSupported => ui.ImageFilter.isShaderFilterSupported;

  /// Whether the shader program loaded successfully.
  static bool get ready => _program != null;

  /// Loads the shader once; idempotent and never throws. A failed load keeps
  /// [ready] false so callers can fall back to a plain blur.
  static Future<void> ensureLoaded() async {
    final future = _programFuture ??= _load();
    await future;
  }

  static Future<ui.FragmentProgram?> _load() async {
    try {
      final program = await ui.FragmentProgram.fromAsset(asset);
      _program = program;
      return program;
    } catch (error) {
      debugPrint('LiquidGlassShader: unable to load $asset ($error)');
      return null;
    }
  }

  /// Builds the liquid glass filter, or null when the shader is unavailable,
  /// the backend cannot do shader filters, or the arguments are invalid.
  ///
  /// [barRect] and [cornerRadius] are logical pixels in screen coordinates and
  /// are converted with [devicePixelRatio]; the shader works in device pixels.
  static ui.ImageFilter? buildFilter({
    required Rect barRect,
    required double devicePixelRatio,
    required double cornerRadius,
    required Color tint,
    double bezelWidth = 18.0,
    double refractStrength = 0.03,
    double chromaticAberration = 0.004,
  }) {
    final program = _program;
    if (program == null || !filtersSupported) return null;

    final bool valid = barRect.left.isFinite &&
        barRect.top.isFinite &&
        barRect.width.isFinite &&
        barRect.height.isFinite &&
        barRect.width > 0 &&
        barRect.height > 0 &&
        cornerRadius.isFinite &&
        bezelWidth.isFinite &&
        refractStrength.isFinite &&
        chromaticAberration.isFinite &&
        devicePixelRatio.isFinite;
    if (!valid) return null;

    final double dpr = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    final double radiusPx = (cornerRadius < 0 ? 0.0 : cornerRadius) * dpr;
    final double bezelPx = (bezelWidth < 0 ? 0.0 : bezelWidth) * dpr;
    final Rect rectPx = Rect.fromLTWH(
      barRect.left * dpr,
      barRect.top * dpr,
      barRect.width * dpr,
      barRect.height * dpr,
    );

    try {
      final shader = program.fragmentShader();
      shader
        ..setFloat(2, radiusPx)
        ..setFloat(3, bezelPx)
        ..setFloat(4, refractStrength)
        ..setFloat(5, chromaticAberration)
        ..setFloat(6, tint.r)
        ..setFloat(7, tint.g)
        ..setFloat(8, tint.b)
        ..setFloat(9, tint.a)
        ..setFloat(10, rectPx.left)
        ..setFloat(11, rectPx.top)
        ..setFloat(12, rectPx.width)
        ..setFloat(13, rectPx.height);
      return ui.ImageFilter.shader(shader);
    } catch (error) {
      debugPrint('LiquidGlassShader: unable to build filter ($error)');
      return null;
    }
  }
}
