import 'package:localsend_app/gen/strings.g.dart';

class AlbumBatchStrings {
  final AppLocale locale;
  const AlbumBatchStrings(this.locale);
  bool get _zh => {AppLocale.zhCn, AppLocale.zhTw, AppLocale.zhHk}.contains(locale);
  bool get _simple => locale == AppLocale.zhCn;
  String get select => !_zh
      ? 'Select current album'
      : _simple
      ? '全选当前相册'
      : '全選目前相簿';
  String get hint => !_zh
      ? 'Up to 999 items · authorized photos and videos only'
      : _simple
      ? '最多 999 项 · 仅含已授权的照片和视频'
      : '最多 999 項 · 僅含已授權的照片和影片';
  String get cancel => !_zh
      ? 'Cancel'
      : _simple
      ? '取消'
      : '取消';
  String progress(int count) => !_zh
      ? 'Selecting… $count items'
      : _simple
      ? '正在选择… $count 项'
      : '正在選取… $count 項';
  String get limited => !_zh
      ? 'Selection limit reached. Review the selected items before confirming.'
      : _simple
      ? '已达到批量选择上限，请检查已选内容后确认。'
      : '已達批次選取上限，請檢查已選內容後確認。';
  String get failed => !_zh
      ? 'The album could not be read. Nothing was added. Check photo access and try again.'
      : _simple
      ? '相册读取失败，未加入任何内容。请检查照片访问权限后重试。'
      : '相簿讀取失敗，未加入任何內容。請檢查照片存取權限後重試。';
}
