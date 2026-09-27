import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';

const _channel = MethodChannel('legnasend/ios_drop');

/// UIKit owns importing the source. Flutter freezes the destination before the
/// import starts and reports failures through the same in-app UI as other drops.
class IosDropController {
  final bool Function(Offset position) prepare;
  final void Function() failed;
  final MethodChannel channel;

  IosDropController({required this.prepare, required this.failed, this.channel = _channel});

  void attach() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'prepare') {
        final args = call.arguments;
        if (args is! List || args.length != 2 || args.any((value) => value is! num || !value.isFinite)) return false;
        return prepare(Offset((args[0] as num).toDouble(), (args[1] as num).toDouble()));
      }
      if (call.method == 'failed') failed();
      return null;
    });
  }

  void dispose() => channel.setMethodCallHandler(null);
}

/// Call only within SourceCacheCoordinator.cleanIfIdle after checking all source
/// references. Native code also refuses cleanup while a provider import is live.
Future<bool> clearImportedIosDrops() async => await _channel.invokeMethod<bool>('clearIfIdle') ?? false;

String iosDropFailureText(AppLocale locale) => switch (locale) {
  AppLocale.zhCn => '导入拖放文件失败。请检查文件权限和剩余空间，然后重试。',
  AppLocale.zhTw || AppLocale.zhHk => '匯入拖放檔案失敗。請檢查檔案權限與剩餘空間，然後重試。',
  _ => 'Could not import dropped files. Check file access and free space, then try again.',
};
