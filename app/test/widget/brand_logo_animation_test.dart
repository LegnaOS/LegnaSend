import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/local_send_logo.dart';
import 'package:localsend_app/widget/rotating_widget.dart';

void main() {
  Widget scene({bool spinning = true, bool reduced = false, bool ticker = true, bool reverse = false, Duration? duration}) {
    return MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: ticker,
          child: RotatingWidget(
            spinning: spinning,
            reverse: reverse,
            duration: duration ?? const Duration(seconds: 8),
            child: const LocalSendLogo(withText: false),
          ),
        ),
      ),
    );
  }

  double angle(WidgetTester tester) => tester.widget<RotationTransition>(find.byType(RotationTransition)).turns.value;

  testWidgets('portal mark keeps its own brand palette and accessible name', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorSchemeSeed: Colors.purple),
        home: const LocalSendLogo(withText: true),
      ),
    );
    expect(find.byType(ColorFiltered), findsNothing);
    expect(find.text('LegnaSend'), findsOneWidget);
    expect(find.bySemanticsLabel('LegnaSend'), findsWidgets);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, 'assets/img/logo-512.png');
  });

  testWidgets('rotation keeps moving over consecutive revolutions', (tester) async {
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(seconds: 2));
    expect(angle(tester), closeTo(.25, .001));
    await tester.pump(const Duration(seconds: 8));
    expect(angle(tester), closeTo(.25, .001));
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), closeTo(.375, .001));
    await tester.pumpWidget(const SizedBox());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduce motion stops ticker and reenable resumes without catch-up jump', (tester) async {
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(seconds: 2));
    final frozen = angle(tester);
    await tester.pumpWidget(scene(reduced: true));
    await tester.pump(const Duration(seconds: 10));
    expect(angle(tester), frozen);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(scene());
    expect(angle(tester), frozen);
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), greaterThan(frozen));
  });

  testWidgets('tab spinning gate and TickerMode each stop hidden animation work', (tester) async {
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(seconds: 1));
    final frozen = angle(tester);
    await tester.pumpWidget(scene(spinning: false));
    await tester.pump(const Duration(seconds: 3));
    expect(angle(tester), frozen);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(scene(ticker: false));
    await tester.pump(const Duration(seconds: 3));
    expect(angle(tester), frozen);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('background lifecycle stops animation and foreground resumes', (tester) async {
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final frozen = angle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(angle(tester), frozen);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), greaterThan(frozen));
  });

  testWidgets('covered route pauses until it becomes visible again', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        home: const RotatingWidget(duration: Duration(seconds: 8), child: LocalSendLogo(withText: false)),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('Details')))));
    await tester.pumpAndSettle();
    final rotation = find.descendant(
      of: find.byType(RotatingWidget, skipOffstage: false),
      matching: find.byType(RotationTransition, skipOffstage: false),
      skipOffstage: false,
    );
    final hidden = tester.widget<RotationTransition>(rotation).turns.value;
    await tester.pump(const Duration(seconds: 3));
    expect(tester.widget<RotationTransition>(rotation).turns.value, hidden);
    expect(tester.binding.transientCallbackCount, 0);
    nav.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), isNot(hidden));
  });

  testWidgets('duration and reverse changes are honored', (tester) async {
    await tester.pumpWidget(scene());
    await tester.pump(const Duration(seconds: 2));
    expect(angle(tester), closeTo(.25, .001));
    await tester.pumpWidget(scene(duration: const Duration(seconds: 4)));
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), closeTo(.5, .001));
    await tester.pumpWidget(scene(reverse: true, duration: const Duration(seconds: 4)));
    await tester.pump(const Duration(seconds: 1));
    expect(angle(tester), closeTo(.25, .001));
  });
  testWidgets('logo renders with the same green on light and dark surfaces', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('brand-render'),
            child: SizedBox(
              width: 440,
              height: 230,
              child: Row(
                children: [
                  Container(
                    width: 220,
                    height: 230,
                    color: const Color(0xFFF5F4EE),
                    child: const Center(child: LocalSendLogo(withText: false)),
                  ),
                  Container(
                    width: 220,
                    height: 230,
                    color: const Color(0xFF171D19),
                    child: const Center(child: LocalSendLogo(withText: false)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() => precacheImage(const AssetImage('assets/img/logo-512.png'), tester.element(find.byType(LocalSendLogo).first)));
    await tester.pumpAndSettle();
    await expectLater(find.byKey(const ValueKey('brand-render')), matchesGoldenFile('goldens/legnasend_portal_mark.png'));
  });
}
