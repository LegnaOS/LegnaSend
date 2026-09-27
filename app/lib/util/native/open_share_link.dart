import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openShareLink(BuildContext context, String value) async {
  final uri = Uri.tryParse(value);
  try {
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('Browser unavailable');
    }
  } catch (_) {
    if (context.mounted) context.showSnackBar(t.directoryWorkspaces.openFailed);
  }
}
