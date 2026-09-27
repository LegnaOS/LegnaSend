class SourceEndStrings {
  final String locale;
  const SourceEndStrings(this.locale);
  String _p(String en, String zh, String hant) => !locale.toLowerCase().startsWith('zh')
      ? en
      : RegExp('tw|hk|hant', caseSensitive: false).hasMatch(locale)
      ? hant
      : zh;
  String get title => _p('Source cleanup notices', '来源结束通知', '來源結束通知');
  String get detail => _p(
    'Only acknowledged removal confirms cleanup. Active transfers and published files are preserved. Offline or expired notices do not prove deletion.',
    '只有接收端确认删除才算清理完成；活动传输和已发布文件保留。离线或通知过期不代表已经删除。',
    '只有接收端確認刪除才算清理完成；活動傳輸與已發布檔案保留。離線或通知過期不代表已經刪除。',
  );
  String get capacity => _p(
    'Some files have no cleanup-notice authorization. Ordinary transfer remains available.',
    '部分文件未启用清理通知授权，普通传输仍可使用。',
    '部分檔案未啟用清理通知授權，一般傳輸仍可使用。',
  );
  String get empty => _p('No cleanup notices', '暂无清理通知', '暫無清理通知');
  String get unavailable => _p('Private notification storage is unavailable. No cleanup is confirmed.', '私有通知存储暂不可用，未确认任何清理。', '私有通知儲存暫不可用，未確認任何清理。');
  String get retry => _p('Retry notice', '重试通知', '重試通知');
  String get help => _p('Cleanup details', '清理说明', '清理說明');
  String get receiptTitle => _p('Receiver cleanup receipt', '接收端清理回执', '接收端清理回執');
  String get receiptId => _p('Receipt ID', '回执编号', '回執編號');
  String get noReceipt => _p(
    'No itemized cleanup receipt is available.',
    '暂无包含实际清理数量的回执。',
    '暫無包含實際清理數量的回執。',
  );
  String get logicalBytesDetail => _p(
    'These are logical bytes of removed temporary files, not measured physical disk space reclaimed. Published files are not included.',
    '这是已移除临时文件的逻辑字节数，不是实际释放磁盘空间的测量值，不包含已发布文件。',
    '這是已移除暫存檔案的邏輯位元組數，不是實際釋放磁碟空間的測量值，不包含已發布檔案。',
  );
  String removedFiles(int count) => _p(
    'Temporary files removed: $count',
    '已移除临时文件：$count',
    '已移除暫存檔案：$count',
  );
  String logicalBytes(int bytes, String readable) => _p(
    'Logical size: $readable ($bytes bytes)',
    '逻辑大小：$readable（$bytes 字节）',
    '邏輯大小：$readable（$bytes 位元組）',
  );
  String cleanupSummary(int count, String readable) => _p(
    '$count temporary files removed · $readable logical',
    '已移除 $count 个临时文件 · 逻辑大小 $readable',
    '已移除 $count 個暫存檔案 · 邏輯大小 $readable',
  );
  String state(String code) => switch (code) {
    'pending' => _p('Pending notification', '待通知', '待通知'),
    'waitingPeer' => _p('Waiting for verified peer / route', '等待设备身份与路线核验', '等待裝置身分與路線核驗'),
    'sharedSource' => _p('Shared by another task · retained', '其他任务仍使用 · 保留', '其他任務仍使用 · 保留'),
    'busy' => _p('Receiver busy · retained', '接收端忙 · 保留', '接收端忙 · 保留'),
    'authorizationRequired' => _p('Authorization required · unconfirmed', '需要重新授权 · 未确认清理', '需要重新授權 · 未確認清理'),
    'removed' => _p('Receiver confirmed removal', '接收端已确认删除', '接收端已確認刪除'),
    'publishedPreserved' => _p('Published file preserved', '已发布文件保留', '已發布檔案保留'),
    'expired' => _p('Notice expired · cleanup unconfirmed', '通知已过期 · 未确认清理', '通知已過期 · 未確認清理'),
    'unsupported' => _p('Peer does not support cleanup notices', '对端不支持清理通知', '對端不支援清理通知'),
    'superseded' => _p('Old authorization replaced · not a removal receipt', '旧授权已替换 · 不代表已删除', '舊授權已替換 · 不代表已刪除'),
    _ => _p('Cleanup not confirmed', '未确认清理', '未確認清理'),
  };
  bool retryable(String state) => !const {'removed', 'publishedPreserved', 'expired', 'unsupported', 'superseded'}.contains(state);
}
