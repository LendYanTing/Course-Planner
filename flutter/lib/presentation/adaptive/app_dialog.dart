import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

/// Shows a dialog that matches the active [UiVariant].
///
/// * MD3: the platform default [AlertDialog].
/// * HyperOS: a centered superellipse card on wide screens, a bottom-docked
///   sheet on phones.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required String title,
  required Widget content,
  List<Widget> actions = const [],
  bool barrierDismissible = true,
}) {
  final tokens = AppStyleTokens.of(context);
  if (tokens.variant != UiVariant.hyperOS) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: content,
        actions: actions,
      ),
    );
  }

  final desktop = MediaQuery.sizeOf(context).width >= 600;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    transitionDuration: const Duration(milliseconds: 300),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      // The theme's motion curve is spring-shaped and overshoots 1, so both the
      // opacity and the 15px slide are clamped to the visible range.
      final curve = CurveTween(curve: tokens.motionCurve);
      return AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = curve.transform(animation.value).clamp(0.0, 1.0);
          return Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 15 * (1 - t)),
              child: child,
            ),
          );
        },
        child: child,
      );
    },
    pageBuilder: (context, animation, secondaryAnimation) {
      final panel = _HyperDialogPanel(
        tokens: tokens,
        title: title,
        content: content,
        actions: actions,
        desktop: desktop,
      );
      if (desktop) {
        return Center(
          child: SizedBox(width: 420, child: panel),
        );
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: panel,
        ),
      );
    },
  );
}

/// HyperOS dialog body: a flat superellipse surface with a hairline border.
class _HyperDialogPanel extends StatelessWidget {
  const _HyperDialogPanel({
    required this.tokens,
    required this.title,
    required this.content,
    required this.actions,
    required this.desktop,
  });

  final AppStyleTokens tokens;
  final String title;
  final Widget content;
  final List<Widget> actions;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(tokens.dialogRadius);
    final titleStyle = (theme.textTheme.titleMedium ?? const TextStyle()).copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );

    final panel = ClipRSuperellipse(
      borderRadius: radius,
      child: Material(
        color: scheme.surfaceContainerHigh,
        child: Padding(
          padding: desktop
              ? const EdgeInsets.fromLTRB(24, 24, 24, 20)
              : const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!desktop) ...[
                // Grabber: purely decorative on a docked dialog.
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
              ],
              Text(title, style: titleStyle),
              const SizedBox(height: 12),
              Flexible(child: SingleChildScrollView(child: content)),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 20),
                _HyperActions(tokens: tokens, actions: actions),
              ],
            ],
          ),
        ),
      ),
    );

    if (tokens.borderWidth <= 0) return panel;
    return Stack(
      children: [
        panel,
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
    );
  }
}

/// HyperOS actions: equal-width pills from two actions up, right aligned below.
class _HyperActions extends StatelessWidget {
  const _HyperActions({required this.tokens, required this.actions});

  final AppStyleTokens tokens;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final pill = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.buttonRadius),
    );
    final content = actions.length >= 2
        ? Row(
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: actions[i]),
              ],
            ],
          )
        : Row(mainAxisAlignment: MainAxisAlignment.end, children: actions);

    // Restyle caller-provided buttons without rebuilding them.
    return Theme(
      data: Theme.of(context).copyWith(
        textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: pill)),
        filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(shape: pill)),
        outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: pill)),
      ),
      child: content,
    );
  }
}
