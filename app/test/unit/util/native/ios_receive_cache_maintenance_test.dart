import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/native/receive_cache_maintenance.dart';
import 'package:localsend_isolates/util/ios_receive_scope.dart';

const _root = '/provider/中文 % root ';
const _leaseId = '19a3b3f0-141b-4c41-b421-2f68a0e929d3';

String _report({bool inspection = false, String disposition = 'retained', String reason = 'external_scope_required', int bytes = 0}) => jsonEncode({
  'inspection': inspection,
  'examined': 1,
  'retained': disposition == 'retained' ? 1 : 0,
  'removedFiles': disposition == 'removed' ? 1 : 0,
  'removedRecords': disposition == 'removed' ? 1 : 0,
  'plannedBytes': bytes,
  'unlinkedBytes': disposition == 'removed' ? bytes : 0,
  'reasons': {reason: 1},
  'entries': [
    {
      'id': 'a' * 64,
      'sourceKind': 'nativeReceive',
      'disposition': disposition,
      'reason': reason,
      'plannedBytes': bytes,
      'unlinkedBytes': disposition == 'removed' ? bytes : 0,
    },
  ],
});

IosReceiveScopeLease _lease(String path, {Future<void> Function(String)? release}) =>
    IosReceiveScopeLease(leaseId: _leaseId, path: path, release: release ?? (_) async {});

void main() {
  setUp(() => setAutomaticReceiveCacheCleanupAllowed(true));
  tearDown(() => setAutomaticReceiveCacheCleanupAllowed(false));

  test('startup acquires exact external root and replaces ordinary scope-required observation', () async {
    final order = <String>[];
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async => _report(),
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root],
        acquire: (root) async {
          expect(root, _root);
          order.add('acquire');
          return _lease(root, release: (_) async => order.add('release'));
        },
        maintain: (root, {required limit, required inspection, required force}) async {
          expect([root, limit, inspection, force], [_root, 4096, false, false]);
          order.add('worker');
          return _report(disposition: 'removed', reason: 'non_resumable_receive_attempt', bytes: 42);
        },
      ),
    );
    expect(order, ['acquire', 'worker', 'release']);
    expect(report.examined, 1);
    expect(report.retained, 0);
    expect(report.removedFiles, 1);
    expect(report.removedRecords, 1);
    expect(report.unlinkedBytes, 42);
    expect(report.reasons, {'non_resumable_receive_attempt': 1});
    expect(report.entries.single.disposition, 'removed');
    expect(report.interrupted, false);
  });

  test('inspection preserves overlapping bookmarks but counts one opaque candidate once', () async {
    final visited = <String>[];
    final report = await inspectRegisteredReceiveCaches(
      inspect: () async => _report(inspection: true),
      manual: true,
      maxBatches: 2,
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root, '$_root/child'],
        acquire: (root) async => _lease(root),
        maintain: (root, {required limit, required inspection, required force}) async {
          expect(inspection, true);
          expect(force, true);
          visited.add(root);
          return _report(inspection: true, disposition: 'candidate', reason: 'non_resumable_receive_attempt', bytes: 42);
        },
      ),
    );
    expect(visited.toSet(), {_root, '$_root/child'});
    expect(report.entries.length, 1);
    expect(report.examined, 1);
    expect(report.plannedBytes, 42);
    expect(report.retained, 0);
    expect(report.removedFiles, 0);
    expect(report.reasons, {'non_resumable_receive_attempt': 1});
  });

  test('busy and revoked roots never invoke worker; another valid root still proceeds', () async {
    final visited = <String>[];
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{}',
      maxBatches: 3,
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => ['/busy', '/revoked', '/valid'],
        acquire: (root) async {
          if (root == '/busy') throw PlatformException(code: 'receiveGrantBusy');
          if (root == '/revoked') throw PlatformException(code: 'receiveGrantUnavailable');
          return _lease(root);
        },
        maintain: (root, {required limit, required inspection, required force}) async {
          visited.add(root);
          return '{}';
        },
      ),
    );
    expect(visited, ['/valid']);
    expect(report.reasons['ios_scope_busy'], 1);
    expect(report.reasons['ios_scoped_maintenance_failed'], 1);
    expect(report.failed, 1);
    expect(report.interrupted, true);
  });

  test('automatic policy gates scoped work even with scan injection; manual retains force intent', () async {
    setAutomaticReceiveCacheCleanupAllowed(false);
    var lists = 0, workers = 0;
    final ops = IosReceiveCacheMaintenance(
      listRoots: () async {
        lists++;
        return [_root];
      },
      acquire: (root) async => _lease(root),
      maintain: (root, {required limit, required inspection, required force}) async {
        workers++;
        expect(force, true);
        return '{}';
      },
    );
    final automatic = await cleanRegisteredReceiveCaches(cleanup: () async => '{}', iosMaintenance: ops);
    expect(lists, 0);
    expect(workers, 0);
    expect(automatic.reasons['retention_unavailable'], 1);
    final manual = await cleanRegisteredReceiveCaches(cleanup: () async => '{}', iosMaintenance: ops, manual: true);
    expect(lists, 1);
    expect(workers, 1);
    expect(manual.interrupted, false);
  });

  test('policy changed during acquisition releases lease without destructive worker', () async {
    var releases = 0;
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{}',
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root],
        acquire: (root) async {
          setAutomaticReceiveCacheCleanupAllowed(false);
          return _lease(
            root,
            release: (_) async {
              releases++;
            },
          );
        },
        maintain: (_, {required limit, required inspection, required force}) => throw StateError('must not execute'),
      ),
    );
    expect(releases, 1);
    expect(report.reasons['retention_unavailable'], 1);
  });

  test('busy state spans worker completion and native release acknowledgement', () async {
    final worker = Completer<String>();
    final release = Completer<void>();
    final started = Completer<void>();
    final releasing = Completer<void>();
    var done = false;
    final future =
        cleanRegisteredReceiveCaches(
          cleanup: () async => '{}',
          iosMaintenance: IosReceiveCacheMaintenance(
            listRoots: () async => [_root],
            acquire: (root) async => _lease(
              root,
              release: (_) {
                releasing.complete();
                return release.future;
              },
            ),
            maintain: (_, {required limit, required inspection, required force}) {
              started.complete();
              return worker.future;
            },
          ),
        ).then((value) {
          done = true;
          return value;
        });
    await started.future;
    expect(releasing.isCompleted, false);
    expect(receiveCacheCleanupBusy.value, true);
    worker.complete('{}');
    await releasing.future;
    await Future<void>.delayed(Duration.zero);
    expect(done, false);
    expect(receiveCacheCleanupBusy.value, true);
    release.complete();
    expect((await future).interrupted, false);
    expect(receiveCacheCleanupBusy.value, false);
  });

  test('worker failure releases; release failure is visible and stops more acquisitions', () async {
    var releases = 0;
    final failed = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{}',
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root],
        acquire: (root) async => _lease(
          root,
          release: (_) async {
            releases++;
          },
        ),
        maintain: (_, {required limit, required inspection, required force}) => throw StateError('worker failed'),
      ),
    );
    expect(releases, 1);
    expect(failed.interrupted, true);
    var acquires = 0;
    final unacknowledged = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{}',
      maxBatches: 2,
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => ['/first', '/second'],
        acquire: (root) async {
          acquires++;
          return _lease(root, release: (_) => throw StateError('release failed'));
        },
        maintain: (_, {required limit, required inspection, required force}) async =>
            _report(disposition: 'removed', reason: 'non_resumable_receive_attempt', bytes: 42),
      ),
    );
    expect(acquires, 1);
    expect(unacknowledged.removedFiles, 1);
    expect(unacknowledged.reasons['ios_scope_release_failed'], 1);
    expect(unacknowledged.failed, 1);
    expect(unacknowledged.interrupted, true);
    expect(receiveCacheCleanupBusy.value, false);
  });

  test('root budget rotates across calls and does not starve later bookmarks', () async {
    final visited = <String>[];
    final ops = IosReceiveCacheMaintenance(
      listRoots: () async => List.generate(20, (i) => '/root-$i'),
      acquire: (root) async => _lease(root),
      maintain: (root, {required limit, required inspection, required force}) async {
        visited.add(root);
        return '{}';
      },
    );
    for (var i = 0; i < 10; i++) {
      final before = visited.length;
      final report = await cleanRegisteredReceiveCaches(cleanup: () async => '{}', iosMaintenance: ops, maxBatches: 2);
      expect(visited.length - before, 2);
      expect(report.budgetReached, true);
    }
    expect(visited.toSet().length, 20);
  });

  test('oversized roots are rejected before any authority or worker request', () async {
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{}',
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => List.generate(129, (i) => '/root-$i'),
        acquire: (_) => throw StateError('must not acquire'),
        maintain: (_, {required limit, required inspection, required force}) => throw StateError('must not execute'),
      ),
    );
    expect(report.reasons['ios_scope_list_failed'], 1);
    expect(report.interrupted, true);
  });

  test('external list requires matching non-null lease and malformed lease is released', () async {
    var releases = 0;
    for (final wrong in [false, true]) {
      final report = await cleanRegisteredReceiveCaches(
        cleanup: () async => '{}',
        iosMaintenance: IosReceiveCacheMaintenance(
          listRoots: () async => [_root],
          acquire: (_) async => wrong
              ? _lease(
                  '/different',
                  release: (_) async {
                    releases++;
                  },
                )
              : null,
          maintain: (_, {required limit, required inspection, required force}) => throw StateError('must not execute'),
        ),
      );
      expect(report.interrupted, true);
    }
    expect(releases, 1);
  });

  test('inspection rejects removals and awaits release even after invalid worker result', () async {
    var releases = 0;
    final report = await inspectRegisteredReceiveCaches(
      inspect: () async => '{"inspection":true}',
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root],
        acquire: (root) async => _lease(
          root,
          release: (_) async {
            releases++;
          },
        ),
        maintain: (_, {required limit, required inspection, required force}) async => _report(inspection: true, disposition: 'removed'),
      ),
    );
    expect(report.removedFiles, 0);
    expect(report.interrupted, true);
    expect(releases, 1);
  });

  test('missing detail does not invent subtractable scope-required counts', () async {
    final report = await cleanRegisteredReceiveCaches(
      cleanup: () async => '{"examined":2,"retained":2,"entriesTruncated":true,"reasons":{"external_scope_required":2}}',
      iosMaintenance: IosReceiveCacheMaintenance(
        listRoots: () async => [_root],
        acquire: (root) async => _lease(root),
        maintain: (_, {required limit, required inspection, required force}) async =>
            _report(disposition: 'removed', reason: 'non_resumable_receive_attempt'),
      ),
    );
    expect(report.retained, 2);
    expect(report.reasons['external_scope_required'], 2);
    expect(report.entriesTruncated, true);
    expect(report.removedFiles, 1);
  });
}
