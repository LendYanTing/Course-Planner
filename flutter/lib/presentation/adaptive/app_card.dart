import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

/// Surface used for tappable/informational blocks, adapting to the active
/// [UiVariant].
///
/// * MD3: an elevated [Card] with a rounded rectangle shape.
/// * HyperOS: no elevation at all — a superellipse-clipped surface with a
///   hairline highlight border, and a press-scale instead of a shadow.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = AppStyleTokens.of(context);
    if (tokens.variant != UiVariant.hyperOS) return _material(tokens);
    return _hyper(context, tokens);
  }

  Widget _material(AppStyleTokens tokens) {
    final radius = BorderRadius.circular(tokens.cardRadius);
    return Card(
      margin: margin,
      color: color,
      elevation: tokens.cardElevation,
      shape: RoundedRectangleBorder(borderRadius: radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }

  Widget _hyper(BuildContext context, AppStyleTokens tokens) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(tokens.cardRadius);
    final surface = ClipRSuperellipse(
      borderRadius: radius,
      child: Material(
        color: color ?? scheme.surfaceContainerHigh,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    return Container(
      margin: margin,
      child: _PressScale(
        enabled: onTap != null,
        child: Stack(
          children: [
            surface,
            // Hairline highlight drawn over the clipped surface: painting it
            // behind the clip would hide half of a sub-pixel stroke.
            if (tokens.borderWidth > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      border: Border.all(
                        color: tokens.borderColor,
                        width: tokens.borderWidth,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shrinks its child slightly while a pointer is down.
///
/// Only competes for taps when the card is tappable; the [InkWell] inside the
/// card still owns the actual tap and its ripple.
class _PressScale extends StatefulWidget {
  const _PressScale({required this.child, required this.enabled});

  final Widget child;
  final bool enabled;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!widget.enabled || _pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(_PressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _pressed) _pressed = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final tokens = AppStyleTokens.of(context);
    return GestureDetector(
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.98 : 1,
        duration: const Duration(milliseconds: 180),
        curve: tokens.motionCurve,
        child: widget.child,
      ),
    );
  }
}
