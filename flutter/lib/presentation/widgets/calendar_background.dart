import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/prefs.dart';

/// The four built-in gradient wallpapers. They need no asset bundle: each is
/// painted from a `LinearGradient`/`RadialGradient` (plus a hairline grid for
/// the minimalist one), so they work on every platform and cannot fail to load.
const kCalendarWallpaperPresets = <({String id, String label})>[
  (id: 'aurora', label: '晨曦极光'),
  (id: 'lotus', label: '莫奈睡莲'),
  (id: 'nebula', label: '深海星云'),
  (id: 'grid', label: '极简网格'),
];

/// Key of the gradient painted for a built-in preset. Exposed so tests and the
/// settings preview can find the layer without depending on widget internals.
const calendarBackgroundPresetKey = ValueKey<String>(
  'calendar-background-preset',
);

/// Key of the gradient drawn when a configured image path cannot be read.
const calendarBackgroundFallbackKey = ValueKey<String>(
  'calendar-background-fallback',
);

/// Paints the user's background wallpaper behind a page.
///
/// The widget is transparent to the rest of the tree: with no background
/// configured it returns [child] untouched. Otherwise it stacks the wallpaper
/// (local image or preset gradient), the readability scrim and [child], in that
/// order. The page itself must be transparent (its `Scaffold` background) for
/// the wallpaper to show through.
class CalendarBackground extends ConsumerWidget {
  const CalendarBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(backgroundConfigProvider);
    if (!config.hasBackground) return child;

    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        _BackgroundLayer(config: config),
        if (config.scrimOpacity > 0)
          // The scrim only tints; taps must reach the page under it.
          IgnorePointer(
            child: ColoredBox(
              color: scheme.surface.withValues(alpha: config.scrimOpacity),
            ),
          ),
        child,
      ],
    );
  }

  /// The wallpaper + scrim stack alone, for the appearance page's live preview.
  ///
  /// Unlike [CalendarBackground] it does not depend on providers: the caller
  /// passes the config being edited. A page with no background shows a neutral
  /// surface so the preview is never blank.
  static Widget previewFor(
    BuildContext context,
    BackgroundConfig config, {
    double height = 120,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final Widget content;
    if (config.hasBackground) {
      content = Stack(
        fit: StackFit.expand,
        children: [
          _BackgroundLayer(config: config),
          if (config.scrimOpacity > 0)
            IgnorePointer(
              child: ColoredBox(
                color: scheme.surface.withValues(alpha: config.scrimOpacity),
              ),
            ),
        ],
      );
    } else {
      content = ColoredBox(color: scheme.surfaceContainerHighest);
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: content,
    );
  }

  /// Gradient of a built-in preset for the given theme brightness.
  ///
  /// Dark mode dims every preset so a bright wallpaper never washes out the
  /// dark scheme's text. The settings page reuses this for its thumbnails.
  static BoxDecoration presetDecoration(BuildContext context, String id) {
    final brightness = Theme.of(context).brightness;
    final scheme = Theme.of(context).colorScheme;

    Color dim(Color color) => brightness == Brightness.dark
        ? Color.lerp(color, Colors.black, 0.3)!
        : color;

    switch (id) {
      case 'aurora':
        // Dawn over a polar sky: deep indigo, violet, then peach.
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            stops: const [0, 0.36, 0.7, 1],
            colors: [
              dim(const Color(0xFF16214F)),
              dim(const Color(0xFF7E57C2)),
              dim(const Color(0xFFFF9E9E)),
              dim(const Color(0xFFFFD9A8)),
            ],
          ),
        );
      case 'lotus':
        // Impressionist water lilies: cream light fading into sage and teal.
        return BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.55, -0.7),
            radius: 1.5,
            stops: const [0, 0.34, 0.68, 1],
            colors: [
              dim(const Color(0xFFF7F1E6)),
              dim(const Color(0xFFC3DCCB)),
              dim(const Color(0xFF8FB9B4)),
              dim(const Color(0xFF5C7F88)),
            ],
          ),
        );
      case 'nebula':
        // Deep-sea nebula: a teal glow above indigo depth.
        return BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.5, -0.6),
            radius: 1.45,
            stops: const [0, 0.28, 0.62, 1],
            colors: [
              dim(const Color(0xFF6FC6D8)),
              dim(const Color(0xFF1F5C74)),
              dim(const Color(0xFF1A2A55)),
              dim(const Color(0xFF05070F)),
            ],
          ),
        );
      case 'grid':
        // A near-neutral canvas; `_PresetWallpaper` draws the grid lines.
        final colors = brightness == Brightness.dark
            ? const [Color(0xFF14161B), Color(0xFF232833)]
            : const [Color(0xFFF7F8FA), Color(0xFFE2E7EF)];
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: colors,
          ),
        );
      default:
        return BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.surfaceContainerHighest, scheme.surface],
          ),
        );
    }
  }
}

/// The wallpaper itself: a local image, a preset gradient or a theme fallback.
class _BackgroundLayer extends StatelessWidget {
  const _BackgroundLayer({required this.config});

  /// Below this sigma the blur is invisible, so the extra layer is skipped.
  static const double _blurThreshold = 0.1;

  final BackgroundConfig config;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final path = config.imagePath;
    if (path != null && path.isNotEmpty) {
      // A stale path (file moved or deleted) falls back like a failed decode
      // instead of leaving an empty hole in the page.
      if (!_fileExists(path)) return _FallbackGradient(scheme: scheme);
      final image = Image.file(
        File(path),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) =>
            _FallbackGradient(scheme: scheme),
      );
      if (config.blurSigma <= _blurThreshold) return image;
      // Blurring without overscan fades the wallpaper's outer edge to
      // transparent; scaling the blurred layer up pushes that edge out of view.
      // Preset gradients are not blurred: an `ImageFilter` cannot sample a
      // painted decoration, and they are already soft by design.
      return Transform.scale(
        scale: 1.08,
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: config.blurSigma,
            sigmaY: config.blurSigma,
          ),
          child: image,
        ),
      );
    }

    final preset = config.presetId;
    if (preset != null && preset.isNotEmpty) return _PresetWallpaper(id: preset);

    return _FallbackGradient(scheme: scheme);
  }

  static bool _fileExists(String path) {
    try {
      return File(path).existsSync();
    } on Object {
      return false;
    }
  }
}

/// A built-in gradient, with the hairline grid on top of the minimalist preset.
class _PresetWallpaper extends StatelessWidget {
  const _PresetWallpaper({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final gradient = DecoratedBox(
      key: calendarBackgroundPresetKey,
      decoration: CalendarBackground.presetDecoration(context, id),
    );
    if (id != 'grid') return gradient;

    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        gradient,
        IgnorePointer(
          child: CustomPaint(
            painter: _GridPainter(
              color: dark ? const Color(0x14FFFFFF) : const Color(0x12000000),
            ),
          ),
        ),
      ],
    );
  }
}

/// Fallback for a missing image: a quiet surface gradient so the page keeps a
/// sensible backdrop instead of showing the raw scaffold colour.
class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: calendarBackgroundFallbackKey,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.surfaceContainerHighest, scheme.surface],
        ),
      ),
    );
  }
}

/// Hairline grid for the 极简网格 wallpaper.
class _GridPainter extends CustomPainter {
  const _GridPainter({required this.color});

  static const double _step = 28;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 0.6;
    for (var x = _step; x < size.width; x += _step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = _step; y < size.height; y += _step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => oldDelegate.color != color;
}
