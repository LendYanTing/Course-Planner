import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

/// Shows a modal bottom sheet that matches the active [UiVariant].
///
/// Both variants use [showModalBottomSheet]; only the surface is different:
/// HyperOS gets a superellipse top edge, a drag handle and the theme's motion
/// curve. MD3 keeps every platform default.
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = true,
  bool isDismissible = true,
  bool enableDrag = true,
}) {
  final tokens = AppStyleTokens.of(context);
  final hyper = tokens.variant == UiVariant.hyperOS;
  final scheme = Theme.of(context).colorScheme;

  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    shape: hyper
        ? RoundedSuperellipseBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(tokens.sheetRadius),
            ),
          )
        : null,
    clipBehavior: hyper ? Clip.antiAlias : null,
    showDragHandle: hyper ? true : null,
    backgroundColor: hyper ? scheme.surfaceContainerHigh : null,
    sheetAnimationStyle: hyper ? AnimationStyle(curve: tokens.motionCurve) : null,
  );
}
