import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/device_drop_region.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  testWidgets('one hit-tested destination; blank space does not select a device', (tester) async {
    late BuildContext hitContext;
    final target = Device.empty.copyWith(fingerprint: 'a', alias: 'Receiver');
    await tester.pumpWidget(
      RefenaScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              hitContext = context;
              return Scaffold(
                body: Stack(
                  children: [
                    Positioned(
                      left: 20,
                      top: 20,
                      child: DeviceDropRegion(device: target, child: const SizedBox(width: 180, height: 80)),
                    ),
                    const Positioned.fill(
                      child: IgnorePointer(child: ColoredBox(color: Colors.transparent)),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(hitTestDropDevice(hitContext, const Offset(50, 50)), target);
    expect(hitTestDropDevice(hitContext, const Offset(400, 300)), isNull);
    hitContext.ref.notifier(deviceDropHoverProvider).set(target);
    await tester.pump();
    expect(hitTestDropDevice(hitContext, const Offset(50, 50)), target);
    // An actual modal on top must win, unlike the pointer-transparent drag hint.
    final dialog = showDialog<void>(
      context: hitContext,
      builder: (_) => const AlertDialog(content: Text('Modal')),
    );
    await tester.pumpAndSettle();
    expect(hitTestDropDevice(hitContext, const Offset(50, 50)), isNull);
    Navigator.of(hitContext).pop();
    await tester.pumpAndSettle();
    await dialog;
  });
}
