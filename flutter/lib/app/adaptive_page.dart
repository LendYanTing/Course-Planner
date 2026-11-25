import 'package:flutter/material.dart';
// `CustomTransitionPage` lives in go_router (Flutter only ships
// `MaterialPage`/`CupertinoPage`). go_router does not import the app, so this
// adds no cycle.
import 'package:go_router/go_router.dart';

import '../state/prefs.dart';

/// Builds a route for the current engine: [MaterialPage] for MD3, a
/// spring/parallax slide for HyperOS.
Page<T> buildAdaptivePage<T>({
  required LocalKey key,
  required Widget child,
  required UiVariant variant,
}) {
  if (variant == UiVariant.material3) {
    return MaterialPage<T>(key: key, child: child);
  }
  return CustomTransitionPage<T>(
    key: key,
    child: child,
    transitionDuration: HyperOsPageTransitionsBuilder.duration,
    reverseTransitionDuration: HyperOsPageTransitionsBuilder.duration,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        buildHyperOsTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    ),
  );
}

/// HyperOS-style push: the entering page slides in from the right (~40 logical
/// pixels of travel) while fading, and the page underneath drifts slightly
/// left as a parallax backdrop. The system edge-back gesture is preserved by
/// keeping [CupertinoPageTransitionsBuilder] for iOS in the theme.
class HyperOsPageTransitionsBuilder extends PageTransitionsBuilder {
  const HyperOsPageTransitionsBuilder();

  /// Push/pop duration; the same value is used for both directions.
  static const duration = Duration(milliseconds: 320);

  @override
  Duration get transitionDuration => duration;

  @override
  Duration get reverseTransitionDuration => duration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return buildHyperOsTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

/// The transition itself, shared by [HyperOsPageTransitionsBuilder] and the
/// [CustomTransitionPage] built by [buildAdaptivePage] (which has no route
/// object to pass to [PageTransitionsBuilder.buildTransitions]).
Widget buildHyperOsTransition({
  required Animation<double> animation,
  required Animation<double> secondaryAnimation,
  required Widget child,
}) {
  final enter = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic,
  );
  final covered = CurvedAnimation(
    parent: secondaryAnimation,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic,
  );
  return SlideTransition(
    position: Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.03, 0),
    ).animate(covered),
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.06, 0),
        end: Offset.zero,
      ).animate(enter),
      child: FadeTransition(opacity: enter, child: child),
    ),
  );
}
