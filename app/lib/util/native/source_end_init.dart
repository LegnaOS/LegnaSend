import 'dart:io';

import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/source_end_provider.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_isolates/util/source_end_journal.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

Future<void> initializeSourceEndStore(RefenaContainer container, String supportRoot) async {
  await container.set(sourceEndRequiredProvider.overrideWithValue(true));
  final root = await Directory(supportRoot).resolveSymbolicLinks();
  final lease = await openSourceEndJournal(p.join(root, 'source-end-control', 'journal.json'));
  try {
    final store = SourceEndStore(
      read: lease.read,
      write: lease.write,
      releaseLease: lease.close,
      referenced: (peer, key) => container.read(sendQueueProvider).any((job) => job.target.fingerprint == peer && job.resumeKeys.contains(key)),
    );
    await store.initialize();
    await container.set(sourceEndStoreProvider.overrideWithValue(store));
  } catch (_) {
    await lease.close();
    rethrow;
  }
}
