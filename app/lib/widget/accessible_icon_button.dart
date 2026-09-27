import 'package:flutter/material.dart';

/// Keep the accessible name on the actionable/focusable button node, rather
/// than relying on a platform accessibility adapter exposing tooltip metadata.
class AccessibleIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double iconSize;

  const AccessibleIconButton({super.key, required this.icon, required this.label, required this.onPressed, this.tooltip, this.iconSize = 24});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? label,
    excludeFromSemantics: true,
    child: IconButton(
      onPressed: onPressed,
      iconSize: iconSize,
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: Semantics(label: label, excludeSemantics: true, child: Icon(icon)),
    ),
  );
}
