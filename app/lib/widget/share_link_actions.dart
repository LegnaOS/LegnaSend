import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/widget/accessible_icon_button.dart';

/// Every interface has separate named actions. Do not merge these with the
/// static network tags or the selectable address above them.
class ShareLinkActions extends StatelessWidget {
  final String url;
  final VoidCallback onCopy;
  final VoidCallback onQr;
  final VoidCallback onZoom;

  const ShareLinkActions({super.key, required this.url, required this.onCopy, required this.onQr, required this.onZoom});

  @override
  Widget build(BuildContext context) => FocusTraversalGroup(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in [
          (Icons.content_copy, t.general.copy, onCopy),
          (Icons.qr_code, t.dialogs.qr.title, onQr),
          (Icons.tv, t.dialogs.zoom.title, onZoom),
        ])
          AccessibleIconButton(
            icon: action.$1,
            iconSize: 16,
            label: '${action.$2} · $url',
            tooltip: action.$2,
            onPressed: action.$3,
          ),
      ],
    ),
  );
}
