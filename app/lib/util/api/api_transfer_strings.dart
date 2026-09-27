import 'package:localsend_app/util/api/api_settings.dart';

class ApiTransferStrings {
  final String language;
  const ApiTransferStrings(this.language);
  String _s(String en, String cn, String tw) => !language.startsWith('zh')
      ? en
      : language.contains('TW') || language.contains('HK')
      ? tw
      : cn;
  String get nativeOperation => _s('Native task control', '原生任务控制', '原生工作控制');
  String get nativeUnknown => _s(
    'The result is unknown. Refresh native tasks before another action; do not repeat this control request.',
    '结果尚不明确。请重新读取原生任务后再操作，不重复提交本次控制。',
    '結果尚不明確。請重新讀取原生工作後再操作，不重複提交本次控制。',
  );
  String get hostOperation => _s('Host administration', '宿主管理操作', '主機管理操作');
  String get hostUnknown => _s(
    'The result is unknown. Read the current settings or inspect caches before deciding whether to retry.',
    '结果尚不明确。请先读取当前设置或只读盘点缓存，再决定是否重试。',
    '結果尚不明確。請先讀取目前設定或唯讀盤點快取，再決定是否重試。',
  );
  String get group => _s('Devices and transfers', '设备与传送', '裝置與傳送');
  String get operation => _s('Device / transfer action', '设备／传送操作', '裝置／傳送操作');
  String get confirm => _s('Confirm action', '确认操作', '確認操作');
  String get cancel => _s('Back', '返回', '返回');
  String get hint => _s(
    'These actions require a key with an explicit device / transfer scope and the global * grant. Sending uses only the files currently selected in the app, never arbitrary disk paths. Task listing and control are limited to tasks created by this key. Optional localRouteId comes from GET /devices localRoutes; omit for automatic routing. Retired IDs fail without fallback; retry preserves the route.',
    '这些操作须密钥明确拥有设备／传送权限及全局 * 授权。发送仅使用应用内当前已选文件，不接受任意磁盘路径。任务查询与控制仅限此密钥创建的任务。可选 localRouteId 来自 GET /devices 的 localRoutes；省略自动选路。失效 ID 不回退，重试保留原出口。',
    '這些操作須密鑰明確擁有裝置／傳送權限及全域 * 授權。傳送僅使用應用程式內目前已選檔案，不接受任意磁碟路徑。工作查詢與控制僅限此密鑰建立的工作。可選 localRouteId 來自 GET /devices 的 localRoutes；省略自動選路。失效 ID 不回退，重試保留原出口。',
  );
  String get requestHint => _s(
    'Keep the same request ID and payload when an outcome is unknown. This page retains the draft when switching operations or after errors. Save the request ID before leaving this page; a new ID represents a new intent and can send again.',
    '结果不明确时保留相同请求 ID 与正文。本页在切换接口或请求失败后保留草稿；离开页面前请保存请求 ID。新 ID 代表新意图，可能再次发送。',
    '結果不明確時保留相同請求 ID 與正文。本頁在切換介面或請求失敗後保留草稿；離開頁面前請儲存請求 ID。新 ID 代表新意圖，可能再次傳送。',
  );
  String get unknown => _s(
    'The result is unknown. Keep this request ID and payload; inspect the task before submitting a new intent.',
    '结果尚不明确。保留此请求 ID 与正文；提交新意图前先查询任务。',
    '結果尚不明確。保留此請求 ID 與正文；提交新意圖前先查詢工作。',
  );
  String get newRequest => _s('New request ID', '新建请求 ID', '新增請求 ID');
  String get filesystemSource => _s('Versioned filesystem files', '指定版本的本地文件', '指定版本的本機檔案');
  String get documentSource => _s('Capture document files', '捕获文档提供程序文件', '擷取文件提供者檔案');
  String field(String key) => switch (key) {
    'path' => _s('Parent directory (empty for root)', '父目录（根目录留空）', '父目錄（根目錄留空）'),
    'ids' => _s('Selected direct-child IDs JSON (1–20,000; 2 MiB body)', '选中直接子项 ID JSON（1–20,000；正文 2 MiB）', '所選直接子項 ID JSON（1–20,000；正文 2 MiB）'),
    'selection' => _s('Archive selection ticket UUID', '归档选择票据 UUID', '封存選取票據 UUID'),
    'id' => _s('Document ID from workspace listing', '工作区清单中的文档 ID', '工作區清單中的文件 ID'),
    'lease' => _s('Preview lease UUID', '预览租约 UUID', '預覽租約 UUID'),
    'localRouteId' => _s('Outgoing route ID (optional; GET /devices)', '本机出口 ID（可选；先 GET /devices）', '本機出口 ID（可選；先 GET /devices）'),
    'version' => _s('Current version (read first)', '当前版本（先读取）', '目前版本（先讀取）'),
    'epoch' => _s('Native task service epoch', '原生任务服务代次', '原生工作服務代次'),
    'action' => _s('Action: cancel / accept / reject / remove', '操作：cancel / accept / reject / remove', '操作：cancel / accept / reject / remove'),
    'instanceId' => _s('Current API instance ID', '当前 API 实例 ID', '目前 API 實例 ID'),
    'generation' => _s('Workspace generation', '工作区代次', '工作區代次'),
    'sourceMode' => _s('Source mode', '来源模式', '來源模式'),
    'files' => _s(
      'Files JSON: id; filesystem also needs quoted ETag version',
      '文件 JSON：id；本地文件还须带引号的 ETag version',
      '檔案 JSON：id；本機檔案另需帶引號的 ETag version',
    ),
    'field' => _s('Setting field', '设置字段', '設定欄位'),
    'value' => _s(
      'Value: boolean, text, or retention code (−2 = 1 hour; −1…3650)',
      '新值：布尔、文本或保留期编码（−2 为 1 小时；−1…3650）',
      '新值：布林、文字或保留期編碼（−2 為 1 小時；−1…3650）',
    ),
    'deviceId' => _s('Destination device ID', '目标设备 ID', '目標裝置 ID'),
    'selectionVersion' => _s('Local selection version', '本地已选文件版本', '本機已選檔案版本'),
    'requestId' => _s('Request ID (keep after errors)', '请求 ID（失败后保留）', '請求 ID（失敗後保留）'),
    'channelId' => _s('Network channel ID (optional)', '网络通道 ID（可选）', '網路通道 ID（選填）'),
    _ => key,
  };
  String action(String id) => switch (id) {
    'prepareWorkspaceArchive' => _s(
      'Prepare a short-lived selection ticket, not ZIP bytes. Keep the returned URL and ticket; a lost response must not be automatically retried. New download admissions expire after 120 seconds without renewal.',
      '创建短期选择票据，不生成 ZIP 缓存。保留返回的网址与票据；丢失响应后不自动重试。新的下载准入在 120 秒后到期，不续期。',
      '建立短期選取票據，不產生 ZIP 快取。保留返回網址與票據；遺失回應後不自動重試。新的下載准入在 120 秒後到期，不續期。',
    ),
    'cancelWorkspaceArchive' => _s(
      'Cancel this exact ticket and its active streams without deleting source files. HTTP 410 means it already ended.',
      '撤销此精确票据及活动流，不删除源文件。HTTP 410 表示已经结束。',
      '撤銷此精確票據及活動串流，不刪除來源檔案。HTTP 410 表示已結束。',
    ),
    'prepareDocumentPreview' => _s(
      'Pin one read-only provider descriptor for preview. Same-authority HEAD/reads renew the 120-second idle lease; this is not persistent download resume.',
      '为预览固定一个只读提供程序描述符。同一授权的 HEAD/读取续期 120 秒闲置租约，不是持久下载续传。',
      '為預覽固定一個唯讀提供者描述符。同一授權的 HEAD/讀取續期 120 秒閒置租約，不是持久下載續傳。',
    ),
    'closeDocumentPreview' => _s(
      'Release this authority’s preview lease without deleting the source file.',
      '释放此授权的预览租约，不删除源文件。',
      '釋放此授權的預覽租約，不刪除來源檔案。',
    ),
    'listSourceEndNotices' || 'retrySourceEndNotice' => _s(
      'Read redacted source-end notices. Retry uses the current version and the same requestId to reconcile an unknown response. Accepted means scheduled, not remotely cleaned; published files are preserved.',
      '读取脱敏的来源结束通知。重试使用当前版本；结果未知时用同一 requestId 核对。已接受表示已排程，不代表远端已清理；已发布文件保留。',
      '讀取脫敏的來源結束通知。重試使用目前版本；結果未知時以相同 requestId 核對。已接受表示已排程，不代表遠端已清理；已發佈檔案保留。',
    ),
    'listNativeTasks' || 'controlNativeTask' => _s(
      'Control one actual native task using its current epoch and version. Accept uses local receive settings. Remove clears only ordinary terminal history, not files; restored send entries are excluded. Dispatched does not mean the peer completed the operation.',
      '使用当前代次和版本控制一个实际原生任务。接受沿用本地接收设置；移除仅清普通终态记录，不删文件，恢复的发送记录不包含移除操作。已派发不代表对端已完成。',
      '使用目前代次與版本控制一個實際原生工作。接受沿用本機接收設定；移除僅清一般終態記錄，不刪檔案，恢復的傳送記錄不包含移除操作。已派發不代表對端已完成。',
    ),
    'sendWorkspaceFiles' => _s(
      'Send up to 128 selected workspace files to a discovered device with transfers.send, files.read and *. Filesystem files require their listed version; document files use explicit byte capture without a fabricated version. The current UI selection stays unchanged.',
      '持 transfers.send、files.read 与 * 授权，把最多 128 个所选工作区文件发送至已发现设备。本地文件须指定清单版本；文档文件明确捕获字节，不伪造版本。不改变当前 UI 选择。',
      '持 transfers.send、files.read 與 * 授權，把最多 128 個所選工作區檔案傳送至已發現裝置。本機檔案須指定清單版本；文件提供者檔案明確擷取位元組，不偽造版本。不改變目前 UI 選擇。',
    ),
    'cleanupCache' => _s(
      'Clean only registered inactive receive staging after ownership checks. User files, unknown data and active transfers remain protected.',
      '仅清理已登记且身份核验通过的非活动接收暂存，保留用户文件、未知数据和活动任务。',
      '僅清理已登記且身分核驗通過的非活動接收暫存，保留使用者檔案、未知資料和活動工作。',
    ),
    'updateSettings' => _s(
      'Update one supported setting using its current version. receiveCacheRetentionDays is an integer: −2 keeps one hour (default), −1 keeps manually, 0 cleans automatically, 1…3650 retains days. Updating does not run cleanup. Secrets, paths and listener restarts are excluded.',
      '核验当前版本后修改一项设置。receiveCacheRetentionDays 必须是整数：−2 保留 1 小时（默认）、−1 手动保留、0 自动清理、1…3650 保留天数；修改不会执行清理。不包含秘密、路径和监听重启。',
      '核驗目前版本後修改一項設定。receiveCacheRetentionDays 必須是整數：−2 保留 1 小時（預設）、−1 手動保留、0 自動清理、1…3650 保留天數；修改不會執行清理。不包含秘密、路徑和監聽重新啟動。',
    ),
    'sendSelection' => _s(
      'Send the current local selection to this device. The receiver still decides whether to accept.',
      '将当前本地已选文件发送至此设备；接收端仍自行决定是否接收。',
      '將目前本機已選檔案傳送至此裝置；接收端仍自行決定是否接收。',
    ),
    'retryTransfer' => _s(
      'Retry this task with both transfers.control and transfers.send permissions. All files in the original task are sent again, including already completed files; even a succeeded task can be resent. The original LocalSend protocol restarts each file in full, not from a byte offset.',
      '重试此任务须同时拥有 transfers.control 与 transfers.send 权限。将重新发送原任务的全部文件，包括此前已完成的文件；成功结束的任务也可再次发送。使用原始 LocalSend 协议逐个整文件重传，不是字节断点续传。',
      '重試此工作須同時擁有 transfers.control 與 transfers.send 權限。將重新傳送原工作的全部檔案，包括先前已完成的檔案；成功結束的工作也可再次傳送。使用原始 LocalSend 協定逐個整檔重傳，不是位元組斷點續傳。',
    ),
    'cancelTransfer' => _s(
      'Cancel this key’s transfer task. Already received files are not deleted.',
      '取消此密钥的传送任务；不会删除已接收文件。',
      '取消此密鑰的傳送工作；不會刪除已接收檔案。',
    ),
    'removeTransfer' => _s(
      'Remove a finished task from this key’s list. Active tasks must be canceled first. Source and received files remain unchanged.',
      '从此密钥列表移除已结束任务；活动任务须先取消。源文件与已接收文件保持不变。',
      '從此密鑰清單移除已結束工作；活動工作須先取消。來源檔案與已接收檔案保持不變。',
    ),
    'scanDevices' => _s(
      'Start discovery on the app’s configured local networks; no arbitrary scan target is accepted.',
      '在应用已配置的本地网络启动设备发现，不接受任意扫描目标。',
      '在應用程式已設定的本機網路啟動裝置探索，不接受任意掃描目標。',
    ),
    _ => hint,
  };
  String scope(ApiScope scope) => switch (scope) {
    ApiScope.keysManage => _s('Manage bounded-authority keys', '管理不超出自身权限的密钥', '管理不超出自身權限的密鑰'),
    ApiScope.requestsManage => _s('Clear observed request history', '清理已观测请求历史', '清理已觀測請求歷史'),
    ApiScope.cacheRead => _s('Inspect owned receive caches', '盘点受管接收缓存', '盤點受管接收快取'),
    ApiScope.cacheClean => _s('Clean inactive owned receive caches', '清理非活动受管接收缓存', '清理非活動受管接收快取'),
    ApiScope.nativeTasksRead => _s('Read all native send / receive tasks', '读取全部原生收发任务', '讀取全部原生收發任務'),
    ApiScope.nativeTasksControl => _s('Control all native send / receive tasks', '控制全部原生收发任务', '控制全部原生收發任務'),
    ApiScope.settingsRead => _s('Read non-secret application settings', '读取非敏感应用设置', '讀取非敏感應用設定'),
    ApiScope.settingsWrite => _s('Change supported application settings', '修改受支持应用设置', '修改受支援應用設定'),
    ApiScope.devicesRead => _s('Read discovered devices', '读取已发现设备', '讀取已探索裝置'),
    ApiScope.devicesScan => _s('Start local device discovery', '启动本地设备发现', '啟動本機裝置探索'),
    ApiScope.transfersRead => _s('Read local selection and own tasks', '读取本地选择与自有任务', '讀取本機選擇與自有工作'),
    ApiScope.transfersSend => _s('Send currently selected local files', '发送当前本地已选文件', '傳送目前本機已選檔案'),
    ApiScope.transfersControl => _s('Control own tasks (retry also requires send)', '控制自有任务（重试还须发送权限）', '控制自有工作（重試還須傳送權限）'),
    _ => scope.wire,
  };
}
