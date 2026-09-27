class ApiSourceStrings {
  final String language;
  const ApiSourceStrings(this.language);
  String _s(String en, String cn, String tw) => !language.startsWith('zh')
      ? en
      : language.contains('TW') || language.contains('HK')
      ? tw
      : cn;
  String get sources => _s('Approved API sources', 'API 已批准来源', 'API 已核准來源');
  String get approve => _s('Approve local directory', '批准本地目录', '核准本機目錄');
  String get name => _s('Source name', '来源名称', '來源名稱');
  String get revoke => _s('Revoke source approval', '撤销来源批准', '撤銷來源核准');
  String get confirm => _s('Confirm', '确认', '確認');
  String get cancel => _s('Cancel', '取消', '取消');
  String get copy => _s('Copy source ID', '复制来源 ID', '複製來源 ID');
  String get failed => _s('The source change was not saved.', '来源变更未保存。', '來源變更未儲存。');
  String get hint => _s(
    'Only local confirmation creates a source reference. API keys need workspaces.manage and the * workspace grant to list sources or create closed workspaces. Native paths are never returned by the API.',
    '只有本地确认才能批准来源。API 密钥须拥有 workspaces.manage 和 * 工作区授权，才能查询来源或创建已关闭的工作区。API 不返回本地路径。',
    '只有本機確認才能核准來源。API 密鑰須擁有 workspaces.manage 和 * 工作區授權，才能查詢來源或建立已關閉的工作區。API 不回傳本機路徑。',
  );
  String get approveHint => _s(
    'Allow authorized API clients to create workspaces backed by this directory? New workspaces start closed; authorized managers may later enable them for remote access. This does not grant a filesystem permission missing from the app.',
    '允许已授权 API 客户端以此目录创建工作区？新工作区初始关闭；获授权的管理客户端可随后启用远程访问。这不会授予应用原本没有的文件系统权限。',
    '允許已授權 API 客戶端以此目錄建立工作區？新工作區初始關閉；獲授權的管理客戶端可隨後啟用遠端存取。這不會授予應用原本沒有的檔案系統權限。',
  );
  String get revokeHint => _s(
    'Future API creation and source changes using this reference are blocked. Existing workspaces remain unchanged; disable them separately if needed.',
    '阻止 API 后续使用此引用创建工作区或更换来源。已有工作区保持不变；如需停止访问，请另行关闭。',
    '阻止 API 後續使用此參照建立工作區或更換來源。既有工作區保持不變；如需停止存取，請另行關閉。',
  );
  String get sourceId => _s('Approved source ID (body only)', '已批准来源 ID（仅正文）', '已核准來源 ID（僅正文）');
  String get slug => _s('Workspace route', '工作区访问路径名', '工作區存取路徑名稱');
  String get password => _s('New password / PIN (4–128 characters)', '新密码／PIN（4–128 字符）', '新密碼／PIN（4–128 字元）');
  String get clear => _s('Remove workspace password', '移除工作区密码', '移除工作區密碼');
  String get configure => _s('Change closed workspace source / route', '更换已关闭工作区的来源／路径', '更換已關閉工作區的來源／路徑');
  String get create => _s('Create a closed workspace', '创建已关闭的工作区', '建立已關閉的工作區');
  String get bodyHint => _s(
    'Source references and passwords are sent only in JSON bodies. Examples use placeholders; password fields are cleared after the request. Source/route changes require a closed workspace.',
    '来源引用和密码仅通过 JSON 正文发送。示例使用占位符；请求结束后清空密码字段。更换来源／路径前须关闭工作区。',
    '來源參照和密碼僅透過 JSON 正文傳送。範例使用佔位符；請求結束後清空密碼欄位。更換來源／路徑前須關閉工作區。',
  );
}
