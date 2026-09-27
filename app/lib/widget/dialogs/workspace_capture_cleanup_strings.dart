class WorkspaceCaptureCleanupStrings {
  final String locale;
  const WorkspaceCaptureCleanupStrings(this.locale);
  bool get _zh => locale.toLowerCase().startsWith('zh');
  bool get _hant => ['tw', 'hk', 'hant'].any(locale.toLowerCase().contains);
  String _s(String en, String zh, String hant) => !_zh
      ? en
      : _hant
      ? hant
      : zh;
  String get title => _s('Workspace export cleanup', '工作区导出缓存管理', '工作區匯出快取管理');
  String get description => _s(
    'Clean registered interrupted export copies in private application storage. Original workspace files, downloaded files and persistent send tasks are kept. Unknown entries are retained, not force-deleted.',
    '清理应用私有存储中已登记的中断导出副本。保留工作区原文件、下载成品和持久发送任务；未知条目保留，不强制删除。',
    '清理應用私有儲存中已登記的中斷匯出副本。保留工作區原始檔案、下載成品和持久傳送任務；未知項目保留，不強制刪除。',
  );
  String get clean => _s('Clean inactive exports', '清理非活动导出', '清理非活動匯出');
  String get retry => _s('Retry cleanup', '重试清理', '重試清理');
  String get close => _s('Close', '关闭', '關閉');
  String get busy => _s('Cleaning in bounded batches…', '正在分批清理…', '正在分批清理…');
  String get completed => _s('Cleanup finished', '清理已结束', '清理已結束');
  String get partial => _s('Some entries were retained', '部分条目已保留', '部分項目已保留');
  String get failed => _s('Cleanup interrupted; retry when storage is available.', '清理中断，存储恢复后可重试。', '清理中斷，儲存恢復後可重試。');
  String get unavailable => _s('Private export storage is not configured.', '私有导出存储尚未配置。', '私有匯出儲存尚未設定。');
  String get note => _s(
    'Counts cover the latest maintenance pass, including automatic continuation batches. Bytes are successfully unlinked logical bytes, not guaranteed physical free space. Closing this panel does not stop cleanup or transfers.',
    '统计包含最近一次维护及其自动续扫批次。字节仅表示已成功移除的逻辑长度，不等于磁盘实际释放空间。关闭面板不会停止清理或传输。',
    '統計包含最近一次維護及其自動續掃批次。位元組僅表示已成功移除的邏輯長度，不等於磁碟實際釋放空間。關閉面板不會停止清理或傳輸。',
  );
  List<String> get rows => [
    _s('Examined', '已核对', '已核對'),
    _s('Removed exports', '已删除导出', '已刪除匯出'),
    _s('Removed files', '已删除文件', '已刪除檔案'),
    _s('Unlinked bytes', '已移除字节', '已移除位元組'),
    _s('Active — kept', '活动中，保留', '活動中，保留'),
    _s('Unknown or unsafe — kept', '未知或不安全，保留', '未知或不安全，保留'),
    _s('Failed — retained', '失败，保留', '失敗，保留'),
    _s('Batches', '批次', '批次'),
  ];
}
