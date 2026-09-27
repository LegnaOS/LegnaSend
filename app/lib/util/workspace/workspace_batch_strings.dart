class WorkspaceBatchStrings {
  final String locale;
  const WorkspaceBatchStrings(this.locale);
  String _text(String en, String cn, String tw) => locale == 'zh-CN'
      ? cn
      : locale.startsWith('zh')
      ? tw
      : en;
  String get select => _text('Select workspaces', '选择工作区', '選擇工作區');
  String get open => _text('Open selected', '开启所选', '開啟所選');
  String get close => _text('Close selected', '关闭所选', '關閉所選');
  String get clear => _text('Clear selection', '清除选择', '清除選擇');
  String get hint => _text(
    'Only these workspaces change. Their visibility, passwords and upload permissions stay unchanged; the server and other shares keep running.',
    '仅修改以下工作区，保留各自可见性、密码与上传权限；服务器及其他共享继续运行。',
    '僅修改以下工作區，保留各自可見性、密碼與上傳權限；伺服器及其他分享繼續運行。',
  );
  String get results => _text('Workspace results', '工作区操作结果', '工作區操作結果');
  String get applied => _text('Applied', '已应用', '已套用');
  String get invalid => _text('Unavailable · remains closed', '源不可用 · 保持关闭', '來源不可用 · 保持關閉');
  String get changed => _text('Configuration changed · not modified', '配置已变化 · 未修改', '設定已變更 · 未修改');
  String get failed => _text('Failed · retry individually', '失败 · 请单独重试', '失敗 · 請單獨重試');
  String get pending => _text('Saved · awaiting server confirmation', '已保存 · 等待服务确认', '已儲存 · 等待伺服器確認');
}
