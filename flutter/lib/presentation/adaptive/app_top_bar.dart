import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../state/prefs.dart';

/// Top bar that matches the active [UiVariant].
///
/// * MD3: a plain flat [AppBar].
/// * HyperOS: a transparent platform bar over a frosted blur, with a 22sp
///   left-aligned title and a hairline bottom border.
class AppTopBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTopBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions,
    this.leading,
    this.bottom,
    this.height = kToolbarHeight,
  });

  /// Thickness of the HyperOS hairline. Always reserved in [preferredSize]
  /// because the size getter has no access to the variant.
  static const double _hairline = 0.5;

  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final double height;

  @override
  Size get preferredSize => Size.fromHeight(
        height + (bottom?.preferredSize.height ?? 0) + _hairline,
      );

  @override
  Widget build(BuildContext context) {
    final tokens = AppStyleTokens.of(context);
    final titleText = titleWidget ?? (title == null ? null : Text(title!));
    if (tokens.variant != UiVariant.hyperOS || !tokens.topBarBlur) {
      return _material(tokens, titleText);
    }
    return _hyper(context, tokens, titleText);
  }

  Widget _material(AppStyleTokens tokens, Widget? titleText) {
    return AppBar(
      title: titleText,
      actions: actions,
      leading: leading,
      bottom: bottom,
      toolbarHeight: height,
      elevation: 0,
      centerTitle: tokens.topBarCenterTitle,
    );
  }

  Widget _hyper(
    BuildContext context,
    AppStyleTokens tokens,
    Widget? titleText,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final baseStyle =
        theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;

    return AppBar(
      title: titleText,
      actions: actions,
      leading: leading,
      toolbarHeight: height,
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      // The bar is translucent, so the theme's brightness estimate (which sees
      // transparent as black) would pick the wrong status bar icons.
      systemOverlayStyle: scheme.brightness == Brightness.light
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
      titleTextStyle: baseStyle?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w600,
      ),
      // The blur lives behind the toolbar so content scrolling underneath is
      // frosted rather than hidden by an opaque slab. The pane must fill the
      // bar: a bare ColoredBox would collapse to zero height.
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(color: scheme.surface.withValues(alpha: 0.72)),
        ),
      ),
      bottom: _HairlineBottom(color: tokens.borderColor, child: bottom),
    );
  }
}

/// Stacks the caller's [bottom] above a hairline divider.
class _HairlineBottom extends StatelessWidget implements PreferredSizeWidget {
  const _HairlineBottom({this.child, required this.color});

  final PreferredSizeWidget? child;
  final Color color;

  @override
  Size get preferredSize => Size.fromHeight(
        (child?.preferredSize.height ?? 0) + AppTopBar._hairline,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?child,
        SizedBox(
          height: AppTopBar._hairline,
          width: double.infinity,
          child: ColoredBox(color: color),
        ),
      ],
    );
  }
}
