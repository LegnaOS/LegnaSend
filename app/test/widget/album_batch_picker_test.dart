import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/widget/album_batch_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

AssetEntity asset(String id) => AssetEntity(id: id, typeInt: 1, width: 100, height: 100);
DefaultAssetPickerProvider provider() => DefaultAssetPickerProvider.forTest(maxAssets: 999)
  ..currentPath = PathWrapper(
    path: AssetPathEntity(id: 'album', name: 'Travel'),
  )
  ..selectedAssets = [asset('old')];
Future<void> mount(WidgetTester tester, DefaultAssetPickerProvider state, Future<List<AssetEntity>> Function(AssetPathEntity, int, int) load) async {
  await LocaleSettings.setLocale(AppLocale.en);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: AlbumBatchBar(provider: state, loadPage: load),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('visible batch action preserves individually selected assets and selects album metadata', (tester) async {
    final state = provider();
    await mount(tester, state, (path, page, size) async {
      expect(path.id, 'album');
      expect(size, 128);
      return [asset('old'), asset('new')];
    });
    await tester.tap(find.text('Select current album'));
    await tester.pumpAndSettle();
    expect(state.selectedAssets.map((a) => a.id), ['old', 'new']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('cancel closes progress immediately and pending page never mutates selection', (tester) async {
    final state = provider(), pending = Completer<List<AssetEntity>>();
    await mount(tester, state, (_, _, _) => pending.future);
    await tester.tap(find.text('Select current album'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.selectedAssets.map((a) => a.id), ['old']);
    pending.complete([asset('new')]);
    await tester.pumpAndSettle();
    expect(state.selectedAssets.map((a) => a.id), ['old']);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('read error reports failure without altering selection', (tester) async {
    final state = provider();
    await mount(tester, state, (_, _, _) async => throw StateError('permission revoked'));
    await tester.tap(find.text('Select current album'));
    await tester.pumpAndSettle();
    expect(state.selectedAssets.map((a) => a.id), ['old']);
    expect(find.textContaining('Nothing was added.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('late result from another album cannot change selection', (tester) async {
    final state = provider(), pending = Completer<List<AssetEntity>>();
    await mount(tester, state, (_, _, _) => pending.future);
    await tester.tap(find.text('Select current album'));
    await tester.pump();
    state.currentPath = PathWrapper(
      path: AssetPathEntity(id: 'different', name: 'New album'),
    );
    pending.complete([asset('new')]);
    await tester.pumpAndSettle();
    expect(state.selectedAssets.map((a) => a.id), ['old']);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('system back cancels pending enumeration without popping parent page', (tester) async {
    final state = provider(), pending = Completer<List<AssetEntity>>();
    await mount(tester, state, (_, _, _) => pending.future);
    await tester.tap(find.text('Select current album'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    pending.complete([asset('new')]);
    await tester.pumpAndSettle();
    expect(find.byType(AlbumBatchBar), findsOneWidget);
    expect(state.selectedAssets.map((a) => a.id), ['old']);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('no authorized album disables batch action', (tester) async {
    final state = DefaultAssetPickerProvider.forTest(maxAssets: 999);
    await mount(tester, state, (_, _, _) async => throw StateError('must not query'));
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Select current album')).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('desktop and mobile platforms expose media entry; desktop filter covers images and video', (tester) async {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(FilePickerOption.getOptionsForPlatform(), contains(FilePickerOption.media));
    }
    debugDefaultTargetPlatformOverride = null;
    expect(desktopMediaFileTypes.single.extensions, containsAll(['jpg', 'heic', 'mp4', 'mov']));
    expect(desktopMediaFileTypes.single.uniformTypeIdentifiers, containsAll(['public.image', 'public.movie']));
  });
}
