/// Explorer-only upload copy. Other locales use the existing documented English fallback.
class ApiUploadStrings {
  final String language;
  const ApiUploadStrings(this.language);
  bool get _zh => language.startsWith('zh');
  bool get _traditional => language.contains('TW') || language.contains('HK');
  String _pick(String en, String cn, String tw) => !_zh
      ? en
      : _traditional
      ? tw
      : cn;
  String get hint => _pick(
    'Read-only requests run immediately. Uploads require a selected file or an empty directory and confirmation.',
    '只读请求直接执行；上传需选择文件或空目录，并在页面内确认。',
    '唯讀請求直接執行；上傳需選擇檔案或空目錄，並在頁面內確認。',
  );
  String get operation => _pick('Upload · confirmation required', '上传 · 需要确认', '上傳 · 需要確認');
  String get choose => _pick('Choose upload file', '选择上传文件', '選擇上傳檔案');
  String get replace => _pick('Change file', '更换文件', '更換檔案');
  String get empty => _pick('Create an empty directory', '创建空目录', '建立空目錄');
  String get fileRequired => _pick('Choose one file before uploading.', '请先选择一个上传文件。', '請先選擇一個上傳檔案。');
  String get chooseFailed => _pick('The selected file could not be opened. Select it again.', '所选文件读取失败，请重新选择。', '所選檔案讀取失敗，請重新選擇。');
  String get single => _pick('Select exactly one file for this API request.', '每次 API 请求请选择一个文件。', '每次 API 請求請選擇一個檔案。');
  String get sourceHint => _pick(
    'The selected source is streamed from disk. Its local path is never sent to the remote endpoint or included in examples.',
    '所选文件通过磁盘流式读取；本地路径不会发送给远端接口，也不会写入示例。',
    '所選檔案透過磁碟串流讀取；本機路徑不會傳送至遠端介面，也不會寫入範例。',
  );
  String get confirmTitle => _pick('Confirm workspace upload', '确认工作区上传', '確認工作區上傳');
  String get confirmHint => _pick(
    'This writes to the selected workspace. Existing files are never overwritten. A failure requires a whole-file retry.',
    '此操作会写入指定工作区，不会覆盖已有文件；失败后需整文件重试。',
    '此操作會寫入指定工作區，不會覆寫既有檔案；失敗後需整檔重試。',
  );
  String get destination => _pick('Destination', '目标', '目標');
  String get parent => _pick('Parent directory ID', '父目录标识', '父目錄識別碼');
  String get file => _pick('Source file', '源文件', '來源檔案');
  String get confirm => _pick('Confirm upload', '确认上传', '確認上傳');
  String get cancel => _pick('Cancel', '取消', '取消');
}
