import 'package:localsend_app/gen/strings.g.dart';

/// Fork-owned copy, with the same English fallback as the generated locales.
class SendRouteStrings {
  final AppLocale locale;
  const SendRouteStrings(this.locale);
  bool get _zh => locale == AppLocale.zhCn || locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  bool get _traditional => locale == AppLocale.zhTw || locale == AppLocale.zhHk;
  String _text(String en, String zh, String hant) => !_zh
      ? en
      : _traditional
      ? hant
      : zh;
  String get all => _text('All networks', '全部网络', '全部網路');
  String get local => _text('Local subnets', '本地网段', '本地網段');
  String get tunnel => _text('VPN / tunnel subnets', 'VPN / 隧道网段', 'VPN / 隧道網段');
  String get routed => _text('Routed / unknown', '经路由 / 未知', '經路由 / 未知');
  String get automatic => _text('Automatic entry point', '自动选择入口', '自動選擇入口');
  String get choose => _text('Receiver entry point', '接收端入口', '接收端入口');
  String get hint => _text(
    'Filters only change this device list. Select the receiver address, not the outgoing network interface. Subnet tags do not guarantee a direct route or bypass a VPN. Queued tasks and retries keep their selected entry point.',
    '筛选仅影响设备列表。选择的是接收端地址，不是本机出网网卡。网段标签不保证直连或绕过 VPN。排队任务与重试保留入队时选择的入口。',
    '篩選僅影響裝置列表。選擇的是接收端地址，不是本機出網網卡。網段標籤不保證直連或繞過 VPN。排隊任務與重試保留入隊時選擇的入口。',
  );
  String get unavailable => _text(
    'Selected entry point is no longer advertised. Select an entry point and send again.',
    '所选入口已不在发现结果中，请重新选择入口后发送。',
    '所選入口已不在探索結果中，請重新選擇入口後傳送。',
  );
  String get missingNetwork => _text('Selected network is unavailable', '所选网络当前不可用', '所選網路目前不可用');
  String get noMatches => _text('No devices match this network filter.', '没有符合当前网络筛选的设备。', '沒有符合目前網路篩選的裝置。');

  String get localExit => _text('Outgoing network', '本机出口', '本機出口');
  String get automaticExit => _text('Automatic network', '自动选择网络', '自動選擇網路');
  String get localInterface => _text('Local interface', '本地接口', '本機介面');
  String get tunnelInterface => _text('VPN / tunnel interface', 'VPN / 隧道接口', 'VPN / 通道介面');
  String get routeDetails => _text('Network binding details', '网络绑定说明', '網路綁定說明');
  String get androidNetworkBinding => _text('Android Network binding', 'Android 系统网络绑定', 'Android 系統網路綁定');
  String get sourceBinding => _text('Source address binding', '来源地址绑定', '來源位址綁定');
  String get interfaceBinding => _text('Interface and source binding', '接口与来源地址绑定', '介面與來源位址綁定');
  String get noLocalAddresses => _text('No usable local addresses.', '暂无可用本机地址。', '暫無可用本機位址。');
  String get addressFamilyMismatch => _text('IP version differs from receiver entry point', '与接收端入口的 IP 版本不同', '與接收端入口的 IP 版本不同');
  String get localRouteUnavailable => _text(
    'The selected source address is unavailable. Restore that interface and address, or create a new send with another network.',
    '所选来源地址不可用。请恢复该接口和地址，或选择其他网络新建发送任务。',
    '所選來源位址無法使用。請還原該介面與位址，或選擇其他網路建立新傳送工作。',
  );
  String get localRouteInvalid => _text('Invalid outgoing network selection.', '本机出口选择无效。', '本機出口選擇無效。');
  String get bindingHint => _text(
    'The selected source address is bound to this task’s sockets. On Apple and Linux the interface is also constrained; Windows uses its selected interface; Android entries with a system Network bind each new socket to that Network, while other entries bind only the source address. Preparation, upload and cancellation keep the same selection, including retries and restart recovery. An unavailable selection fails instead of switching networks. System VPN and firewall rules still apply. Tunnel labels describe the interface, not verified VPN bypass.',
    '选定来源地址绑定到当前任务的套接字；Apple 和 Linux 同时约束接口，Windows 约束所选接口；Android 已识别系统 Network 的入口逐套接字绑定该网络，其他入口仅绑定来源地址。准备、上传、取消、重试及重启恢复保留同一选择；出口失效直接报错，不切换到其他网络。系统 VPN 与防火墙规则仍生效，隧道标签仅描述接口，不代表已验证绕过 VPN。',
    '選定來源位址綁定至目前工作的通訊端；Apple 與 Linux 同時約束介面，Windows 約束所選介面；Android 已識別系統 Network 的入口逐通訊端綁定該網路，其他入口僅綁定來源位址。準備、上傳、取消、重試及重新啟動還原保留同一選擇；出口失效直接報錯，不切換至其他網路。系統 VPN 與防火牆規則仍生效，通道標籤僅描述介面，不代表已驗證略過 VPN。',
  );
}
