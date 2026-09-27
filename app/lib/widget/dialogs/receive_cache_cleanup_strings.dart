/// English fallback plus Simplified/Traditional Chinese for the maintenance UI.
class ReceiveCacheCleanupStrings {
  final String locale;
  const ReceiveCacheCleanupStrings(this.locale);
  bool get _zh => locale.toLowerCase().startsWith('zh');
  bool get _hant => ['tw', 'hk', 'hant'].any(locale.toLowerCase().contains);
  String _pick(String en, String zh, String hant) => !_zh ? en : (_hant ? hant : zh);

  String get title => _pick('Receive cache maintenance', '接收缓存管理', '接收快取管理');
  String get description => _pick(
    'Manual cleanup bypasses retention age for registered inactive receive files. Active transfers, completed files and unknown .ls files are kept. Android also checks registered provider transactions; interrupted writes and uncertain publications remain protected.',
    '手动清理忽略保留期，清理已登记且没有活动写入者的中断接收文件。保留活动传输、正式文件及未知 .ls 文件。Android 同时核对已登记的文档提供器事务，中断写入及不确定的发布结果保守保留。',
    '手動清理忽略保留期，清理已登記且沒有活動寫入者的中斷接收檔案。保留活動傳輸、正式檔案及未知 .ls 檔案。Android 同時核對已登記的文件提供者交易，中斷寫入及不確定的發布結果保守保留。',
  );
  String get inspect => _pick('Inspect without deleting', '只读盘点', '唯讀盤點');
  String get inspectNext => _pick('Inspect next batch', '盘点下一批', '盤點下一批');
  String get inspected => _pick('Read-only inspection completed', '只读盘点完成', '唯讀盤點完成');
  String get inspectionNote => _pick(
    'Inspection never deletes files and previews manual cleanup regardless of retention age. It covers registered ordinary paths, not Android provider documents. Cleanup rechecks identities and active locks; candidates may change.',
    '盘点不删除文件，按手动清理模式忽略保留期，仅覆盖已登记普通路径，不含 Android 提供器文档。执行清理时会重新核验身份与活动锁，候选结果可能变化。',
    '盤點不刪除檔案，依手動清理模式忽略保留期，僅涵蓋已登記一般路徑，不含 Android 提供者文件。執行清理時會重新核驗身分與活動鎖，候選結果可能變化。',
  );
  String get details => _pick('Individual entries', '逐项结果', '逐項結果');
  String get unknownEntry => _pick('Unverified entry', '待核验条目', '待核驗項目');
  String entryBytes(int planned, int removed) =>
      _pick('Planned $planned B · removed $removed B', '计划 $planned 字节 · 已删 $removed 字节', '計畫 $planned 位元組 · 已刪 $removed 位元組');
  String sourceKind(String code) => switch (code) {
    'nativeReceive' => _pick('Native receive', '原生接收', '原生接收'),
    'directoryUpload' => _pick('Workspace upload', '工作区上传', '工作區上傳'),
    _ => _pick('Unverified source', '来源待核验', '來源待核驗'),
  };
  String disposition(String code) => switch (code) {
    'candidate' => _pick('Eligible', '可清理', '可清理'),
    'removed' => _pick('Removed', '已删除', '已刪除'),
    'retired' => _pick('Record retired', '登记已清理', '登記已清理'),
    'active' => _pick('Active · protected', '活动中 · 已保护', '活動中 · 已保護'),
    'failed' => _pick('Failed · review result', '失败 · 请核对结果', '失敗 · 請核對結果'),
    _ => _pick('Retained', '已保留', '已保留'),
  };
  String get clean => _pick('Clean registered leftovers', '清理已登记残留', '清理已登記殘留');
  String get close => _pick('Close', '关闭', '關閉');
  String get retry => _pick('Check again', '重新检查', '重新檢查');
  String get resume => _pick('Continue cleanup', '继续清理', '繼續清理');
  String get busy => _pick('Checking registered caches… Transfers continue normally.', '正在检查已登记缓存…传输继续正常运行。', '正在檢查已登記快取…傳輸繼續正常執行。');
  String get bounded => _pick('Batch limit reached', '本轮已达处理上限', '本輪已達處理上限');
  String get completed => _pick('Scan completed', '本轮检查完成', '本輪檢查完成');
  String get partial => _pick('Some entries need attention', '部分条目需要处理', '部分項目需要處理');
  String get more => _pick('This bounded scan has more entries. Continue to inspect the next batch.', '本轮已达到处理上限，可继续检查下一批。', '本輪已達處理上限，可繼續檢查下一批。');
  String get interrupted => _pick(
    'Cleanup was interrupted. Completed removals are shown below; remaining entries were kept. Retry when storage is available.',
    '清理中断。下方显示此前已完成的删除，其余条目保留；存储可用后可重试。',
    '清理中斷。下方顯示此前已完成的刪除，其餘項目保留；儲存空間可用後可重試。',
  );
  String get bytesNote => _pick(
    'Planned bytes are verified cleanup candidates; removed bytes count successful unlinks only. Both are logical file lengths, not actual disk space released. Android provider document sizes are not included in byte totals. Results describe this scan, not a complete inventory.',
    '计划字节是通过核验的清理候选量，已删字节仅统计成功删除。两者均为逻辑长度，不代表实际释放的磁盘空间。字节统计不含 Android 提供器文档。结果仅表示本轮扫描，不是完整存量。',
    '計畫位元組是通過核驗的清理候選量，已刪位元組僅統計成功刪除。兩者均為邏輯長度，不代表實際釋放的磁碟空間。位元組統計不含 Android 提供者文件。結果僅表示本輪掃描，並非完整存量。',
  );
  String get examined => _pick('Entries checked', '检查条目', '檢查項目');
  String get files => _pick('Cache files removed', '已删缓存文件', '已刪快取檔案');
  String get records => _pick('Records retired', '已清理登记', '已清理登記');
  String get plannedBytes => _pick('Logical bytes planned', '计划清理逻辑字节', '計畫清理邏輯位元組');
  String get bytes => _pick('Logical bytes removed', '已删逻辑字节', '已刪邏輯位元組');
  String get active => _pick('Active — kept', '活动中 · 已保留', '活動中 · 已保留');
  String get retained => _pick('Unverified — kept', '待核验 · 已保留', '待核驗 · 已保留');
  String get failed => _pick('Storage failures', '存储失败', '儲存失敗');
  String reason(String code) => switch (code) {
    'durable_resume' => _pick('Persistent recovery records checked', '已核对持久续传登记', '已核對持久續傳登記'),
    'durable_resume_failed' => _pick('Persistent recovery storage needs review', '持久续传存储核对失败', '持久續傳儲存核對失敗'),
    'retention_period' => _pick('Retention period has not elapsed', '尚未达到保留期', '尚未達到保留期'),
    'retention_manual' => _pick('Manual retention is enabled', '已启用手动保留', '已啟用手動保留'),
    'retention_age_unknown' => _pick('Registration age is unknown', '登记时间未知', '登記時間未知'),
    'retention_clock_unverified' => _pick('Clock could not be verified', '时钟未通过核验', '時鐘未通過核驗'),
    'retention_unavailable' => _pick('Retention policy is not synchronized', '保留策略未同步', '保留策略未同步'),
    'SAF_ACTIVE_RECEIVE' || 'SAF_ACTIVE_LEASE' => _pick('Provider receive is active', '提供器接收进行中', '提供者接收進行中'),
    'SAF_INTERRUPTED_RECEIVE' => _pick('Interrupted provider write retained', '中断的提供器写入已保留', '中斷的提供者寫入已保留'),
    'SAF_PUBLICATION_RECONCILED' => _pick('Completed file verified after interruption', '已核对中断前保存的完整文件', '已核對中斷前儲存的完整檔案'),
    'SAF_PUBLICATION_RECONCILE_RETAINED' => _pick('Saved file could not be verified; kept unchanged', '保存结果暂未核实，文件保持不变', '儲存結果暫未核實，檔案保持不變'),
    'SAF_PUBLISHED_STAGING_DELETED' => _pick('Saved-file temporary copy removed', '已清理保存后的临时副本', '已清理儲存後的暫存副本'),
    'SAF_PUBLISHED_STAGING_PROOF_UNAVAILABLE' ||
    'SAF_PUBLISHED_STAGING_CLEANUP_RETAINED' => _pick('Temporary copy kept for a later check', '临时副本保留至下次核对', '暫存副本保留至下次核對'),
    'SAF_PUBLICATION_AMBIGUOUS' => _pick('Publication needs reconciliation', '发布结果待核对', '發布結果待核對'),
    'SAF_PUBLISHED_RECEIPT' => _pick('Published file receipt preserved', '已保留成品回执', '已保留成品回執'),
    'SAF_PUBLISHED_CACHE_RETAINED' => _pick('Published file preserved; cache needs review', '保留成品，缓存待核对', '保留成品，快取待核對'),
    'SAF_PERMISSION_DENIED' => _pick('Provider access revoked', '提供器授权已撤回', '提供者授權已撤回'),
    'SAF_JOURNAL_OR_PROVIDER_UNAVAILABLE' => _pick('Provider or journal unavailable', '提供器或登记暂不可用', '提供者或登記暫不可用'),
    'SAF_OWNERSHIP_UNPROVEN' ||
    'SAF_OWNERSHIP_CHANGED_OR_UNAVAILABLE' => _pick('Provider document identity not verified', '提供器文档身份未通过核验', '提供者文件身分未通過核驗'),

    'ios_scope_busy' => _pick('Folder is in use; kept for the next check', '目录使用中，保留至下次检查', '目錄使用中，保留至下次檢查'),
    'ios_scope_list_failed' => _pick('Saved folders could not be checked', '已保存目录暂时未能检查', '已儲存目錄暫時未能檢查'),
    'ios_scoped_maintenance_failed' => _pick('Folder access failed; remaining files kept', '目录访问失败，其余文件保留', '目錄存取失敗，其餘檔案保留'),
    'ios_scope_release_failed' => _pick('Folder check could not finish; further cleanup stopped', '目录检查未正常结束，已停止后续清理', '目錄檢查未正常結束，已停止後續清理'),
    'external_scope_required' => _pick('Files folder requires coordinated access; kept', '文件目录需要重新协调访问，已保留', '檔案目錄需要重新協調存取，已保留'),
    'permission_denied' => _pick('Permission denied; entry retained', '权限不足，登记保留', '權限不足，登記保留'),
    'registry_entry_io' || 'storage_error' => _pick('Storage access failed', '存储访问失败', '儲存存取失敗'),
    'unknown_registry_entry' => _pick('Unknown registry entry', '未知登记条目', '未知登記項目'),
    'registry_not_regular' || 'target_not_regular' => _pick('Not an ordinary file', '不是普通文件', '不是一般檔案'),
    'active_registration' || 'active_file' => _pick('Owned by an active writer', '存在活动写入者', '存在活動寫入者'),
    'invalid_registry_record' => _pick('Registry record could not be verified', '登记内容未通过核验', '登記內容未通過核驗'),
    'parent_unavailable' => _pick('Destination is offline or inaccessible', '目标目录离线或访问受限', '目標目錄離線或存取受限'),
    'parent_identity_unverified' => _pick('Directory identity could not be verified', '目录身份未通过核验', '目錄身分未通過核驗'),
    'already_absent' => _pick('File already absent; record retired', '文件已不存在，清理登记', '檔案已不存在，清理登記'),
    'file_identity_changed' || 'target_changed_during_cleanup' => _pick('File changed; kept', '文件身份变化，已保留', '檔案身分變化，已保留'),
    'cache_header_unverified' => _pick('Cache header could not be verified', '缓存头未通过核验', '快取標頭未通過核驗'),
    'interrupted_directory_upload' => _pick('Interrupted workspace upload removed', '已清理中断的工作区上传', '已清理中斷的工作區上傳'),
    'non_resumable_receive_attempt' => _pick('Inactive non-resumable receive removed', '已清理不支持续传的非活动接收', '已清理不支援續傳的非活動接收'),
    _ => _pick('Other diagnostic', '其他诊断原因', '其他診斷原因'),
  };
}
