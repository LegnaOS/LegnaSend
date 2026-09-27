import 'package:localsend_app/util/send_recovery_store.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Installed by native bootstrap. Tests and unsupported containers stay in memory.
final sendRecoveryStoreProvider = Provider<SendRecoveryStore?>((_) => null);
final sendRecoveryIssueProvider = NotifierProvider<SendRecoveryIssue, String?>((_) => SendRecoveryIssue());

class SendRecoveryIssue extends PureNotifier<String?> {
  @override
  String? init() => null;
  void report(String? issue) => state = issue;
}
