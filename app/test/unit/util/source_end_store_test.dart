import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/source_end_store.dart';
import 'package:localsend_isolates/model/source_end.dart';
import 'package:uuid/uuid.dart';

const uuid = Uuid();
const peer = 'verified-peer';
final job = uuid.v4(), key = uuid.v4(), attempt = uuid.v4();
SourceEndGrant grant({String? round}) =>
    SourceEndGrant(version: 1, grantId: uuid.v4(), round: round ?? uuid.v4(), token: 'A' * 43, expiresAtUnixMs: 2000000000000);
Future<bool> track(SourceEndStore store, {String? owner, String? source, String? task}) =>
    store.track(jobId: owner ?? job, peer: peer, resumeKey: source ?? key, peerLabel: 'Peer', name: 'file.bin', attemptId: task ?? attempt);
Future<void> saveGrant(SourceEndStore store, {SourceEndGrant? value, String? owner, String? task}) =>
    store.recordGrant(peer: peer, resumeKey: key, jobId: owner ?? job, attemptId: task ?? attempt, grant: value ?? grant());
void main() {
  late String? disk;
  late bool fail;
  late SourceEndStore store;
  setUp(() {
    disk = null;
    fail = false;
    store = SourceEndStore(
      read: () async => disk,
      write: (value) async {
        if (fail) throw StateError('IO');
        disk = value;
      },
    );
  });
  test('grant committed before acknowledgment and public projection excludes secrets', () async {
    await track(store);
    final value = grant();
    await saveGrant(store, value: value);
    expect(disk, contains(value.token));
    expect(store.notices(), isEmpty);
    await store.requestEnd(job);
    final visible = jsonEncode(store.notices());
    expect(visible, isNot(contains(value.token)));
    expect(visible, isNot(contains(key)));
    expect(visible, isNot(contains('grantId')));
    expect(store.pending().single.toString(), isNot(contains(value.token)));
  });
  test('uncertain write poisons store and cannot overwrite disk with stale memory', () async {
    await track(store);
    fail = true;
    await expectLater(saveGrant(store), throwsA(isA<SourceEndStorageException>()));
    fail = false;
    await expectLater(store.requestEnd(job), throwsA(isA<SourceEndStorageException>()));
    expect(store.notices(), isEmpty);
  });
  test('rename committed then sync failure reloads durable intent on restart', () async {
    await track(store);
    await saveGrant(store);
    final poisoned = SourceEndStore(
      read: () async => disk,
      write: (value) async {
        disk = value;
        throw StateError('sync');
      },
    );
    await expectLater(poisoned.requestEnd(job), throwsA(isA<SourceEndStorageException>()));
    expect(poisoned.notices(), isEmpty);
    final restart = SourceEndStore(read: () async => disk, write: (value) async => disk = value);
    await restart.initialize();
    expect(restart.notices().single['state'], 'pending');
    expect(restart.pending(), hasLength(1));
  });
  test('cancel and removal before late grant retain exact owner intent', () async {
    await track(store);
    await store.requestEnd(job);
    await store.detachOwner(job);
    expect(store.notices().single['state'], 'unknown');
    await saveGrant(store);
    expect(store.pending(), hasLength(1));
    expect(store.ended(peer, key), true);
    final restart = SourceEndStore(read: () async => disk, write: (value) async => disk = value);
    await restart.initialize();
    expect(restart.pending().single.requestId, store.pending().single.requestId);
  });
  test('shared source owners are separate and ended source key never revives', () async {
    final other = uuid.v4();
    await track(store);
    await track(store, owner: other);
    await saveGrant(store);
    await store.requestEnd(job);
    expect(store.endedOwners(peer, key), {job});
    expect(await track(store, owner: uuid.v4()), false);
    await store.requestEnd(other);
    expect(store.endedOwners(peer, key), {job, other});
  });
  test('late old attempt grant cannot replace current round', () async {
    await track(store);
    await saveGrant(store);
    final next = uuid.v4();
    await track(store, task: next);
    await saveGrant(store, task: next);
    await expectLater(saveGrant(store), throwsA(isA<SourceEndStorageException>()));
    await store.requestEnd(job);
    expect(store.pending(), hasLength(1));
  });
  test('retry request id is persisted and stale callback cannot regress newer intent', () async {
    await track(store);
    await saveGrant(store);
    await store.requestEnd(job);
    final dispatch = store.pending().single;
    final row = store.notices().single;
    final request = uuid.v4();
    final result = await store.retry(row['id']! as String, row['version']! as String, request);
    await store.outcome(dispatch, 'removed');
    expect(store.notices().single['state'], 'pending');
    final restarted = SourceEndStore(read: () async => disk, write: (value) async => disk = value);
    await restarted.initialize();
    expect(await restarted.retry(row['id']! as String, row['version']! as String, request), result);
    await expectLater(restarted.retry(row['id']! as String, row['version']! as String, uuid.v4()), throwsA(isA<SourceEndStorageException>()));
  });
  test('published, unsupported and expired are distinct from confirmed removal', () async {
    await track(store);
    await saveGrant(store);
    await store.requestEnd(job);
    await store.outcome(store.pending().single, 'expired');
    expect(store.notices().single['state'], 'expired');
    expect(store.hasScheduled, false);
  });
  test('512 pending record capacity disables optional opt in without mutation', () async {
    await track(store);
    final base = (jsonDecode(disk!) as Map)['records'][0] as Map<String, dynamic>;
    final rows = <Map<String, dynamic>>[];
    for (var i = 0; i < 512; i++) {
      final source = '00000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';
      rows.add({...base, 'id': uuid.v4(), 'resumeKey': source, 'key': SourceEndStore.key(peer, source)});
    }
    disk = jsonEncode({'version': 1, 'records': rows});
    final full = SourceEndStore(read: () async => disk, write: (value) async => disk = value);
    expect(await track(full, source: uuid.v4()), false);
    expect((jsonDecode(disk!)['records'] as List), hasLength(512));
  });
  test('journal restore rejects control characters before API exposure', () async {
    await track(store);
    final value = jsonDecode(disk!);
    value['records'][0]['name'] = 'bad\nname';
    disk = jsonEncode(value);
    final bad = SourceEndStore(read: () async => disk, write: (_) async {});
    await expectLater(bad.initialize(), throwsA(isA<SourceEndStorageException>()));
  });
  test('close releases native lease only after current journal write exits', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var closed = false;
    final s = SourceEndStore(
      read: () async => null,
      write: (_) async {
        entered.complete();
        await release.future;
      },
      releaseLease: () async => closed = true,
    );
    final pending = track(s);
    await entered.future;
    final closing = s.close();
    await Future<void>.delayed(Duration.zero);
    expect(closed, false);
    release.complete();
    await pending;
    await closing;
    expect(closed, true);
  });
}
