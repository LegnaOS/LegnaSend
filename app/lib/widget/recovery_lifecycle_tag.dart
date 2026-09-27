import 'package:flutter/material.dart';
import 'package:localsend_app/util/upload_recovery_strings.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/model/upload_recovery.dart';

/// Typed recovery state, never inferred from a server's free-form error text.
/// Retention is separate from the reason: authorization may need renewal while
/// the receiver still retains verified blocks, or while that fact is unknown.
class RecoveryLifecycleTag extends StatelessWidget {
  final UploadRecoveryState recovery;
  const RecoveryLifecycleTag({required this.recovery, super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        StatusTag(
          label: uploadRecoveryLabel(recovery),
          icon: recovery.waiting ? Icons.cloud_off_outlined : Icons.info_outline,
          backgroundColor: recovery.waiting ? null : colors.errorContainer,
          foregroundColor: recovery.waiting ? null : colors.onErrorContainer,
        ),
        if (recovery.failure case final failure?) StatusTag(label: uploadRecoveryRetentionLabel(failure.retention), icon: Icons.storage_outlined),
      ],
    );
  }
}
