import 'package:flutter/material.dart';
import 'package:localsend_app/widget/status_tag.dart';

class DeviceBadge extends StatelessWidget {
  final Color backgroundColor;
  final Color foregroundColor;
  final String label;

  const DeviceBadge({
    required this.backgroundColor,
    required this.foregroundColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return StatusTag(label: label, backgroundColor: backgroundColor, foregroundColor: foregroundColor);
  }
}
