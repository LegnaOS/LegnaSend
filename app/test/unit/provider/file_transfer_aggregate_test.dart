import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/file_verification.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

class _ObservedTransfers extends FileTransferNotifier {
  void Function()? onPresentation;
  @override
  void notifyListeners() {
    onPresentation?.call();
    super.notifyListeners();
  }
}

void main() {
  testWidgets('5000 files update exact aggregates and immediate results with one presentation flush', (tester) async {
    final container = RefenaContainer(overrides: [fileTransferProvider.overrideWithNotifier((_) => _ObservedTransfers())]);
    addTearDown(container.disposeContainer);
    final files = container.notifier(fileTransferProvider);
    var presentations = 0;
    var results = 0;
    (files as _ObservedTransfers).onPresentation = () => presentations++;
    files.addResultListener(() => results++);
    files.registerFileSizes('send', {for (var i = 0; i < 5000; i++) '$i': 4096});
    expect(files.hasPending('send'), isFalse, reason: 'metadata alone cannot create protocol work');
    expect(files.getStatuses('send'), isEmpty);
    for (var i = 0; i < 5000; i++) {
      files.setStatus(sessionId: 'send', fileId: '$i', status: FileStatus.sending);
      files.setProgress(sessionId: 'send', fileId: '$i', progress: .5);
      files.setProgress(sessionId: 'send', fileId: '$i', progress: 1);
      files.setStatus(sessionId: 'send', fileId: '$i', status: FileStatus.finished);
    }
    expect(files.transferredBytes('send'), 5000 * 4096);
    expect(files.statusCount('send', FileStatus.finished), 5000);
    expect(files.statusCount('send', FileStatus.queue), 0);
    expect(files.statusCount('send', FileStatus.sending), 0);
    expect(results, 10000, reason: 'result observers are not delayed behind presentation');
    expect(presentations, 0);
    expect(files.getData()['send']!.length, 5000, reason: 'no per-event retained records');
    await tester.pump(FileTransferNotifier.presentationInterval);
    expect(presentations, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(presentations, 1, reason: 'no permanent polling timer');
  });

  testWidgets('repeated progress, rounding, late sizes, skipped and retried files use deltas', (tester) async {
    final container = RefenaContainer(overrides: [fileTransferProvider.overrideWithNotifier((_) => _ObservedTransfers())]);
    addTearDown(container.disposeContainer);
    final files = container.notifier(fileTransferProvider);
    files.setProgress(sessionId: 's', fileId: 'a', progress: .5);
    files.registerFileSizes('s', {'a': 3, 'b': 7});
    expect(files.transferredBytes('s'), 2);
    files.registerFileSizes('s', {'a': 3, 'b': 7});
    files.setProgress(sessionId: 's', fileId: 'a', progress: .5);
    expect(files.transferredBytes('s'), 2);
    files.setStatus(sessionId: 's', fileId: 'a', status: FileStatus.failed);
    files.setStatus(sessionId: 's', fileId: 'b', status: FileStatus.skipped);
    expect(files.statusCount('s', FileStatus.failed), 1);
    files.setStatus(sessionId: 's', fileId: 'a', status: FileStatus.sending);
    files.setProgress(sessionId: 's', fileId: 'a', progress: 0);
    expect(files.transferredBytes('s'), 0);
    expect(files.statusCount('s', FileStatus.failed), 0);
    files.setProgress(sessionId: 's', fileId: 'a', progress: double.nan);
    expect(files.transferredBytes('s'), 0);
    files.setProgress(sessionId: 's', fileId: 'a', progress: 1);
    expect(files.transferredBytes('s'), 3);
    container.disposeContainer();
  });

  testWidgets('removal invalidates pending flush and replacement session owns fresh totals', (tester) async {
    final container = RefenaContainer(overrides: [fileTransferProvider.overrideWithNotifier((_) => _ObservedTransfers())]);
    addTearDown(container.disposeContainer);
    final files = container.notifier(fileTransferProvider);
    var presentations = 0;
    (files as _ObservedTransfers).onPresentation = () => presentations++;
    files.registerFileSizes('s', {'a': 100});
    files.setProgress(sessionId: 's', fileId: 'a', progress: .7);
    files.removeSession('s');
    await tester.pump();
    expect(presentations, 1);
    expect(files.transferredBytes('s'), 0);
    await tester.pump(FileTransferNotifier.presentationInterval);
    expect(presentations, 1);
    expect(files.getData(), isEmpty);
    files.registerFileSizes('s', {'new': 9});
    files.setProgress(sessionId: 's', fileId: 'new', progress: 1);
    await tester.pump(FileTransferNotifier.presentationInterval);
    expect(files.transferredBytes('s'), 9);
    expect(files.getData()['s']!.keys, ['new']);
    files.dispose();
    await tester.pump(FileTransferNotifier.presentationInterval);
    expect(presentations, 2);
  });

  test('equal session IDs use independent page file-membership projections', () {
    final files = FileTransferNotifier();
    files.registerFileSizes('same', {'out': 100}, scope: TransferProgressScope.send);
    files.registerFileSizes('same', {'in': 200}, scope: TransferProgressScope.receive);
    files.setProgress(sessionId: 'same', fileId: 'out', progress: .4);
    files.setStatus(sessionId: 'same', fileId: 'out', status: FileStatus.finished);
    files.setProgress(sessionId: 'same', fileId: 'in', progress: .5);
    files.setStatus(sessionId: 'same', fileId: 'in', status: FileStatus.sending);
    expect(files.transferredBytes('same', scope: TransferProgressScope.send), 40);
    expect(files.transferredBytes('same', scope: TransferProgressScope.receive), 100);
    expect(files.statusCount('same', FileStatus.finished, scope: TransferProgressScope.receive), 0);
    expect(files.statusCount('same', FileStatus.finished, scope: TransferProgressScope.send), 1);
    files.dispose();
  });

  testWidgets('dispose and reset drain pending presentation without replaying captured files', (tester) async {
    final container = RefenaContainer(overrides: [fileTransferProvider.overrideWithNotifier((_) => _ObservedTransfers())]);
    addTearDown(container.disposeContainer);
    final files = container.notifier(fileTransferProvider);
    var presentations = 0;
    (files as _ObservedTransfers).onPresentation = () => presentations++;
    files.setProgress(sessionId: 'old', fileId: 'a', progress: .5);
    files.removeAllSessions();
    await tester.pump();
    expect(presentations, 1);
    files.setProgress(sessionId: 'new', fileId: 'a', progress: .5);
    files.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(presentations, 1);
    expect(files.getData(), isEmpty);
  });

  testWidgets('parallel directions and verification retain exact attempt identity without adding bytes', (tester) async {
    final container = RefenaContainer(overrides: [fileTransferProvider.overrideWithNotifier((_) => _ObservedTransfers())]);
    addTearDown(container.disposeContainer);
    final files = container.notifier(fileTransferProvider);
    for (final session in ['send', 'receive']) {
      files.registerFileSizes(session, {'a': 100});
      files.setStatus(sessionId: session, fileId: 'a', status: FileStatus.sending);
      files.beginReceiveAttempt(sessionId: session, fileId: 'a', attemptId: session, owner: session == 'send' ? 0 : 7);
    }
    files.setProgress(sessionId: 'send', fileId: 'a', progress: .4);
    expect(
      files.setVerification(
        sessionId: 'receive',
        fileId: 'a',
        owner: 7,
        value: const FileVerification(attemptId: 'receive', verifiedBytes: 90, totalBytes: 100),
        verifying: true,
      ),
      isTrue,
    );
    expect(
      files.setVerification(
        sessionId: 'receive',
        fileId: 'a',
        owner: 6,
        value: const FileVerification(attemptId: 'receive', verifiedBytes: 100, totalBytes: 100),
        verifying: true,
      ),
      isFalse,
    );
    expect(files.transferredBytes('send'), 40);
    expect(files.transferredBytes('receive'), 0);
    files.setStatus(sessionId: 'receive', fileId: 'a', status: FileStatus.finished);
    expect(files.getVerification(sessionId: 'receive', fileId: 'a'), isNull);
    expect(files.statusCount('send', FileStatus.sending), 1);
    expect(files.statusCount('receive', FileStatus.finished), 1);
    container.disposeContainer();
  });
}
