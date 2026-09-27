class ApiManagementStrings {
  final String language;
  const ApiManagementStrings(this.language);
  String _pick(String en, String cn, String tw) => !language.startsWith('zh')
      ? en
      : language.contains('TW') || language.contains('HK')
      ? tw
      : cn;
  String get operation => _pick('Manage workspace · confirmation required', '管理工作区 · 需要确认', '管理工作區 · 需要確認');
  String get action => _pick('Action', '操作', '操作');
  String get unchanged => _pick('Leave unchanged', '保持不变', '保持不變');
  String get yes => _pick('Enabled', '开启', '開啟');
  String get no => _pick('Disabled', '关闭', '關閉');
  String get name => _pick('Workspace name (optional)', '工作区名称（可选）', '工作區名稱（選填）');
  String get visible => _pick('Visible in workspace index', '在工作区索引中可见', '在工作區索引中可見');
  String get allowUpload => _pick('Allow browser uploads', '允许网页上传', '允許網頁上傳');
  String get emptyUpdate =>
      _pick('Choose at least one change: name, visibility or browser upload permission.', '请至少修改一项：名称、可见性或网页上传权限。', '請至少修改一項：名稱、可見性或網頁上傳權限。');
  String get hint => _pick(
    'Read the current generation from managed workspaces before changing it. Omitted fields are not changed; requests are never retried automatically.',
    '请先从管理列表读取当前 generation；未设置的字段保持不变，请求不会自动重试。',
    '請先從管理清單讀取目前 generation；未設定的欄位保持不變，請求不會自動重試。',
  );
  String get confirmTitle => _pick('Confirm workspace change', '确认工作区变更', '確認工作區變更');
  String get target => _pick('Workspace', '工作区', '工作區');
  String get changes => _pick('Changes', '变更内容', '變更內容');
  String get confirm => _pick('Confirm change', '确认变更', '確認變更');
  String get cancel => _pick('Cancel', '取消', '取消');
  String get destroy => _pick(
    'Destroy removes the share metadata and disables access. Files in the local directory are not deleted.',
    '销毁将移除共享配置并关闭访问，不删除本地目录中的文件。',
    '銷毀將移除分享設定並關閉存取，不刪除本機目錄中的檔案。',
  );
  String get review => _pick(
    'Inspect the actual HTTP status and response before another change. A timeout may have an unknown outcome; saved settings awaiting synchronization are not a rollback. Read the managed workspace again before retrying.',
    '再次变更前，请检查实际 HTTP 状态和响应。超时可能结果未知；已保存但待同步不代表回滚。请重新读取管理列表后再决定是否重试。',
    '再次變更前，請檢查實際 HTTP 狀態與回應。逾時可能結果未知；已儲存但待同步不代表復原。請重新讀取管理清單後再決定是否重試。',
  );
  String get unknown => _pick(
    'The request ended without a confirmed result. The change may already be saved; read the managed workspace before retrying.',
    '请求结束，但未确认最终结果。变更可能已经保存，请先重新读取工作区状态再决定是否重试。',
    '請求已結束，但尚未確認最終結果。變更可能已儲存，請先重新讀取工作區狀態再決定是否重試。',
  );
  String actionLabel(String value) => switch (value) {
    'update' => _pick('Update settings', '更新设置', '更新設定'),
    'enable' => _pick('Enable sharing', '开启共享', '開啟分享'),
    'disable' => _pick('Disable sharing', '关闭共享', '關閉分享'),
    'validate' => _pick('Validate local directory', '验证本地目录', '驗證本機目錄'),
    'configure' => _pick('Change source / route (closed only)', '更换来源／路径（仅已关闭工作区）', '更換來源／路徑（僅已關閉工作區）'),
    'password' => _pick('Set or clear password / PIN', '设置或清除密码／PIN', '設定或清除密碼／PIN'),
    'destroy' => _pick('Destroy workspace share', '销毁工作区共享', '銷毀工作區分享'),
    _ => value,
  };
}
