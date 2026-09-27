import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/widget/status_tag.dart';

/// Compact integrity stage, not a network throughput or saved-file claim.
class ReceiveVerificationTag extends StatelessWidget {
  final FileVerification verification;
  const ReceiveVerificationTag({required this.verification, super.key});

  @override
  Widget build(BuildContext context) {
    final percent = verification.progress;
    final label = verification.receiving ? t.receivePage.verifyingReceivedData : t.sendPage.verifyingSourceData;
    return StatusTag(
      label: '$label${percent == null ? '' : ' · ${(percent * 100).floor()}%'}',
      icon: Icons.fact_check_outlined,
    );
  }
}
