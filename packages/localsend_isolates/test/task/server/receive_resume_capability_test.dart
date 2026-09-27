import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/task/server/receive_resume_capability.dart';

void main() {
  test('only accepted ordinary-path large files negotiate; no original checksum requirement', () {
    List<String> ids(String directory, {bool gallery = false, int? sdk}) => resumableReceiveFileIds(
      destinationDirectory: directory,
      saveToGallery: gallery,
      androidSdkInt: sdk,
      acceptedIds: ['small', 'large', 'unknown'],
      sizes: {'small': 1048575, 'large': 1048576, 'unaccepted': 2000000},
    );
    expect(ids('/fixture/downloads'), ['large']);
    expect(ids('/storage/emulated/0/Download', sdk: 35), ['large']);
    expect(ids('/fixture/downloads', gallery: true), isEmpty);
    expect(ids('content://provider/tree/root', sdk: 35), isEmpty);
    expect(ids('/storage/ABCD-1234/Download', sdk: 35), isEmpty);
    expect(ids('relative'), isEmpty);
  });
}
