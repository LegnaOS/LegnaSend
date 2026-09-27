import 'package:localsend_app/gen/strings.g.dart';

class NativeResumeStrings {
  final AppLocale locale;
  const NativeResumeStrings(this.locale);
  String _text(String en, String cn, String tw) => switch (locale) {
    AppLocale.zhCn => cn,
    AppLocale.zhTw || AppLocale.zhHk => tw,
    _ => en,
  };
  String get title => _text('Connection recovery', '断线恢复说明', '斷線還原說明');
  String get explanation => _text(
    'Compatible LegnaSend peers can negotiate verified-block recovery for files of at least 1 MiB saved to ordinary folders. When both support durable recovery and the sender saves a stable source record, retry after a session change or restart can reuse verified blocks after fresh approval and source validation. Cache verification is not network transfer. Without that capability, manual retry resends the whole file; original LocalSend, gallery and document-provider destinations remain compatible. Explicit cancellation or changed sources end active recovery. A lost suspension reply leaves retention unconfirmed, not saved successfully. This note describes capabilities, not confirmation that this file negotiated them.',
    '兼容的 LegnaSend 双方可为保存到普通文件夹、至少 1 MiB 的文件协商已校验块恢复。双方支持持久恢复且发送端已保存稳定来源记录时，跨会话或重启后重试可在重新批准、核验来源后复用已校验块。缓存核验不是网络传输。未具备该能力时，手动重试仍重发整文件；原版 LocalSend、相册与文档提供程序目标保持兼容。明确取消或来源变化会结束活动恢复。暂停响应丢失时仅表示保留状态未确认，不代表已保存成功。本说明介绍能力，不代表当前文件已协商启用。',
    '相容的 LegnaSend 雙方可為儲存至一般資料夾、至少 1 MiB 的檔案協商已驗證區塊還原。雙方支援持久還原且傳送端已儲存穩定來源紀錄時，跨工作階段或重新啟動後重試可在重新批准、驗證來源後重用已驗證區塊。快取驗證不是網路傳輸。未具備此能力時，手動重試仍重傳整個檔案；原版 LocalSend、相簿與文件提供者目的地保持相容。明確取消或來源變更會結束活動還原。暫停回應遺失時僅表示保留狀態未確認，不代表已儲存成功。本說明介紹能力，不代表目前檔案已協商啟用。',
  );
}
