import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/transfer_activity.dart';

class WebTransferActivityStrings {
  final AppLocale locale;
  const WebTransferActivityStrings(this.locale);
  String _text(String en, String cn, String tw) => switch (locale) {
    AppLocale.zhCn => cn,
    AppLocale.zhTw || AppLocale.zhHk => tw,
    _ => en,
  };
  String get kind => _text('Browser download', '浏览器下载', '瀏覽器下載');
  String get detail => _text(
    'Bytes represent this HTTP response only, including a requested range or ZIP. Stream completion does not confirm that the browser saved the file. Cancel stops only this response; sharing and other transfers continue.',
    '字节数仅表示本次 HTTP 响应，包括分段或 ZIP。流完成不代表浏览器已保存文件。取消仅停止本次响应，共享服务及其他传输继续运行。',
    '位元組數僅表示本次 HTTP 回應，包括分段或 ZIP。串流完成不代表瀏覽器已儲存檔案。取消僅停止本次回應，共享服務及其他傳輸繼續運行。',
  );
  String phase(TransferPhase value, String fallback) => switch (value) {
    TransferPhase.succeeded => _text('Response streamed', '响应流已发送', '回應串流已傳送'),
    TransferPhase.preparing => _text('Opening source', '正在打开源文件', '正在開啟來源檔案'),
    _ => fallback,
  };
  String bytes(String sent) => _text('$sent streamed · total unknown', '已发送 $sent · 总大小未知', '已傳送 $sent · 總大小未知');
  String operationLabel(TransferActivity task) => switch (task.operation) {
    'upload' => _text('Upload', '上传', '上傳'),
    'directory' => _text('Create directory', '创建目录', '建立目錄'),
    'archive' => 'ZIP',
    _ => _text('Download', '下载', '下載'),
  };
  String sourceLabel(TransferActivity task) => task.origin == 'api' ? _text('API request', 'API 请求', 'API 請求') : _text('Browser', '浏览器', '瀏覽器');
  String phaseFor(TransferActivity task, String fallback) {
    if (task.direction == TransferDirection.receive) {
      return switch (task.phase) {
        TransferPhase.succeeded => task.operation == 'directory' ? _text('Directory created', '目录已创建', '目錄已建立') : _text('Saved', '已保存', '已儲存'),
        TransferPhase.preparing => _text('Preparing destination', '正在准备保存位置', '正在準備儲存位置'),
        _ => fallback,
      };
    }
    return phase(task.phase, fallback);
  }

  String bytesFor(TransferActivity task, String count) => task.direction == TransferDirection.receive
      ? _text('$count received · total unknown', '已接收 $count · 总大小未知', '已接收 $count · 總大小未知')
      : bytes(count);
  String get unconfirmed => _text('Status unconfirmed', '状态未确认', '狀態未確認');
  String get unknownDetail => _text(
    'The listener stopped before the final outcome was observed. Publication may still complete. Pending results are checked automatically; no save or cancellation is assumed. Check the workspace before retrying.',
    '监听器停止时尚未确认最终结果，发布仍可能完成。未决结果会自动检查，不推断保存成功或取消；重试前请先检查工作区。',
    '監聽器停止時尚未確認最終結果，發佈仍可能完成。未決結果會自動檢查，不推斷儲存成功或取消；重試前請先檢查工作區。',
  );
  String get help => _text('Transfer details', '传输说明', '傳輸說明');
  String detailFor(TransferActivity task) => task.phase == TransferPhase.unconfirmed
      ? unknownDetail
      : task.direction == TransferDirection.receive
      ? _text(
          'Bytes are received upload data. Saved confirms successful server publication; directory creation has no file payload. Cancel targets only this request, not the workspace or other transfers.',
          '字节数表示已接收的上传数据。“已保存”表示服务端成功发布；创建目录没有文件内容。取消只针对本次请求，不关闭工作区或影响其他传输。',
          '位元組數表示已接收的上傳資料。「已儲存」表示伺服器成功發佈；建立目錄沒有檔案內容。取消只針對本次請求，不關閉工作區或影響其他傳輸。',
        )
      : detail;
  String get ended => _text('Finishing or already ended', '正在完成或已结束', '正在完成或已結束');
  String get cancelFailed => _text('Cancellation failed. Refresh the task state and retry.', '取消失败，请等待状态刷新后重试。', '取消失敗，請等待狀態重新整理後重試。');
}
