import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_isolates/model/file_status.dart';

/// Native queue recovery starts a fresh original-protocol session. Completed
/// files and files deliberately omitted by the receiver are not offered again.
/// This is whole-file recovery, not byte-range or cross-restart continuation.
List<CrossFile> remainingSendFiles(SendJob job, SendSessionState? session, FileStatus Function(String fileId) status) {
  if (session == null || session.sessionId != job.id || session.files.isEmpty) return job.files;
  final sent = session.files.values.toList(growable: false);
  // SendNotifier allocates file IDs in selection order and preserves that order.
  // Only use outcomes if they still describe this exact immutable job snapshot;
  // a missing/unrelated session must never silently remove selected files.
  if (sent.length != job.files.length) return job.files;
  for (var i = 0; i < sent.length; i++) {
    final previous = sent[i], source = job.files[i];
    if (previous.file.fileName != source.name ||
        previous.file.size != source.size ||
        previous.path != source.path ||
        !identical(previous.bytes, source.bytes)) {
      return job.files;
    }
  }
  return [
    for (var i = 0; i < sent.length; i++)
      if (status(sent[i].file.id) != FileStatus.finished && status(sent[i].file.id) != FileStatus.skipped) job.files[i],
  ];
}
