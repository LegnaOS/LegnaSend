import 'package:localsend_app/util/workspace/workspace_content_store.dart';

class WorkspaceContentStrings {
  final String locale;
  const WorkspaceContentStrings(this.locale);
  String _text(String en, String cn, String tw, String hk) => switch (locale) {
    'zh-CN' => cn,
    'zh-HK' => hk,
    _ when locale.startsWith('zh') => tw,
    _ => en,
  };
  String label(WorkspaceContentState? value, {required bool failed}) {
    if (failed) return _text('Updates · not saved', '内容更新 · 未保存', '內容更新 · 未儲存', '內容更新 · 未儲存');
    if (value == null) return _text('Updates · awaiting observation', '内容更新 · 待观察', '內容更新 · 待觀察', '內容更新 · 待觀察');
    final revision = value.contentRevision;
    return value.observed && !value.dirty
        ? _text('Observed update $revision', '已观察更新 $revision', '已觀察更新 $revision', '已觀察更新 $revision')
        : _text('Update $revision · awaiting observation', '更新 $revision · 待观察', '更新 $revision · 待觀察', '更新 $revision · 待觀察');
  }

  String get hint => _text(
    'Persisted observations, not a complete directory digest. Browsing refreshes the observed scope; offline changes remain unknown.',
    '持久记录已观察的更新，不是完整目录摘要。访问时刷新当前范围，离线变化保持未知。',
    '持久記錄已觀察的更新，並非完整目錄摘要。瀏覽時更新目前範圍，離線變更保持未知。',
    '持久記錄已觀察的更新，並非完整目錄摘要。瀏覽時更新目前範圍，離線變更保持未知。',
  );
}
