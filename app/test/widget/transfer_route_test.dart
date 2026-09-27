import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/ui/transfer_route.dart';

void main() {
  testWidgets('replacing a covered send route leaves a receive prompt on top', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: Text('home'));
          },
        ),
      ),
    );
    final sending = TransferRoute(context);
    unawaited(sending.show((_) => const Scaffold(body: Text('sending request'))));
    await tester.pumpAndSettle();
    final receiving = TransferRoute(context);
    unawaited(receiving.show((_) => const Scaffold(body: Text('receive confirmation'))));
    await tester.pumpAndSettle();
    unawaited(sending.show((_) => const Scaffold(body: Text('send progress'))));
    await tester.pumpAndSettle();
    expect(find.text('receive confirmation'), findsOneWidget);
    receiving.close();
    await tester.pumpAndSettle();
    expect(find.text('send progress'), findsOneWidget);
    sending.close();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('closing a covered completed task does not pop another task', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: Text('home'));
          },
        ),
      ),
    );
    final receiving = TransferRoute(context);
    unawaited(receiving.show((_) => const Scaffold(body: Text('receive progress'))));
    await tester.pumpAndSettle();
    final sending = TransferRoute(context);
    unawaited(sending.show((_) => const Scaffold(body: Text('send progress'))));
    await tester.pumpAndSettle();
    receiving.close();
    receiving.close();
    await tester.pumpAndSettle();
    expect(find.text('send progress'), findsOneWidget);
    sending.close();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });
  testWidgets('accepting through a task sheet replaces only the underlying prompt', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: Text('home'));
          },
        ),
      ),
    );
    final receiving = TransferRoute(context);
    unawaited(receiving.show((_) => const Scaffold(body: Text('receive confirmation'))));
    await tester.pumpAndSettle();
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 200, child: Text('task sheet')),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(receiving.show((_) => const Scaffold(body: Text('receive progress'))));
    await tester.pumpAndSettle();
    expect(find.text('task sheet'), findsOneWidget);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(find.text('receive progress'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
