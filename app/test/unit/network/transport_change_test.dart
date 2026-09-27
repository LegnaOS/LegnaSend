import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/util/network/transport_change.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('HTTP is default and explicitly persisted HTTPS remains opt-in', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({
      'ls_version': 3,
      'ls_security_context': '{}',
      'ls_alias': 'Fixture',
      'ls_show_token': 'fixture',
      'ls_locale': 'en',
      'ls_color': 'localsend',
    });
    final prefs = await PersistenceService.initialize(supportsDynamicColors: false);
    expect(prefs.isHttps(), false);
    await prefs.setHttps(true);
    expect((await PersistenceService.initialize(supportsDynamicColors: false)).isHttps(), true);
    await prefs.setHttps(false);
    expect((await PersistenceService.initialize(supportsDynamicColors: false)).isHttps(), false);
  });
  test('transport change saves before listener switch and restores on failure', () async {
    final calls = <String>[];
    Future<void> persist(bool value) async => calls.add('save:$value');
    await applyTransportChange(
      previous: true,
      next: false,
      persist: persist,
      apply: () async => calls.add('switch'),
      restore: () async => calls.add('restore'),
    );
    expect(calls, ['save:false', 'switch']);
    calls.clear();
    await expectLater(
      applyTransportChange(
        previous: true,
        next: false,
        persist: persist,
        apply: () async {
          calls.add('switch');
          throw StateError('bind');
        },
        restore: () async => calls.add('restore'),
      ),
      throwsStateError,
    );
    expect(calls, ['save:false', 'switch', 'save:true', 'restore']);
  });
  test('persistence failure does not interrupt the running listener', () async {
    var interrupted = false;
    await expectLater(
      applyTransportChange(
        previous: true,
        next: false,
        persist: (_) async => throw StateError('disk'),
        apply: () async {
          interrupted = true;
        },
        restore: () async {
          interrupted = true;
        },
      ),
      throwsStateError,
    );
    expect(interrupted, false);
  });
  test('failed preference restoration still attempts to restore the listener', () async {
    var restored = false;
    await expectLater(
      applyTransportChange(
        previous: true,
        next: false,
        persist: (value) async {
          if (value) throw StateError('disk');
        },
        apply: () async => throw StateError('bind'),
        restore: () async {
          restored = true;
        },
      ),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('restoration is incomplete'))),
    );
    expect(restored, true);
  });
}
