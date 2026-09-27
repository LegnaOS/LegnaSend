import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/send_route_strings.dart';

/// Fork-owned recovery copy with English fallback for untranslated locales.
class SendRecoveryStrings {
  final AppLocale locale;
  const SendRecoveryStrings(this.locale);
  bool get _zh => locale == AppLocale.zhCn || locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  bool get _traditional => locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  String _text(String en, String zh, String hant) => !_zh ? en : (_traditional ? hant : zh);
  String get restored => _text('Restored · waiting to continue', '已恢复，等待继续', '已還原，等待繼續');
  String get continuing => _text('Restored · continuing', '已恢复，继续发送中', '已還原，繼續傳送中');
  String get queued => _text('Restored · queued', '已恢复，已加入队列', '已還原，已加入佇列');
  String get completed => _text('Restored · already completed', '已恢复，已全部完成', '已還原，已全部完成');
  String get resume => _text('Continue unfinished files', '继续未完成文件', '繼續未完成檔案');
  String get checking => _text('Checking files and device…', '正在核验文件与设备…', '正在核驗檔案與裝置…');
  String summary(int completed, int skipped, int remaining) => _text(
    '$completed confirmed · $skipped skipped · $remaining remaining',
    '已确认 $completed · 已跳过 $skipped · 剩余 $remaining',
    '已確認 $completed · 已略過 $skipped · 剩餘 $remaining',
  );
  String issue(String code) => switch (code) {
    'retainedConfirmed' => _text(
      'Connection interrupted. The receiver retained verified blocks. Retry after reconnecting; approval is required again.',
      '连接中断，接收端已保留校验通过的数据块。重新连接后可重试，仍需再次批准。',
      '連線中斷，接收端已保留驗證通過的資料區塊。重新連線後可重試，仍須再次批准。',
    ),
    'retainedUnknown' => _text(
      'Connection interrupted. Retention is not confirmed. Reconnect and retry to check; the receiver may need time to release the old session.',
      '连接中断，尚未确认缓存保留状态。请重新连接后重试核验，接收端可能需要时间释放旧会话。',
      '連線中斷，尚未確認快取保留狀態。請重新連線後重試核驗，接收端可能需要時間釋放舊工作階段。',
    ),
    'selectedLocalRouteUnavailable' => SendRouteStrings(locale).localRouteUnavailable,
    'sourceMissing' => _text(
      'A source file is missing. Restore it to its original location, then continue.',
      '源文件已丢失。请恢复到原位置后继续。',
      '來源檔案已遺失。請還原至原位置後繼續。',
    ),
    'sourceChanged' => _text(
      'A source file has changed. Select the updated files and create a new send.',
      '源文件已变化。请选择更新后的文件重新创建发送任务。',
      '來源檔案已變更。請選擇更新後的檔案重新建立傳送工作。',
    ),
    'sourcePermission' => _text(
      'Source access has expired. Grant access again or select the files for a new send.',
      '源文件访问权限已失效。请重新授权，或重新选择文件发送。',
      '來源檔案存取權限已失效。請重新授權，或重新選擇檔案傳送。',
    ),
    'unsupported' => _text(
      'This source cannot be restored after restart. Select the files for a new send.',
      '此来源不支持重启后恢复，请重新选择文件发送。',
      '此來源不支援重新啟動後還原，請重新選擇檔案傳送。',
    ),
    'peerUnavailable' => _text(
      'The receiving device has not been rediscovered. Connect both devices and scan, then continue.',
      '尚未重新发现接收设备。请连接双方设备并刷新发现，然后继续。',
      '尚未重新探索到接收裝置。請連接雙方裝置並重新探索，然後繼續。',
    ),
    'recoveryInUse' => _text(
      'Another LegnaSend instance is using these recovery records. New sends here remain available but are not saved for restart recovery. Close the other instance, then restart this one to restore its tasks.',
      '另一个 LegnaSend 实例正在使用这些恢复记录。当前仍可新建发送，但不会保存为重启恢复任务。请关闭另一实例后重新启动当前实例，再恢复已有任务。',
      '另一個 LegnaSend 執行個體正在使用這些還原紀錄。目前仍可建立傳送，但不會儲存為重新啟動後還原的工作。請關閉另一個執行個體後重新啟動目前的執行個體，再還原既有工作。',
    ),
    'busy' => _text(
      'Another send still uses these recovery files. Finish or remove that send first.',
      '其他发送任务仍在使用这些恢复文件，请先完成或删除相关任务。',
      '其他傳送工作仍在使用這些還原檔案，請先完成或刪除相關工作。',
    ),
    'cleanupStorage' => _text(
      'Cleanup notifications are temporarily unavailable. You can still start new sends.',
      '清理通知暂不可用，仍可新建发送。',
      '清理通知暫不可用，仍可建立傳送。',
    ),
    'storage' => _text(
      'Recovery records could not be saved. Check free space and storage access, then retry.',
      '恢复记录保存失败。请检查剩余空间与存储权限后重试。',
      '還原紀錄儲存失敗。請檢查剩餘空間與儲存權限後重試。',
    ),
    'corrupt' => _text(
      'Some recovery records are damaged and were not loaded. Select the files again to send.',
      '部分恢复记录已损坏，未加载。请重新选择文件发送。',
      '部分還原紀錄已損毀，未載入。請重新選擇檔案傳送。',
    ),
    _ => _text(
      'This send needs attention before it can continue. Check the source files and receiving device.',
      '此发送任务需要核验后再继续，请检查源文件和接收设备。',
      '此傳送工作需要核驗後再繼續，請檢查來源檔案與接收裝置。',
    ),
  };
}
