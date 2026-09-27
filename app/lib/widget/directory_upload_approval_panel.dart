import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/directory_upload_approval.dart';
import 'package:localsend_app/provider/directory_upload_approval_provider.dart';
import 'package:localsend_app/util/directory_upload_approval_strings.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_isolates/util/file_size_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Approvals are separate from transfer navigation: dismissing only hides the UI.
class DirectoryUploadApprovalPanel extends StatelessWidget {
  const DirectoryUploadApprovalPanel();

  @override
  Widget build(BuildContext context) {
    final requests = context.watch(directoryUploadApprovalProvider);
    final labels = DirectoryUploadApprovalStrings(Translations.of(context).$meta.locale);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: Column(
          children: [
            ListTile(
              title: Text(labels.title),
              trailing: IconButton(tooltip: labels.hide, onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.expand_more)),
            ),
            Expanded(
              child: requests.isEmpty
                  ? Center(
                      child: Padding(padding: const EdgeInsets.all(16), child: Text(labels.empty)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: requests.length + 1,
                      itemBuilder: (context, index) => index == requests.length
                          ? Padding(padding: const EdgeInsets.only(top: 12), child: Text(labels.hint))
                          : _RequestCard(request: requests[requests.length - index - 1]),
                    ),
            ),
            if (requests.any((request) => !request.pending))
              TextButton(onPressed: () => context.ref.notifier(directoryUploadApprovalProvider).clearFinished(), child: Text(labels.clear)),
          ],
        ),
      ),
    );
  }
}

String _relativeName(String path, String fallback) {
  // The server only emits relative paths. Defend the UI boundary too: never
  // accidentally reveal an absolute storage root supplied by a future caller.
  final normalized = path.replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(normalized) ||
      normalized.contains('://') ||
      normalized.split('/').contains('..')) {
    return fallback;
  }
  return normalized.isEmpty ? fallback : normalized.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
}

class _RequestCard extends StatelessWidget {
  final DirectoryUploadApproval request;
  const _RequestCard({required this.request});

  @override
  Widget build(BuildContext context) {
    final labels = DirectoryUploadApprovalStrings(Translations.of(context).$meta.locale);
    final colors = Theme.of(context).colorScheme;
    final actionable = request.status == DirectoryUploadApprovalStatus.waiting;
    return Card(
      key: ValueKey('workspace-request-${request.requestId}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                StatusTag(icon: Icons.folder_shared_outlined, label: '${labels.workspace} · ${request.workspaceName}'),
                StatusTag(label: labels.summary(request.fileCount, request.directoryCount)),
                StatusTag(label: request.totalBytes.asReadableFileSize),
              ],
            ),
            const SizedBox(height: 8),
            Text('${labels.peer} · ${request.peerIp}'),
            _RequestStatus(request: request),
            const SizedBox(height: 6),
            if (request.files.length > 100) Text(labels.showing(request.files.length), style: TextStyle(color: colors.onSurfaceVariant)),
            SizedBox(
              height: request.files.length <= 1 ? 80 : 144,
              child: ListView.builder(
                primary: false,
                itemCount: request.files.length.clamp(0, 100),
                itemBuilder: (context, index) {
                  final file = request.files[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_relativeName(file.path, labels.hiddenPath), maxLines: 3, overflow: TextOverflow.ellipsis),
                        Text(
                          '${file.directory ? labels.directory : labels.file} · ${file.size.asReadableFileSize}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (request.pending)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    key: ValueKey('workspace-decline-${request.requestId}'),
                    onPressed: actionable ? () => context.ref.notifier(directoryUploadApprovalProvider).decide(request.requestId, false) : null,
                    child: Text(labels.decline),
                  ),
                  FilledButton(
                    key: ValueKey('workspace-accept-${request.requestId}'),
                    onPressed: actionable ? () => context.ref.notifier(directoryUploadApprovalProvider).decide(request.requestId, true) : null,
                    child: Text(labels.accept),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RequestStatus extends StatefulWidget {
  final DirectoryUploadApproval request;
  const _RequestStatus({required this.request});
  @override
  State<_RequestStatus> createState() => _RequestStatusState();
}

class _RequestStatusState extends State<_RequestStatus> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.request.pending) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = DirectoryUploadApprovalStrings(Translations.of(context).$meta.locale);
    final seconds = ((widget.request.expiresAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil().clamp(0, 60);
    return Text(widget.request.status == DirectoryUploadApprovalStatus.waiting ? labels.remaining(seconds) : labels.status(widget.request.status));
  }
}
