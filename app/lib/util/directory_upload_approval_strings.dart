import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/directory_upload_approval.dart';

class DirectoryUploadApprovalStrings {
  final AppLocale locale;
  const DirectoryUploadApprovalStrings(this.locale);
  bool get _zh => locale == AppLocale.zhCn || locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  bool get _traditional => locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  String _text(String en, String zh, String hant) => !_zh ? en : (_traditional ? hant : zh);
  String get title => _text('Workspace receive requests', '工作区接收请求', '工作區接收要求');
  String badge(int n) => _text('Workspace requests $n', '工作区待确认 $n', '工作區待確認 $n');
  String get hint => _text(
    'Closing this panel keeps requests and transfers running. Accept only allows this request; it does not confirm delivery.',
    '关闭面板不会拒绝请求或停止传输。接受仅批准本次请求，不表示文件已接收完成。',
    '關閉面板不會拒絕要求或停止傳輸。接受僅批准本次要求，不表示檔案已接收完成。',
  );
  String summary(int files, int folders) => _text('$files files · $folders folders', '$files 个文件 · $folders 个文件夹', '$files 個檔案 · $folders 個資料夾');
  String showing(int total) => _text(
    'Showing the first 100 of $total entries. Your decision applies to the entire batch.',
    '显示前 100 项，共 $total 项；本次决定适用于整个批次。',
    '顯示前 100 項，共 $total 項；本次決定適用於整個批次。',
  );
  String get workspace => _text('Workspace', '工作区', '工作區');
  String get peer => _text('Browser address', '浏览器地址', '瀏覽器地址');
  String get file => _text('File', '文件', '檔案');
  String get directory => _text('Folder', '文件夹', '資料夾');
  String get accept => _text('Accept this request', '接受本次请求', '接受本次要求');
  String get decline => _text('Decline', '拒绝', '拒絕');
  String get hide => _text('Hide panel', '隐藏面板', '隱藏面板');
  String get clear => _text('Clear finished requests', '清除已处理请求', '清除已處理要求');
  String get empty => _text('No workspace receive requests.', '暂无工作区接收请求。', '暫無工作區接收要求。');
  String get hiddenPath => _text('Name unavailable', '名称不可用', '名稱不可用');
  String remaining(int seconds) => _text('Waiting · ${seconds}s remaining', '等待确认 · 剩余 $seconds 秒', '等待確認 · 剩餘 $seconds 秒');
  String status(DirectoryUploadApprovalStatus value) => switch (value) {
    DirectoryUploadApprovalStatus.waiting => _text('Waiting for approval', '等待确认', '等待確認'),
    DirectoryUploadApprovalStatus.responding => _text('Sending decision…', '正在提交决定…', '正在提交決定…'),
    DirectoryUploadApprovalStatus.accepted => _text('Accepted · upload permitted', '已批准 · 允许上传', '已批准 · 允許上傳'),
    DirectoryUploadApprovalStatus.declined => _text('Declined', '已拒绝', '已拒絕'),
    DirectoryUploadApprovalStatus.expired => _text('Request timed out · ask the browser to retry', '请求已超时，请在浏览器重试', '要求已逾時，請在瀏覽器重試'),
    DirectoryUploadApprovalStatus.failed => _text('Decision could not be delivered · ask the browser to retry', '决定提交失败，请在浏览器重试', '決定提交失敗，請在瀏覽器重試'),
  };
}
