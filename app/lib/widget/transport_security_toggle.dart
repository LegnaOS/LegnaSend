import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';

/// The existing HTTPS setting, described as transport security rather than file encryption.
class TransportSecurityToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool showCertificate;

  const TransportSecurityToggle({super.key, required this.value, required this.onChanged, this.showCertificate = false});

  @override
  Widget build(BuildContext context) {
    final strings = Translations.of(context).transportSecurity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(strings.title),
          subtitle: Text(strings.description),
          value: value,
          onChanged: onChanged,
        ),
        if (showCertificate && value)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(strings.certificate, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
