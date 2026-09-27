class ApiKeyStrings {
  final String locale;
  const ApiKeyStrings(this.locale);
  String _t(String en, String zh, String tw) => !locale.startsWith('zh') ? en : (locale.contains('TW') || locale.contains('HK') ? tw : zh);
  String get operation => _t('Credential administration', '密钥管理操作', '密鑰管理操作');
  String get confirm => _t('Confirm key operation', '确认密钥操作', '確認密鑰操作');
  String get cancel => _t('Cancel', '取消', '取消');
  String get close => _t('Close and forget', '关闭并清除', '關閉並清除');
  String get hint => _t(
    'Only explicit keys.manage and global * authorize these actions. Grants cannot exceed your own. Self-management is excluded. Keep the same request ID after an unknown outcome; replay returns only a receipt.',
    '须明确 keys.manage 和全局 * 授权，不能授予超出自身的权限，也不能管理当前调用密钥。结果未知时保留相同请求 ID，重放仅返回回执。',
    '須明確 keys.manage 及全域 * 授權，不可授予超出自身的權限，也不可管理目前呼叫密鑰。結果未知時保留相同請求 ID，重放僅回傳回執。',
  );
  String get secretTitle => _t('One-time key secret', '一次性密钥秘密', '一次性密鑰秘密');
  String get secretHint => _t(
    'Shown only here once. Closing clears this page copy. If the response was lost, inspect its receipt and revoke/recreate the key; the secret is not recoverable.',
    '秘密仅在此显示一次，关闭清除页面副本。响应丢失时先查询回执，再撤销并重建密钥；秘密不支持找回。',
    '秘密僅在此顯示一次，關閉清除頁面副本。回應遺失時先查詢回執，再撤銷並重建密鑰；秘密不支援找回。',
  );
  String get unknown => _t(
    'Outcome unknown. Keep the request ID and query its receipt before any new request.',
    '结果未知。保留请求 ID，先查询回执，再决定新操作。',
    '結果未知。保留請求 ID，先查詢回執，再決定新操作。',
  );
  String field(String field) => switch (field) {
    'version' => _t('Key set version (read first)', '密钥集合版本（先读取）', '密鑰集合版本（先讀取）'),
    'scopes' => _t('Scopes (comma separated)', '权限范围（逗号分隔）', '權限範圍（逗號分隔）'),
    'workspaces' => _t('Workspace IDs or * (comma separated)', '工作区 ID 或 *（逗号分隔）', '工作區 ID 或 *（逗號分隔）'),
    'expiresAt' => _t('Expiry Unix seconds (empty: no expiry)', '到期 Unix 秒（空为不过期）', '到期 Unix 秒（空為不過期）'),
    _ => field,
  };
}
