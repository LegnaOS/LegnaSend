import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/api_upload_source.dart';

void main() {
  test('large archive selection reaches native console without provider FD and other operations stay bounded', () async {
    final ids = List.generate(5000, (i) => '00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}');
    final value = {
      'operation': 'prepareWorkspaceArchive',
      'parameters': {'workspaceId': 'id', 'generation': '1'},
      'body': {'path': '', 'ids': ids},
    };
    final request = jsonEncode(value);
    expect(utf8.encode(request).length, greaterThan(72 * 1024));
    var calls = 0;
    expect(
      await executeApiConsoleWithSource(
        request: request,
        isCurrent: () => true,
        execute: (input, fd) async {
          calls++;
          expect(input, request);
          expect(fd, isNull);
          return 'prepared';
        },
      ),
      'prepared',
    );
    for (final invalid in [
      jsonEncode({...value, 'operation': 'getStatus'}),
      jsonEncode({...value, 'uploadUri': 'content://provider/source'}),
      ' ' * (2 * 1024 * 1024 + 16 * 1024 + 1),
    ]) {
      await expectLater(
        executeApiConsoleWithSource(
          request: invalid,
          isCurrent: () => true,
          execute: (_, __) async {
            calls++;
            return '';
          },
        ),
        throwsFormatException,
      );
    }
    expect(calls, 1);
  });

  String input({String operation = 'uploadFile', Object size = 3}) => jsonEncode({
    'operation': operation,
    'parameters': {'workspaceId': 'fixture', 'generation': '1', 'path': 'file.bin'},
    'uploadUri': 'content://provider/document/source',
    'uploadSize': size,
  });
  test('Android picker URI is removed before descriptor ownership transfers once', () async {
    var opens = 0, executions = 0, closes = 0;
    expect(
      await executeApiConsoleWithSource(
        request: input(),
        android: true,
        isCurrent: () => true,
        open: (uri) async {
          opens++;
          expect(uri, startsWith('content://'));
          return 27;
        },
        discard: (_) async {
          closes++;
        },
        execute: (request, fd) async {
          executions++;
          expect(fd, 27);
          expect(request, isNot(contains('content://')));
          expect(jsonDecode(request)['uploadSize'], 3);
          return 'receipt';
        },
      ),
      'receipt',
    );
    expect([opens, executions, closes], [1, 1, 0]);
  });
  test('late platform open after listener replacement closes before execution', () async {
    var current = true, executions = 0;
    final opened = Completer<int>(), closed = <int>[];
    final pending = executeApiConsoleWithSource(
      request: input(),
      android: true,
      isCurrent: () => current,
      open: (_) => opened.future,
      discard: (fd) async {
        closed.add(fd);
      },
      execute: (_, _) async {
        executions++;
        return '';
      },
    );
    current = false;
    opened.complete(42);
    await expectLater(pending, throwsStateError);
    expect(closed, [42]);
    expect(executions, 0);
  });
  test('bad source metadata and non-upload operations never open descriptors', () async {
    var opens = 0;
    for (final request in [
      input(operation: 'getStatus'),
      input(size: '3'),
      input(size: -1),
      jsonEncode({...jsonDecode(input()), 'uploadPath': '/other'}),
      jsonEncode({...jsonDecode(input()), 'uploadUri': 'file:///source'}),
    ]) {
      await expectLater(
        executeApiConsoleWithSource(
          request: request,
          android: true,
          isCurrent: () => true,
          open: (_) async {
            opens++;
            return 1;
          },
          execute: (_, _) async => '',
        ),
        throwsFormatException,
      );
    }
    expect(opens, 0);
  });
  test('provider exceptions are redacted and transferred descriptors are not closed twice', () async {
    await expectLater(
      executeApiConsoleWithSource(
        request: input(),
        android: true,
        isCurrent: () => true,
        open: (_) async => throw Exception('content://private-secret'),
        execute: (_, _) async => '',
      ),
      throwsA(isA<StateError>().having((e) => e.toString(), 'redaction', isNot(contains('private-secret')))),
    );
    var closes = 0;
    await expectLater(
      executeApiConsoleWithSource(
        request: input(),
        android: true,
        isCurrent: () => true,
        open: (_) async => 9,
        discard: (_) async {
          closes++;
        },
        execute: (_, _) async => throw StateError('native rejection'),
      ),
      throwsStateError,
    );
    expect(closes, 0);
  });
  test('ordinary path and read-only console requests preserve their JSON', () async {
    for (final request in ['{"operation":"getStatus"}', '{"operation":"uploadFile","uploadPath":"/selected.txt"}']) {
      await executeApiConsoleWithSource(
        request: request,
        isCurrent: () => true,
        execute: (value, fd) async {
          expect(value, request);
          expect(fd, isNull);
          return '';
        },
      );
    }
  });
}
