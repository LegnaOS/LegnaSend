import 'package:localsend_app/gen/strings.g.dart';

class AndroidFolderStrings {
  final AppLocale locale;
  const AndroidFolderStrings(this.locale);
  bool get _en => !{AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk}.contains(locale);
  bool get _simple => locale == AppLocale.zhCn;
  String empty(int count) => _en
      ? '$count empty folders were not selected. The original transfer protocol sends files only.'
      : _simple
      ? '$count 个空目录未加入选择。原始传输协议仅发送文件。'
      : '$count 個空目錄未加入選取。原始傳輸協定僅傳送檔案。';
  String error(String code) {
    if (_en) {
      return switch (code) {
        'permission' => 'Folder read permission is unavailable. Select and authorize it again; nothing was added.',
        'unsupported' => 'This folder contains a virtual file or a file with unknown size. Nothing was added.',
        'limit' => 'This selection exceeds the bounded folder budget. Choose a smaller subfolder; nothing was added.',
        'duplicate' || 'invalid_name' || 'invalid' => 'Folder names or paths are ambiguous or unsupported. Nothing was added.',
        'busy' || 'loading' => 'The file provider is busy or still loading. Retry later; nothing was added.',
        _ => 'The whole folder could not be read. Check access and retry; nothing was added.',
      };
    }
    if (_simple) {
      return switch (code) {
        'permission' => '目录读取权限不可用，请重新选择并授权；没有加入任何文件。',
        'unsupported' => '目录中包含虚拟文件或大小未知的文件；没有加入任何文件。',
        'limit' => '选择超出目录枚举预算，请选择更小的子目录；没有加入任何文件。',
        'duplicate' || 'invalid_name' || 'invalid' => '目录名称或路径重复、含糊或不受支持；没有加入任何文件。',
        'busy' || 'loading' => '文件提供程序繁忙或仍在加载，请稍后重试；没有加入任何文件。',
        _ => '目录未完整读取，请检查访问权限后重试；没有加入任何文件。',
      };
    }
    return switch (code) {
      'permission' => '目錄讀取權限不可用，請重新選取並授權；沒有加入任何檔案。',
      'unsupported' => '目錄中包含虛擬檔案或大小未知的檔案；沒有加入任何檔案。',
      'limit' => '選取範圍超出目錄列舉預算，請選取較小的子目錄；沒有加入任何檔案。',
      'duplicate' || 'invalid_name' || 'invalid' => '目錄名稱或路徑重複、含糊或不受支援；沒有加入任何檔案。',
      'busy' || 'loading' => '檔案提供程式忙碌或仍在載入，請稍後重試；沒有加入任何檔案。',
      _ => '目錄未完整讀取，請檢查存取權限後重試；沒有加入任何檔案。',
    };
  }
}
