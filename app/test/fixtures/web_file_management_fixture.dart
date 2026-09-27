import 'package:localsend_app/model/state/send/web/web_download_file.dart';
import 'package:localsend_app/model/state/send/web/web_download_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'transfer_fixtures.dart';

class ManagedFileServer extends ServerService {
  ManagedFileServer({this.count = 3});
  final int count;
  int epoch = 7;
  @override
  int get generation => epoch;
  @override
  ServerState init() => ServerState(
    alias: 'LegnaSend',
    port: 53318,
    https: false,
    session: incoming('parallel'),
    web: WebShareDownload(
      pin: null,
      duplex: true,
      allowUpload: true,
      state: WebDownloadState(
        files: {
          for (int i = 0; i < count; i++)
            'file-$i': WebDownloadFile(file: transferFile('file-$i', 4000), asset: null, path: '/source/file-$i', bytes: null),
        },
        sessions: {},
        autoAccept: true,
      ),
    ),
  );
  void receiveUpdate() => state = state!.copyWith(session: incoming('updated-receive'));
  void changeShare() {
    epoch++;
    state = init();
  }
}
