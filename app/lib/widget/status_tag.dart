import 'package:flutter/material.dart';

/// A filled, borderless label. Interactive tags retain a full touch target and
/// native keyboard/focus semantics without looking like outlined buttons.
class StatusTag extends StatelessWidget {
  final String? label;
  final Widget? child;
  final IconData? icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final String? semanticsLabel;
  final Color? backgroundColor;
  final Color? foregroundColor;
  const StatusTag({
    super.key,
    this.label,
    this.child,
    this.icon,
    this.onTap,
    this.tooltip,
    this.semanticsLabel,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = foregroundColor ?? colors.onSecondaryContainer;
    final content = child ?? Text(label ?? '', softWrap: true);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 14), const SizedBox(width: 5)],
        Flexible(child: content),
      ],
    );
    final background = backgroundColor ?? colors.secondaryContainer.withValues(alpha: 0.68);
    Widget tag;
    if (onTap != null) {
      tag = TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          minimumSize: const Size(0, 28),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          textStyle: Theme.of(context).textTheme.labelMedium,
        ),
        child: semanticsLabel == null ? row : Semantics(label: semanticsLabel, excludeSemantics: true, child: row),
      );
    } else {
      tag = DecoratedBox(
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(7)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: IconTheme(
            data: IconThemeData(color: foreground, size: 14),
            child: DefaultTextStyle(
              style: Theme.of(context).textTheme.labelMedium!.copyWith(color: foreground),
              child: row,
            ),
          ),
        ),
      );
    }
    return tooltip == null ? tag : Tooltip(message: tooltip!, child: tag);
  }
}
