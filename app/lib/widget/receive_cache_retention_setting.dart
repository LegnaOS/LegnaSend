import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/provider/receive_cache_retention_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

class ReceiveCacheRetentionStrings {
  final String locale;
  const ReceiveCacheRetentionStrings(this.locale);
  String _s(String en, String zh, String hant) => !locale.toLowerCase().startsWith('zh')
      ? en
      : ['tw', 'hk', 'hant'].any(locale.toLowerCase().contains)
      ? hant
      : zh;
  String get title => _s('Interrupted receive cache retention', '中断接收缓存保留期', '中斷接收快取保留期');
  String get description => _s(
    'Only unfinished transfer files are cleaned. Saved files stay untouched.',
    '仅清理未完成传输的临时文件，已保存文件不受影响。',
    '僅清理未完成傳輸的暫存檔案，已儲存檔案不受影響。',
  );
  String policy(int days) => switch (days) {
    receiveCacheRetentionOneHour => _s('Keep for 1 hour (default)', '保留 1 小时（默认）', '保留 1 小時（預設）'),
    0 => _s('Clean automatically', '立即自动清理', '立即自動清理'),
    -1 => _s('Keep until manually cleaned', '保留至手动清理', '保留至手動清理'),
    _ => _s('Keep for $days days', '保留 $days 天', '保留 $days 天'),
  };
  String actual(int days) => _s('Effective: ${policy(days)}', '当前生效：${policy(days)}', '目前生效：${policy(days)}');
  String get unknown => _s('Policy not confirmed; automatic cleanup paused.', '策略尚未确认，自动清理已暂停。', '策略尚未確認，自動清理已暫停。');
  String get applying => _s('Saving and applying…', '正在保存并应用…', '正在儲存並套用…');
  String get retry => _s('Apply saved policy again', '重新应用已保存策略', '重新套用已儲存策略');
  String failure(String code) => switch (code) {
    'invalid' => _s(
      'Saved policy is damaged. Files are retained; choose a policy to repair the setting.',
      '已保存策略损坏，暂时保留文件；请选择策略以修复设置。',
      '已儲存策略損壞，暫時保留檔案；請選擇策略以修復設定。',
    ),
    'save' => _s('Saving failed. The effective policy is shown below.', '保存失败，下方显示实际生效策略。', '儲存失敗，下方顯示實際生效策略。'),
    'restore' => _s('Preference recovery failed; automatic cleanup paused. Retry to synchronize.', '偏好恢复失败，自动清理已暂停；请重试同步。', '偏好恢復失敗，自動清理已暫停；請重試同步。'),
    _ => _s('Applying failed. The effective policy is shown below; retry to synchronize.', '应用失败，下方显示实际生效策略；请重试同步。', '套用失敗，下方顯示實際生效策略；請重試同步。'),
  };
}

class ReceiveCacheRetentionSetting extends StatelessWidget {
  final ReceiveCacheRetentionController? controller;
  final String? locale;
  const ReceiveCacheRetentionSetting({super.key, this.controller, this.locale});
  @override
  Widget build(BuildContext context) {
    final ReceiveCacheRetentionController state = controller ?? context.ref.read(receiveCacheRetentionProvider);
    final strings = ReceiveCacheRetentionStrings(locale ?? LocaleSettings.currentLocale.languageTag);
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final colors = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(strings.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(strings.description, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                key: ValueKey('receive-retention-${state.days}'),
                initialValue: state.days,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                items: {
                  ...receiveCacheRetentionChoices,
                  state.days,
                }.map((days) => DropdownMenuItem(value: days, child: Text(strings.policy(days), maxLines: 2))).toList(),
                onChanged: state.busy
                    ? null
                    : (days) async {
                        if (days != null) await state.change(days);
                      },
              ),
              if (state.busy) ...[const SizedBox(height: 8), const LinearProgressIndicator(), Text(strings.applying)],
              if (state.error != null) ...[
                const SizedBox(height: 8),
                Text(strings.failure(state.error!), style: TextStyle(color: colors.error)),
                TextButton(onPressed: state.busy ? null : state.initialize, child: Text(strings.retry)),
              ],
              if (!state.ready || state.error != null) ...[
                const SizedBox(height: 6),
                Text(state.ready ? strings.actual(state.days) : strings.unknown, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        );
      },
    );
  }
}
