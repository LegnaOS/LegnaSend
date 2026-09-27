import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/android_folder_strings.dart';
import 'package:localsend_app/util/native/android_folder_selection.dart';
import 'package:refena_flutter/refena_flutter.dart';

Map<String, Object?> entry(String id, String path, {int? size = 12}) => {
  'uri': 'content://opaque/tree/grant/document/$id',
  'name': path.split('/').last,
  'relativePath': path,
  'size': size,
  'modifiedMillis': 1700000000000,
};
Map<String, Object?> selection(List<Map<String, Object?>> files) => {
  'version': 1,
  'directoryUri': 'content://opaque/tree/grant',
  'files': files,
  'emptyDirectories': 2,
};
void main() {
  test('opaque IDs are not decoded and nested provider path becomes exact original-v2 file name', () async {
    final manifest = AndroidFolderSelection.parse(selection([entry('random-token-not-a-path', '頂層/資料/中文 %.txt')]));
    final container = RefenaContainer();
    addTearDown(container.disposeContainer);
    final files = await container.redux(selectedSendingFilesProvider).dispatchAsync(AddAndroidDirectoryAction(manifest));
    expect(files.single.name, '頂層/資料/中文 %.txt');
    expect(files.single.path, 'content://opaque/tree/grant/document/random-token-not-a-path');
    expect(files.single.size, 12);
    expect(manifest.emptyDirectories, 2);
  });
  test('entire manifest is rejected on unknown size, duplicates, unsafe path or old inferred contract', () {
    for (final bad in [
      [entry('ok', 'root/ok'), entry('bad', 'root/unknown', size: null)],
      [entry('one', 'root/same'), entry('two', 'root/same')],
      [entry('one', 'root/../escape')],
      [entry('one', 'root/a\\b')],
      [entry('one', 'root/a')..remove('relativePath')],
    ]) {
      expect(() => AndroidFolderSelection.parse(selection(bad)), throwsFormatException);
    }
  });
  test('5000 structured files are bounded and no empty placeholder files are invented', () {
    final manifest = AndroidFolderSelection.parse(selection([for (var i = 0; i < 5000; i++) entry('opaque-$i', 'root/資料/f$i')]));
    expect(manifest.files.length, 5000);
    expect(manifest.files.every((file) => file.size == 12), isTrue);
    expect(AndroidFolderSelection.parse(selection([])).files, isEmpty);
  });
  test('all four locales explicitly describe omitted empty folders and atomic failure', () {
    for (final locale in [AppLocale.en, AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk]) {
      final strings = AndroidFolderStrings(locale);
      expect(strings.empty(3), contains('3'));
      for (final code in ['permission', 'unsupported', 'limit', 'duplicate', 'loading', 'busy', 'unavailable']) {
        expect(strings.error(code), isNotEmpty);
      }
    }
  });
}
