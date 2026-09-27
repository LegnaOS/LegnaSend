import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';

void main() {
  test('workspace updates retain upload permission and both directions across serialization', () {
    const state = ServerState(
      alias: 'Fixture',
      port: 53318,
      https: true,
      session: null,
      web: WebShareDownload(
        pin: 'pin',
        duplex: true,
        allowUpload: true,
        state: WebDownloadState(files: {}, sessions: {}, autoAccept: false),
      ),
    );
    final updated = state.updateWebDownloadState((download) => download.copyWith(autoAccept: true));
    final restored = ServerStateMapper.deserialize(updated.serialize());
    expect(restored.webUpload, isTrue);
    expect((restored.web as WebShareDownload).duplex, isTrue);
    expect(restored.webDownloadState!.autoAccept, isTrue);
    expect(restored.web!.pin, 'pin');
    expect(restored.copyWith(web: (restored.web as WebShareDownload).copyWith(allowUpload: false)).webUpload, isFalse);
  });
}
