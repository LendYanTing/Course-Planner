import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

/// On/off control that matches the active [UiVariant].
///
/// * MD3: the platform [Switch].
/// * HyperOS: a hand-drawn pill whose thumb is driven by a spring, so toggling
///   settles with a tiny overshoot instead of a fixed-duration tween.
class AppSwitch extends StatefulWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> with SingleTickerProviderStateMixin {
  // HyperOS track metrics (logical pixels).
  static const double _width = 52;
  static const double _height = 32;
  static const double _thumb = 26;
  static const double _inset = 3;
  static const double _travel = _width - _thumb - _inset * 2;

  /// Unbounded: 0 = off, 1 = on, may overshoot while the spring settles.
  late final AnimationController _position;

  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(
      vsync: this,
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AppSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    final tokens = AppStyleTokens.of(context);
    if (tokens.variant != UiVariant.hyperOS) return;
    _position.animateWith(
      SpringSimulation(
        tokens.spring,
        _position.value,
        widget.value ? 1 : 0,
        _position.velocity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppStyleTokens.of(context);
    if (tokens.variant != UiVariant.hyperOS) {
      return Switch(
        value: widget.value,
        onChanged: widget.onChanged,
        activeThumbColor: widget.activeColor,
      );
    }
    return _buildHyper(context, tokens);
  }

  Widget _buildHyper(BuildContext context, AppStyleTokens tokens) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.activeColor ?? scheme.primary;
    return Semantics(
      toggled: widget.value,
      child: GestureDetector(
        onTap: () => widget.onChanged(!widget.value),
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: SizedBox(
          width: _width,
          height: _height,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: tokens.motionCurve,
            decoration: BoxDecoration(
              color: widget.value
                  ? active
                  : scheme.onSurface.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(_height / 2),
            ),
            child: AnimatedBuilder(
              animation: _position,
              builder: (context, child) => Stack(
                children: [
                  Positioned(
                    left: _inset + _position.value.clamp(0.0, 1.0) * _travel,
                    top: _inset,
                    child: child!,
                  ),
                ],
              ),
              child: AnimatedScale(
                scale: _pressed ? 0.9 : 1,
                duration: const Duration(milliseconds: 140),
                curve: tokens.motionCurve,
                child: Container(
                  width: _thumb,
                  height: _thumb,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
