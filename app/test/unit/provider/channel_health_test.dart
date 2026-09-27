import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/network/channel_health_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  const a = HttpChannel(host: 'fe80::1%3', port: 53317, https: true);
  const b = HttpChannel(host: '192.0.2.2', port: 53317, https: true);
  final device = Device.empty.copyWith(ip: a.host, fingerprint: 'peer', channels: [a, b]);
  test('entry failures are independent, version invalidation ignores delayed completion, expiry clears results', () async {
    final pending = <Completer<bool>>[];
    final provider = NotifierProvider<ChannelHealthNotifier, Map<ChannelHealthKey, ChannelHealth>>(
      (ref) => ChannelHealthNotifier((d, c, r) {
        expect(d.fingerprint, 'peer');
        expect([a, b], contains(c));
        final completer = Completer<bool>();
        pending.add(completer);
        return completer.future;
      }, lifetime: const Duration(milliseconds: 10)),
    );
    final container = RefenaContainer();
    addTearDown(() => container.dispose(provider));
    final notifier = container.notifier(provider);
    final first = notifier.check(device, a);
    final second = notifier.check(device, b);
    expect(container.read(provider).length, 2);
    pending[0].complete(false);
    pending[1].complete(true);
    await Future.wait([first, second]);
    expect(container.read(provider)[('peer', a)]!.phase, ChannelHealthPhase.unreachable);
    expect(container.read(provider)[('peer', b)]!.phase, ChannelHealthPhase.reachable);
    notifier.invalidate();
    final stale = notifier.check(device, a);
    notifier.invalidate();
    final fresh = notifier.check(device, a);
    pending[3].complete(true);
    await fresh;
    pending[2].complete(false);
    await stale;
    expect(container.read(provider)[('peer', a)]!.phase, ChannelHealthPhase.reachable);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(container.read(provider), isEmpty);
  });
  test('duplicate checking does not create duplicate requests', () async {
    final pending = Completer<bool>();
    var count = 0;
    final provider = NotifierProvider<ChannelHealthNotifier, Map<ChannelHealthKey, ChannelHealth>>(
      (ref) => ChannelHealthNotifier((d, c, r) {
        count++;
        return pending.future;
      }),
    );
    final container = RefenaContainer();
    addTearDown(() => container.dispose(provider));
    final n = container.notifier(provider);
    final running = n.check(device, a);
    await n.check(device, a);
    expect(count, 1);
    n.reconcile(
      {'peer': device},
      {
        'peer': device.copyWith(ip: b.host, channels: [b]),
      },
    );
    pending.complete(true);
    await running;
    expect(container.read(provider), isEmpty);
  });
}
