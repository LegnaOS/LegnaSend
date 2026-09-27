import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/isolate/child/server_isolate.dart';
import 'package:localsend_isolates/src/task/server/file_saver.dart';
import 'package:localsend_isolates/src/task/server/http_server.dart';

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() => api.discarded.clear());

  FileSaveTarget descriptor(int fd) => FileSaveTarget(path: null, fileDescriptor: fd, displayPath: 'content://provider/document/opaque-$fd');

  test('cancelled queued attempt never creates or truncates its target', () async {
    var opened = false;
    final target = await prepareReceiveTargetIfActive(
      isActive: () => false,
      prepare: () async {
        opened = true;
        return descriptor(71);
      },
    );
    expect(target, isNull);
    expect(opened, false);
    expect(api.discarded, isEmpty);
  });

  test('descriptor opened after cancellation is released once and not submitted', () async {
    var active = true;
    final pending = Completer<FileSaveTarget>();
    final result = prepareReceiveTargetIfActive(isActive: () => active, prepare: () => pending.future);
    active = false;
    pending.complete(descriptor(71));
    expect(await result, isNull);
    expect(api.discarded, [(null, 71)]);
  });

  test('replacement session does not inherit a late provider descriptor', () async {
    final original = Object();
    Object current = original;
    final pending = Completer<FileSaveTarget>();
    final result = prepareReceiveTargetIfActive(isActive: () => identical(current, original), prepare: () => pending.future);
    current = Object();
    pending.complete(descriptor(72));
    expect(await result, isNull);
    expect(api.discarded, [(null, 72)]);
  });

  test('active descriptor ownership remains available to Rust upload', () async {
    final original = descriptor(73);
    final target = await prepareReceiveTargetIfActive(isActive: () => true, prepare: () async => original);
    expect(target, same(original));
    expect(api.discarded, isEmpty);
  });

  test('late ordinary path is not treated as a file to delete', () async {
    var active = true;
    final target = await prepareReceiveTargetIfActive(
      isActive: () => active,
      prepare: () async {
        active = false;
        return FileSaveTarget(path: '/existing/file.txt', fileDescriptor: null, displayPath: '/existing/file.txt');
      },
    );
    expect(target, isNull);
    expect(api.discarded, isEmpty);
  });

  test('provider preparation failure propagates without inventing a descriptor', () async {
    await expectLater(
      prepareReceiveTargetIfActive(isActive: () => true, prepare: () async => throw StateError('provider offline')),
      throwsStateError,
    );
    expect(api.discarded, isEmpty);
  });

  test('preparation error after session cancellation is retired instead of reaching the replacement', () async {
    var active = true;
    final pending = Completer<FileSaveTarget>();
    final result = prepareReceiveTargetIfActive(isActive: () => active, prepare: () => pending.future);
    active = false;
    pending.completeError(const FileSystemException('permission response arrived after stop'));
    expect(await result, isNull);
    expect(api.discarded, isEmpty);
  });

  test('stopped service consumes late descriptor before reporting upload failure', () async {
    final service = HttpServerService();
    await service.stop();
    await expectLater(
      service.respondFileUpload(sessionId: 'old', fileId: 'f', path: null, fileDescriptor: 74, fileSize: 10).drain<void>(),
      throwsStateError,
    );
    expect(api.discarded, [(null, 74)]);
    expect(service.running, false);
  });

  test('stopped ordinary path upload leaves the path untouched', () async {
    await expectLater(
      HttpServerService()
          .respondFileUpload(sessionId: 'old', fileId: 'f', path: '/existing/file.txt', fileDescriptor: null, fileSize: 10)
          .drain<void>(),
      throwsStateError,
    );
    expect(api.discarded, isEmpty);
  });
}

class _Api extends RustLibApi {
  final List<(String?, int?)> discarded = [];

  @override
  Future<void> crateApiServerDiscardDownloadSource({String? path, int? fileDescriptor}) async {
    discarded.add((path, fileDescriptor));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
