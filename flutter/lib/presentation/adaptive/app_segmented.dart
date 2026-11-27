import 'package:flutter/material.dart';

import 'app_switch.dart';

/// A rounded colour block that hosts a list-row icon.
///
/// This is the SukiSU-style icon tile: a 36dp square with a 12dp radius,
/// filled with `secondaryContainer` unless the caller overrides either colour.
class AppIconTile extends StatelessWidget {
  const AppIconTile({
    super.key,
    required this.icon,
    this.backgroundColor,
    this.iconColor,
    this.size = 36,
  });

  final IconData icon;
  final Color? backgroundColor;
  final Color? iconColor;

  /// Edge length of the square tile.
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: backgroundColor ?? scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        size: size * 20 / 36,
        color: iconColor ?? scheme.onSecondaryContainer,
      ),
    );
  }
}

/// A group of rows joined into one segmented superellipse card.
///
/// The first row has a 24dp top radius, the last a 24dp bottom radius and the
/// rows in between 6dp; neighbouring rows are separated by 2dp so the canvas
/// tone shows through. Each row gets its own clipped [Material], so a plain
/// [ListTile] child already has a ripple.
class AppSegmentedColumn extends StatelessWidget {
  const AppSegmentedColumn({
    super.key,
    this.title,
    this.titleIcon,
    this.margin = EdgeInsets.zero,
    required this.children,
  });

  /// Optional group label rendered above the card.
  final String? title;

  /// Optional icon shown before [title].
  final IconData? titleIcon;

  final EdgeInsetsGeometry margin;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final surface = theme.brightness == Brightness.dark
        ? scheme.surfaceContainerHigh
        : scheme.surfaceBright;
    final count = children.length;

    return Padding(
      padding: margin,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) _title(scheme),
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            _SegmentedShape(
              index: i,
              count: count,
              color: surface,
              child: children[i],
            ),
          ],
        ],
      ),
    );
  }

  Widget _title(ColorScheme scheme) {
    final label = Text(
      title!,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          if (titleIcon != null) ...[
            Icon(titleIcon, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
          ],
          label,
        ],
      ),
    );
  }
}

/// Clips one row of an [AppSegmentedColumn] and gives it the card surface.
class _SegmentedShape extends StatelessWidget {
  const _SegmentedShape({
    required this.index,
    required this.count,
    required this.color,
    required this.child,
  });

  final int index;
  final int count;
  final Color color;
  final Widget child;

  /// 24dp on the outer edges of the group, 6dp between rows; a lone row gets
  /// 24dp on all four corners.
  static BorderRadius radiusFor(int index, int count) {
    if (count <= 1) return BorderRadius.circular(24);
    final top = index == 0
        ? const Radius.circular(24)
        : const Radius.circular(6);
    final bottom = index == count - 1
        ? const Radius.circular(24)
        : const Radius.circular(6);
    return BorderRadius.only(
      topLeft: top,
      topRight: top,
      bottomLeft: bottom,
      bottomRight: bottom,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRSuperellipse(
      borderRadius: radiusFor(index, count),
      child: Material(color: color, child: child),
    );
  }
}

/// A segmented row with an icon tile, a title/subtitle and a trailing switch.
class AppSegmentedSwitchItem extends StatelessWidget {
  const AppSegmentedSwitchItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            AppIconTile(icon: icon),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            AppSwitch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
