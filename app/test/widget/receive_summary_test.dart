import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

void main() {
  for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw]) {
    for (final width in [320.0, 900.0]) {
      testWidgets('incoming summary shows localized count and total size with long alias at $width in ${locale.languageTag}', (tester) async {
        await tester.runAsync(() => LocaleSettings.setLocale(locale));
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final files = [
          FileDto(id: 'a', fileName: 'folder/甲.txt', size: 1200, fileType: FileType.other, hash: null, preview: null, metadata: null),
          FileDto(id: 'b', fileName: 'folder/乙.txt', size: 800, fileType: FileType.other, hash: null, preview: null, metadata: null),
        ];
        final alias = 'Legna 的工作设备 A very long sender name across multiple words';
        final vm = ViewProvider(
          (_) => ReceivePageVm(
            status: SessionStatus.waiting,
            sessionId: 'receive',
            sender: Device.empty.copyWith(alias: alias),
            showSenderInfo: true,
            files: files,
            message: null,
            onAccept: () {},
            onDecline: () {},
            onClose: () {},
          ),
        );
        final container = RefenaContainer(overrides: [persistenceProvider.overrideWithValue(MockPersistenceService())]);
        container.notifier(selectedReceivingFilesProvider).setFiles(files);
        await tester.pumpWidget(
          RefenaScope.withContainer(
            container: container,
            child: TranslationProvider(child: MaterialApp(home: ReceivePage(vm))),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(alias), findsOneWidget);
        expect(find.text(t.receivePage.subTitle(n: 2)), findsOneWidget);
        expect(find.text(t.sendTab.selection.size(size: '2.0 KB')), findsOneWidget);
        expect(find.text(t.general.accept), findsOneWidget);
        expect(find.text(t.general.decline), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
