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
  final isDark = Theme.of(context).brightness == Brightness.dark;
  // In dark mode the card and segmented rows sit on container-high, so the
  // sheet itself steps down to `surfaceContainer`; otherwise the rows and the
  // sheet share one tone and the segmented card disappears.
  final hyperSheetColor = isDark
      ? scheme.surfaceContainer
      : scheme.surfaceContainerHigh;

  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    // A modal sheet belongs above the shell's floating nav bar, so it is
    // pushed on the root navigator (same as showAppDialog).
    useRootNavigator: true,
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
    backgroundColor: hyper ? hyperSheetColor : null,
    sheetAnimationStyle: hyper ? AnimationStyle(curve: tokens.motionCurve) : null,
  );
}
