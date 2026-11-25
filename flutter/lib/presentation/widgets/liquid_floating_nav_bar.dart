import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/prefs.dart';
import 'liquid_glass_shader.dart';

/// One destination of the floating bar.
class LiquidNavItem {
  const LiquidNavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// Floating, translucent navigation bar ("liquid glass").
///
/// Sits above the page content instead of occupying a slab at the bottom: the
/// surrounding [Scaffold] sets `extendBody: true`, so lists scroll underneath
/// and are refracted/blurred through the capsule.
///
/// Three materials, picked in Settings ([bottomBarStyleProvider]):
/// * [BottomBarStyle.liquidGlass] — `ImageFilter.shader` (refraction + dispersion).
///   Only Impeller implements shader filters; everywhere else — and until the
///   program finishes loading — this silently falls back to frosted blur.
/// * [BottomBarStyle.frostedBlur] — plain `ImageFilter.blur` + rim highlight.
/// * [BottomBarStyle.solidCapsule] — flat tint, no offscreen blur (low power).
///
/// The selection indicator is spring driven: it flies to a tapped tab and can
/// be dragged horizontally, stretching like jelly with its own velocity.
class LiquidFloatingNavBar extends ConsumerStatefulWidget {
  const LiquidFloatingNavBar({
    super.key,
    required this.currentIndex,
    required this.items,
    required this.onSelected,
  });

  final int currentIndex;
  final List<LiquidNavItem> items;
  final ValueChanged<int> onSelected;

  /// Capsule height (logical pixels), without the safe-area / gap padding.
  static const double capsuleHeight = 54;

  /// Side margins that make the bar "float".
  static const double sideInset = 20;

  /// Widest the capsule grows: on tablets / landscape it stays a compact pill
  /// centred in the width left by [sideInset] instead of stretching edge to
  /// edge. Narrower screens still fill that width.
  static const double maxCapsuleWidth = 360;

  /// Corner radius of the capsule (superellipse corner).
  static const double cornerRadius = 27;

  /// Gap between the capsule and the system navigation area.
  static const double bottomGap = 8;

  /// Extra room the backdrop filter is given on each side. A backdrop filter
  /// only receives the pixels inside its own bounds; blurring right up to the
  /// capsule edge would therefore mix in transparent black and leave a grey
  /// halo. Padding the layer gives the blur real content to sample, and the
  /// superellipse clip trims the excess.
  static const double blurPad = 28;

  @override
  ConsumerState<LiquidFloatingNavBar> createState() => _LiquidFloatingNavBarState();
}

class _LiquidFloatingNavBarState extends ConsumerState<LiquidFloatingNavBar>
    with SingleTickerProviderStateMixin {
  /// Unbounded so the value is a (fractional) tab index: `1.0` = second tab.
  late final AnimationController _indicator;

  /// The tab the spring is currently heading for; avoids restarting the spring
  /// when the parent reports the index change our own tap already started.
  late int _target;

  bool _dragging = false;

  /// Cached filter, rebuilt only when its inputs change. A fresh
  /// `ImageFilter.shader` per frame would defeat BackdropFilter's equality
  /// check and repaint the whole band every tick.
  Object? _filterKey;
  ui.ImageFilter? _filter;

  static const _spring = SpringDescription(mass: 1, stiffness: 380, damping: 24);

  @override
  void initState() {
    super.initState();
    _target = widget.currentIndex;
    _indicator = AnimationController.unbounded(
      vsync: this,
      value: widget.currentIndex.toDouble(),
    );
    // First frame uses the blur fallback; the glass appears as soon as the
    // program is ready (no flash of an empty capsule).
    LiquidGlassShader.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _indicator.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(LiquidFloatingNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentIndex != oldWidget.currentIndex) _springTo(widget.currentIndex);
  }

  void _springTo(int index, {double velocity = 0}) {
    // Compare against the previous target *before* overwriting it: tapping a
    // second tab mid-flight must re-aim the spring instead of being ignored.
    final alreadyHeadingThere = _indicator.isAnimating && _target == index;
    _target = index;
    final target = index.toDouble();
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _indicator.value = target;
      return;
    }
    if (alreadyHeadingThere && velocity == 0) return;
    if ((_indicator.value - target).abs() < 0.001 && velocity.abs() < 0.01) {
      _indicator.value = target;
      return;
    }
    _indicator.animateWith(
      SpringSimulation(_spring, _indicator.value, target, velocity),
    );
  }

  void _select(int index) {
    if (index == widget.currentIndex) return;
    HapticFeedback.selectionClick();
    _springTo(index);
    widget.onSelected(index);
  }

  /// Maps a horizontal offset inside the capsule to a (fractional) tab index.
  ///
  /// The indicator is centred on its cell, so an offset at the centre of cell
  /// `i` (i.e. `(i + 0.5) * itemWidth`) must map to exactly `i` — hence the
  /// half-cell shift.
  double _indexAt(double dx, double itemWidth) {
    if (itemWidth <= 0) return widget.currentIndex.toDouble();
    final n = widget.items.length;
    return ((dx / itemWidth) - 0.5).clamp(0.0, (n - 1).toDouble());
  }

  void _onDragStart(DragStartDetails details, double itemWidth) {
    // Taps still win the arena (a drag needs movement), so the bar stays
    // tappable while this recogniser is registered.
    _dragging = true;
    _indicator.stop();
    setState(() {});
    _onDragUpdate(DragUpdateDetails(
      globalPosition: details.globalPosition,
      localPosition: details.localPosition,
      delta: Offset.zero,
      primaryDelta: 0,
    ), itemWidth);
  }

  void _onDragUpdate(DragUpdateDetails details, double itemWidth) {
    if (!_dragging) return;
    _indicator.value = _indexAt(details.localPosition.dx, itemWidth);
  }

  void _onDragEnd(double itemWidth) {
    if (!_dragging) return;
    final index = _indicator.value.round().clamp(0, widget.items.length - 1);
    final velocity = _indicator.velocity;
    setState(() => _dragging = false);
    _springTo(index, velocity: velocity);
    if (index != widget.currentIndex) {
      HapticFeedback.selectionClick();
      widget.onSelected(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = ref.watch(bottomBarStyleProvider);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final itemCount = widget.items.length;

    // The liquid path needs the shader program *and* an Impeller backend.
    final effective = style == BottomBarStyle.liquidGlass &&
            (!LiquidGlassShader.ready || !LiquidGlassShader.filtersSupported)
        ? BottomBarStyle.frostedBlur
        : style;

    final tint = (dark ? const Color(0xFF1A1B20) : Colors.white)
        .withValues(alpha: dark ? 0.34 : 0.30);

    return Padding(
      padding: EdgeInsets.only(
        left: LiquidFloatingNavBar.sideInset,
        right: LiquidFloatingNavBar.sideInset,
        bottom: safeBottom + LiquidFloatingNavBar.bottomGap,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: LiquidFloatingNavBar.maxCapsuleWidth,
          ),
          child: SizedBox(
            height: LiquidFloatingNavBar.capsuleHeight,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final itemWidth = width / itemCount;
                // The filter's own coordinate space starts at the (padded)
                // layer's top-left, so the capsule is described locally rather
                // than in screen coordinates.
                final localRect = Rect.fromLTWH(
                  LiquidFloatingNavBar.blurPad,
                  LiquidFloatingNavBar.blurPad,
                  width,
                  LiquidFloatingNavBar.capsuleHeight,
                );

                return Stack(
                  children: [
                    // Soft drop shadow only. Anything else painted here would end
                    // up in the BackdropFilter's *input*, i.e. the glass would
                    // refract our own decorations instead of the page behind it
                    // (a filled backing used to paint the bar as a white slab).
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                              LiquidFloatingNavBar.cornerRadius),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: dark ? 0.30 : 0.08),
                              blurRadius: 24,
                              spreadRadius: -10,
                              offset: const Offset(0, 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: ClipRSuperellipse(
                        borderRadius: BorderRadius.circular(
                            LiquidFloatingNavBar.cornerRadius),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned(
                              left: -LiquidFloatingNavBar.blurPad,
                              top: -LiquidFloatingNavBar.blurPad,
                              right: -LiquidFloatingNavBar.blurPad,
                              bottom: -LiquidFloatingNavBar.blurPad,
                              child: _material(effective, localRect, dpr, tint, scheme),
                            ),
                            // Faint top sheen so the surface reads as glass even
                            // when the content behind it is flat.
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.white.withValues(alpha: dark ? 0.10 : 0.18),
                                      Colors.white.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Rim highlight on top of the glass: a gradient stroke that
                    // must not sit behind it (see the shadow note above).
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _RimPainter(
                            top: Colors.white.withValues(alpha: dark ? 0.38 : 0.95),
                            bottom: Colors.white.withValues(alpha: dark ? 0.06 : 0.20),
                          ),
                        ),
                      ),
                    ),
                    // Indicator below the icons, so glyphs stay crisp on top.
                    AnimatedBuilder(
                      animation: _indicator,
                      builder: (context, _) {
                        final velocity = _indicator.velocity;
                        final stretch = (velocity.abs() * 0.06).clamp(0.0, 0.20);
                        final squash = (velocity.abs() * 0.03).clamp(0.0, 0.10);
                        final left = _indicator.value.clamp(0.0, (itemCount - 1).toDouble());
                        return Positioned(
                          left: left * itemWidth + 6,
                          top: 5,
                          width: itemWidth - 12,
                          height: LiquidFloatingNavBar.capsuleHeight - 10,
                          child: IgnorePointer(
                            child: Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.diagonal3Values(
                                1 + stretch,
                                1 - squash,
                                1,
                              ),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                      LiquidFloatingNavBar.cornerRadius - 6),
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      scheme.primary.withValues(alpha: dark ? 0.55 : 0.22),
                                      scheme.primary.withValues(alpha: dark ? 0.32 : 0.10),
                                    ],
                                  ),
                                  border: Border.all(
                                    color: scheme.primary.withValues(alpha: dark ? 0.45 : 0.25),
                                    width: 0.8,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) =>
                            _select(_indexAt(details.localPosition.dx, itemWidth).round()),
                        onHorizontalDragStart: (d) => _onDragStart(d, itemWidth),
                        onHorizontalDragUpdate: (d) => _onDragUpdate(d, itemWidth),
                        onHorizontalDragEnd: (_) => _onDragEnd(itemWidth),
                        onHorizontalDragCancel: () {
                          if (!_dragging) return;
                          setState(() => _dragging = false);
                          _springTo(widget.currentIndex);
                        },
                        child: Row(
                          children: [
                            for (var i = 0; i < itemCount; i++)
                              Expanded(
                                child: Semantics(
                                  button: true,
                                  selected: i == widget.currentIndex,
                                  label: widget.items[i].label,
                                  child: _BarItem(
                                    item: widget.items[i],
                                    selected: i == widget.currentIndex,
                                    color: i == widget.currentIndex
                                        ? (dark ? Colors.white : scheme.primary)
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The translucent material behind the icons.
  Widget _material(
    BottomBarStyle style,
    Rect barRect,
    double dpr,
    Color tint,
    ColorScheme scheme,
  ) {
    switch (style) {
      case BottomBarStyle.solidCapsule:
        // Still slightly translucent so the capsule reads as "floating".
        return ColoredBox(color: Color.alphaBlend(tint, scheme.surface));
      case BottomBarStyle.liquidGlass:
        final filter = _shaderFilter(barRect, dpr, tint);
        if (filter == null) {
          // Late failure (e.g. the backend rejected the filter): keep the bar
          // usable instead of throwing during paint.
          return _frosted(tint);
        }
        // The shader already mixes the tint and the edge highlight; the blur is
        // composed *underneath* it so the refraction acts on frosted content
        // (a pure shader pass would leave the text behind razor sharp).
        return BackdropFilter(filter: filter, child: const SizedBox.expand());
      case BottomBarStyle.frostedBlur:
        return _frosted(tint);
    }
  }

  Widget _frosted(Color tint) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: ColoredBox(color: tint),
      );

  ui.ImageFilter? _shaderFilter(Rect barRect, double dpr, Color tint) {
    final key = Object.hash(
      barRect,
      dpr,
      LiquidFloatingNavBar.cornerRadius,
      tint,
      Theme.of(context).brightness,
    );
    if (_filterKey == key) return _filter;
    _filterKey = key;
    final shader = LiquidGlassShader.buildFilter(
      barRect: barRect,
      devicePixelRatio: dpr,
      cornerRadius: LiquidFloatingNavBar.cornerRadius,
      tint: tint,
    );
    // Frost first, then refract what is already blurred: `outer` runs last.
    _filter = shader == null
        ? null
        : ui.ImageFilter.compose(
            outer: shader,
            inner: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          );
    return _filter;
  }
}

/// Hairline rim highlight painted on top of the glass: bright along the top,
/// fading towards the bottom, following the superellipse outline.
class _RimPainter extends CustomPainter {
  const _RimPainter({required this.top, required this.bottom});

  final Color top;
  final Color bottom;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final path = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(LiquidFloatingNavBar.cornerRadius),
    ).getOuterPath(rect);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [top, bottom],
      ).createShader(rect);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_RimPainter oldDelegate) =>
      oldDelegate.top != top || oldDelegate.bottom != bottom;
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.item,
    required this.selected,
    required this.color,
  });

  final LiquidNavItem item;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(selected ? item.selectedIcon : item.icon, size: 20, color: color),
        const SizedBox(height: 2),
        Text(
          item.label,
          maxLines: 1,
          style: TextStyle(
            fontSize: 10,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }
}
