import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/transfer_activity.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/web_transfer_activity_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

final transferActivityProvider = ViewProvider(
  (ref) => [
    ...ref.watch(webTransferActivityProvider),
    ...ref.watch(webApprovalActivityProvider),
    ...collectTransferActivities(
      jobs: ref.watch(sendQueueProvider),
      sends: ref.watch(sendProvider),
      receive: ref.watch(serverProvider)?.session,
      progress: ref.watch(fileTransferProvider),
    ),
  ],
);

final webApprovalActivityProvider = ViewProvider(
  (ref) => collectWebApprovalActivities(ref.watch(serverProvider.select((state) => state?.webDownloadState))),
);

/// Acknowledging a result hides only its indicator, never removes a live task.
final acknowledgedTransferResultsProvider = NotifierProvider<AcknowledgedTransferResults, Set<String>>((ref) => AcknowledgedTransferResults());

class AcknowledgedTransferResults extends PureNotifier<Set<String>> {
  @override
  Set<String> init() => {};

  /// [tasks] is the complete current task-view snapshot, not an append-only
  /// event log. Released browser response IDs must not accumulate forever.
  void acknowledge(Iterable<TransferActivity> tasks) => state = tasks.where((t) => !t.active).map((t) => t.resultKey).toSet();
}

List<TransferActivity> collectWebApprovalActivities(WebDownloadState? web) => [
  if (web != null)
    for (final session in web.sessions.values)
      if (session.pending)
        TransferActivity(
          id: session.sessionId,
          kind: TransferActivityKind.webApproval,
          direction: TransferDirection.send,
          phase: TransferPhase.waiting,
          peer: '${session.deviceInfo} · ${session.ip}',
          files: [for (final file in web.files.values) TransferActivityFile(file.file.fileName, file.file.size, 0)],
        ),
];
