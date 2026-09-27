/// Stable compare-and-clear input captured before the confirmation dialog.
/// Deliberately excludes credentials, paths and raw request payloads.
class ApiHistoryClearTarget {
  final String instanceId;
  final int generation;
  final int throughSequence;
  const ApiHistoryClearTarget(this.instanceId, this.generation, this.throughSequence);

  factory ApiHistoryClearTarget.fromPage(Map<String, dynamic> page) {
    final instance = page['instanceId'];
    if (instance is! String || !RegExp(r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$').hasMatch(instance)) {
      throw const FormatException('Invalid history identity');
    }
    int number(Object? value, int minimum) {
      if (value is! int || value < minimum || value > 0x1fffffffffffff) throw const FormatException('Invalid history version');
      return value;
    }

    return ApiHistoryClearTarget(instance, number(page['generation'], 1), number(page['latest'], 0));
  }

  Map<String, Object> get body => {'instanceId': instanceId, 'expectedGeneration': generation, 'throughSequence': throughSequence};
  int validateResult(Map<String, dynamic> result) {
    if (result['instanceId'] != instanceId ||
        result['generation'] != generation + 1 ||
        result['throughSequence'] != throughSequence ||
        result['removed'] is! int ||
        (result['removed'] as int) < 0 ||
        (result['removed'] as int) > 200 ||
        result['latest'] is! int ||
        (result['latest'] as int) <= throughSequence) {
      throw const FormatException('Unconfirmed history result');
    }
    return result['removed'] as int;
  }
}

class ApiHistoryControlStrings {
  final String language;
  const ApiHistoryControlStrings(this.language);
  String _copy(String en, String cn, String tw) => !language.startsWith('zh')
      ? en
      : language.contains('TW') || language.contains('HK')
      ? tw
      : cn;
  String get title => _copy('Clear request history', '清空请求记录', '清除請求記錄');
  String get confirm => _copy('Clear observed records', '清空已查看记录', '清除已查看記錄');
  String get cancel => _copy('Cancel', '取消', '取消');
  String get close => _copy('Close', '关闭', '關閉');
  String get explanation => _copy(
    'Requires requests.read and requests.manage on a key with the * workspace grant. Removes only the in-memory records through the captured sequence. New completions, active transfers and rate limits are unchanged. A redacted clear marker remains. Device log files are not deleted.',
    '需要密钥具有 requests.read、requests.manage 和 * 工作区授权。仅移除本次读取序号之前的内存记录；新完成请求、活动传输和限流保持不变。保留脱敏清空标记，不删除设备日志文件。',
    '需要密鑰具有 requests.read、requests.manage 及 * 工作區授權。僅移除本次讀取序號之前的記憶體記錄；新完成請求、活動傳輸與速率限制保持不變。保留已脫敏清除標記，不刪除裝置日誌檔案。',
  );
  String get failed => _copy(
    'History was not confirmed cleared. Refresh and check the key permissions before trying again.',
    '尚未确认清空成功。请刷新并检查密钥权限后再试。',
    '尚未確認清除成功。請重新整理並檢查密鑰權限後再試。',
  );
  String get changed => _copy(
    'The listener or history changed. Nothing was cleared by this attempt; refresh before confirming again.',
    '监听或记录代次已变化，本次未清空；请刷新后重新确认。',
    '監聽或記錄代次已變更，本次未清除；請重新整理後再次確認。',
  );
  String result(int count) => _copy(
    'Cleared $count observed records; new completions and the clear marker remain.',
    '已清空 $count 条已查看记录；新完成记录与清空标记保留。',
    '已清除 $count 筆已查看記錄；新完成記錄與清除標記保留。',
  );
}
