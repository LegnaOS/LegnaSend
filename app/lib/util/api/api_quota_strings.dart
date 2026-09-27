/// Key lifecycle and quota copy shared by narrow and desktop settings views.
class ApiQuotaStrings {
  final String language;
  const ApiQuotaStrings(this.language);
  String _pick(String en, String cn, String tw) => !language.startsWith('zh')
      ? en
      : language.contains('TW') || language.contains('HK')
      ? tw
      : cn;
  String get unlimited => _pick('Unlimited', '不限额', '不限額');
  String value(int value) => value == 0 ? unlimited : '$value';
  String get zeroHint => _pick(
    '0 removes only that quota. Other quotas and server resource limits still apply.',
    '0 仅取消这一项限额，其他限额与服务器资源上限仍然生效。',
    '0 僅取消這一項限額，其他限額與伺服器資源上限仍然生效。',
  );
  String get pause => _pick('Pause key', '暂停密钥', '暫停金鑰');
  String get resume => _pick('Resume key', '恢复密钥', '恢復金鑰');
  String get paused => _pick('Paused', '已暂停', '已暫停');
  String get pausePending => _pick('Pause pending synchronization', '暂停待同步', '暫停待同步');
  String get pauseHint => _pick(
    'Keep this key and its secret, but deny new requests and stop uncommitted work. A management change already accepted by the host may still finish. Existing quota usage is retained.',
    '保留密钥及原凭据，拒绝新请求并停止尚未提交的工作。主机已接受的管理变更仍可能完成，已用配额不会重置。',
    '保留金鑰及原憑證，拒絕新請求並停止尚未提交的工作。主機已接受的管理變更仍可能完成，已用配額不會重設。',
  );
  String get resumeHint => _pick(
    'The same secret will work again after synchronization. Resuming does not reset quota usage or restart interrupted requests.',
    '同步完成后原凭据恢复使用；不会重置已用配额，也不会自动重启中断的请求。',
    '同步完成後原憑證恢復使用；不會重設已用配額，也不會自動重新啟動中斷的請求。',
  );
  String get limits => _pick('Key limits', '密钥限额', '金鑰限額');
  String get inherit => _pick('Use default key limits', '使用默认密钥限额', '使用預設金鑰限額');
  String get inherited => _pick('Default limits', '默认限额', '預設限額');
  String get custom => _pick('Custom limits', '独立限额', '獨立限額');
  String get limitsHint => _pick(
    'Overrides apply only to this key. Global quotas still apply. Changes retain current usage and active requests; lower limits affect new admissions.',
    '独立限额仅用于此密钥，全局限额仍生效。修改保留当前用量及活动请求，降低限额影响后续请求。',
    '獨立限額僅用於此金鑰，全域限額仍生效。修改保留目前用量及活動請求，降低限額影響後續請求。',
  );
}
