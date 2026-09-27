import 'package:localsend_app/gen/strings.g.dart';

class ChannelHealthStrings {
  final AppLocale locale;
  const ChannelHealthStrings(this.locale);
  String _text(String en, String zh, String hant) => switch (locale) {
    AppLocale.zhCn => zh,
    AppLocale.zhTw || AppLocale.zhHk => hant,
    _ => en,
  };
  String get check => _text('Check entry', '检测入口', '檢查入口');
  String get checking => _text('Checking…', '检测中…', '檢查中…');
  String get reachable => _text('Reachable', '可达', '可達');
  String get unreachable => _text('Unreachable', '不可达', '無法連線');
  String get unknown => _text('Not checked / expired', '未检测 / 已过期', '未檢查 / 已過期');
  String get hint => _text(
    'Checks only this entry using the selected outgoing network. Results expire after 60 seconds. No files are sent; a failed entry does not mark the device offline. HTTPS pins its certificate; HTTP identity is not authenticated.',
    '使用所选本机出口，仅检测此入口，结果60秒后过期。不发送文件，单入口失败不代表设备离线。HTTPS固定证书指纹；HTTP身份未经证书认证。',
    '使用所選本機出口，僅檢查此入口，結果60秒後過期。不傳送檔案，單入口失敗不代表裝置離線。HTTPS固定憑證指紋；HTTP身分未經憑證認證。',
  );
}
