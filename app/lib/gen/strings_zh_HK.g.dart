///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:slang/generated.dart';
import 'strings.g.dart';

// Path: <root>
class TranslationsZhHk extends Translations with BaseTranslations<AppLocale, Translations> {
  /// You can call this constructor and build your own translation instance of this locale.
  /// Constructing via the enum [AppLocale.build] is preferred.
  TranslationsZhHk({
    Map<String, Node>? overrides,
    PluralResolver? cardinalResolver,
    PluralResolver? ordinalResolver,
    TranslationMetadata<AppLocale, Translations>? meta,
  }) : assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
       $meta =
           meta ??
           TranslationMetadata(
             locale: AppLocale.zhHk,
             overrides: overrides ?? {},
             cardinalResolver: cardinalResolver,
             ordinalResolver: ordinalResolver,
           ),
       super(cardinalResolver: cardinalResolver, ordinalResolver: ordinalResolver);

  /// Metadata for the translations of <zh-HK>.
  @override
  final TranslationMetadata<AppLocale, Translations> $meta;

  late final TranslationsZhHk _root = this; // ignore: unused_field

  @override
  TranslationsZhHk $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => TranslationsZhHk(meta: meta ?? this.$meta);

  // Translations
  @override
  String get appName => 'LegnaSend';
  @override
  late final Translations$general$zh_HK general = Translations$general$zh_HK.internal(_root);
  @override
  late final Translations$receiveTab$zh_HK receiveTab = Translations$receiveTab$zh_HK.internal(_root);
  @override
  late final Translations$sendTab$zh_HK sendTab = Translations$sendTab$zh_HK.internal(_root);
  @override
  late final Translations$settingsTab$zh_HK settingsTab = Translations$settingsTab$zh_HK.internal(_root);
  @override
  late final Translations$troubleshootPage$zh_HK troubleshootPage = Translations$troubleshootPage$zh_HK.internal(_root);
  @override
  late final Translations$networkInterfacesPage$zh_HK networkInterfacesPage = Translations$networkInterfacesPage$zh_HK.internal(_root);
  @override
  late final Translations$receiveHistoryPage$zh_HK receiveHistoryPage = Translations$receiveHistoryPage$zh_HK.internal(_root);
  @override
  late final Translations$apkPickerPage$zh_HK apkPickerPage = Translations$apkPickerPage$zh_HK.internal(_root);
  @override
  late final Translations$selectedFilesPage$zh_HK selectedFilesPage = Translations$selectedFilesPage$zh_HK.internal(_root);
  @override
  late final Translations$deviceDetailsPage$zh_HK deviceDetailsPage = Translations$deviceDetailsPage$zh_HK.internal(_root);
  @override
  late final Translations$verifyPage$zh_HK verifyPage = Translations$verifyPage$zh_HK.internal(_root);
  @override
  late final Translations$receivePage$zh_HK receivePage = Translations$receivePage$zh_HK.internal(_root);
  @override
  late final Translations$receiveOptionsPage$zh_HK receiveOptionsPage = Translations$receiveOptionsPage$zh_HK.internal(_root);
  @override
  late final Translations$sendPage$zh_HK sendPage = Translations$sendPage$zh_HK.internal(_root);
  @override
  late final Translations$progressPage$zh_HK progressPage = Translations$progressPage$zh_HK.internal(_root);
  @override
  late final Translations$webSharePage$zh_HK webSharePage = Translations$webSharePage$zh_HK.internal(_root);
  @override
  late final Translations$webReceivePage$zh_HK webReceivePage = Translations$webReceivePage$zh_HK.internal(_root);
  @override
  late final Translations$aboutPage$zh_HK aboutPage = Translations$aboutPage$zh_HK.internal(_root);
  @override
  late final Translations$donationPage$zh_HK donationPage = Translations$donationPage$zh_HK.internal(_root);
  @override
  late final Translations$directoryWorkspaces$zh_HK directoryWorkspaces = Translations$directoryWorkspaces$zh_HK.internal(_root);
  @override
  late final Translations$changelogPage$zh_HK changelogPage = Translations$changelogPage$zh_HK.internal(_root);
  @override
  late final Translations$whatsNewPage$zh_HK whatsNewPage = Translations$whatsNewPage$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$zh_HK dialogs = Translations$dialogs$zh_HK.internal(_root);
  @override
  late final Translations$sanitization$zh_HK sanitization = Translations$sanitization$zh_HK.internal(_root);
  @override
  late final Translations$tray$zh_HK tray = Translations$tray$zh_HK.internal(_root);
  @override
  late final Translations$web$zh_HK web = Translations$web$zh_HK.internal(_root);
  @override
  late final Translations$assetPicker$zh_HK assetPicker = Translations$assetPicker$zh_HK.internal(_root);
  @override
  late final Translations$transferActivity$zh_HK transferActivity = Translations$transferActivity$zh_HK.internal(_root);
  @override
  late final Translations$webPreview$zh_HK webPreview = Translations$webPreview$zh_HK.internal(_root);
  @override
  late final Translations$webTextPreview$zh_HK webTextPreview = Translations$webTextPreview$zh_HK.internal(_root);
  @override
  late final Translations$transportSecurity$zh_HK transportSecurity = Translations$transportSecurity$zh_HK.internal(_root);
  @override
  late final Translations$transferSpeed$zh_HK transferSpeed = Translations$transferSpeed$zh_HK.internal(_root);
  @override
  late final Translations$transferNavigation$zh_HK transferNavigation = Translations$transferNavigation$zh_HK.internal(_root);
  @override
  late final Translations$networkEnvironment$zh_HK networkEnvironment = Translations$networkEnvironment$zh_HK.internal(_root);
  @override
  late final Translations$linkWorkspace$zh_HK linkWorkspace = Translations$linkWorkspace$zh_HK.internal(_root);
  @override
  late final Translations$integrationApi$zh_HK integrationApi = Translations$integrationApi$zh_HK.internal(_root);
  @override
  late final Translations$apiExplorer$zh_HK apiExplorer = Translations$apiExplorer$zh_HK.internal(_root);
  @override
  late final Translations$sharedFileManagement$zh_HK sharedFileManagement = Translations$sharedFileManagement$zh_HK.internal(_root);
  @override
  late final Translations$sendQueue$zh_HK sendQueue = Translations$sendQueue$zh_HK.internal(_root);
}

// Path: general
class Translations$general$zh_HK extends Translations$general$en {
  Translations$general$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get accept => '接受';
  @override
  String get accepted => '已接受';
  @override
  String get add => '新增';
  @override
  String get advanced => '更多資訊';
  @override
  String get cancel => '取消';
  @override
  String get close => '關閉';
  @override
  String get confirm => '確認';
  @override
  String get continueStr => '繼續';
  @override
  String get copy => '複製';
  @override
  String get copiedToClipboard => '已複製到剪貼簿';
  @override
  String get decline => '拒絕';
  @override
  String get done => '完成';
  @override
  String get delete => '刪除';
  @override
  String get edit => '編輯';
  @override
  String get error => '錯誤';
  @override
  String get example => '範例';
  @override
  String get files => '檔案';
  @override
  String get finished => '搞掂';
  @override
  String get hide => '隱藏';
  @override
  String get off => '閂';
  @override
  String get offline => '離線';
  @override
  String get on => '開';
  @override
  String get online => '線上';
  @override
  String get open => '開啟';
  @override
  String get queue => '佇列';
  @override
  String get quickSave => '自動儲存';
  @override
  String get quickSaveFromFavorites => '自動儲存已收藏裝置 send 過嚟嘅檔案';
  @override
  String get renamed => '改咗名';
  @override
  String get reset => '重設';
  @override
  String get restart => '重新啟動';
  @override
  String get settings => '設定';
  @override
  String get skipped => '已跳過';
  @override
  String get start => '開始';
  @override
  String get stop => '停止';
  @override
  String get save => '儲存';
  @override
  String get unchanged => '冇改過';
  @override
  String get unknown => '未知';
  @override
  String get noItemInClipboard => '剪貼簿冇嘢。';
}

// Path: receiveTab
class Translations$receiveTab$zh_HK extends Translations$receiveTab$en {
  Translations$receiveTab$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.settingsTab.receive.title;
  @override
  late final Translations$receiveTab$infoBox$zh_HK infoBox = Translations$receiveTab$infoBox$zh_HK.internal(_root);
  @override
  late final Translations$receiveTab$quickSave$zh_HK quickSave = Translations$receiveTab$quickSave$zh_HK.internal(_root);
  @override
  String get link => '連結工作區';
}

// Path: sendTab
class Translations$sendTab$zh_HK extends Translations$sendTab$en {
  Translations$sendTab$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.settingsTab.send.title;
  @override
  late final Translations$sendTab$selection$zh_HK selection = Translations$sendTab$selection$zh_HK.internal(_root);
  @override
  late final Translations$sendTab$picker$zh_HK picker = Translations$sendTab$picker$zh_HK.internal(_root);
  @override
  String get shareIntentInfo => '用你裝置嘅「分享」功能以更方便揀選檔案。';
  @override
  String get nearbyDevices => '附近裝置';
  @override
  String get thisDevice => '此裝置';
  @override
  String get scan => '掃描裝置';
  @override
  String get manualSending => '手動傳送';
  @override
  String get sendMode => '傳送模式';
  @override
  late final Translations$sendTab$sendModes$zh_HK sendModes = Translations$sendTab$sendModes$zh_HK.internal(_root);
  @override
  String get sendModeHelp => '説明';
  @override
  String get help => '請確保目標裝置駁緊同一個 Wi‑Fi 網絡。';
  @override
  String get placeItems => '將要分享嘅檔案拉過嚟呢度。';
}

// Path: settingsTab
class Translations$settingsTab$zh_HK extends Translations$settingsTab$en {
  Translations$settingsTab$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.settings;
  @override
  late final Translations$settingsTab$general$zh_HK general = Translations$settingsTab$general$zh_HK.internal(_root);
  @override
  late final Translations$settingsTab$receive$zh_HK receive = Translations$settingsTab$receive$zh_HK.internal(_root);
  @override
  late final Translations$settingsTab$send$zh_HK send = Translations$settingsTab$send$zh_HK.internal(_root);
  @override
  late final Translations$settingsTab$network$zh_HK network = Translations$settingsTab$network$zh_HK.internal(_root);
  @override
  late final Translations$settingsTab$other$zh_HK other = Translations$settingsTab$other$zh_HK.internal(_root);
  @override
  String get advancedSettings => '進階設定';
}

// Path: troubleshootPage
class Translations$troubleshootPage$zh_HK extends Translations$troubleshootPage$en {
  Translations$troubleshootPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '疑難排解';
  @override
  String get subTitle => '個 app 唔 work？你可以喺度揾到一啲常見問題嘅解決辦法。';
  @override
  String get solution => '解決辦法：';
  @override
  String get fixButton => '自動修復';
  @override
  late final Translations$troubleshootPage$firewall$zh_HK firewall = Translations$troubleshootPage$firewall$zh_HK.internal(_root);
  @override
  late final Translations$troubleshootPage$noDiscovery$zh_HK noDiscovery = Translations$troubleshootPage$noDiscovery$zh_HK.internal(_root);
  @override
  late final Translations$troubleshootPage$noConnection$zh_HK noConnection = Translations$troubleshootPage$noConnection$zh_HK.internal(_root);
}

// Path: networkInterfacesPage
class Translations$networkInterfacesPage$zh_HK extends Translations$networkInterfacesPage$en {
  Translations$networkInterfacesPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '網絡介面';
  @override
  String get info => 'LocalSend 預設會用晒所有可用嘅網絡介面。你可以喺呢度排除唔需要嘅網絡。改完之後要熄咗個 server 再開過先會生效。';
  @override
  String get preview => '預覽';
  @override
  String get whitelist => '白名單';
  @override
  String get blacklist => '黑名單';
}

// Path: receiveHistoryPage
class Translations$receiveHistoryPage$zh_HK extends Translations$receiveHistoryPage$en {
  Translations$receiveHistoryPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '歷史記錄';
  @override
  String get openFolder => '開啟資料夾';
  @override
  String get deleteHistory => '清除記錄';
  @override
  String get empty => '得個吉噃 :(';
  @override
  late final Translations$receiveHistoryPage$entryActions$zh_HK entryActions = Translations$receiveHistoryPage$entryActions$zh_HK.internal(_root);
}

// Path: apkPickerPage
class Translations$apkPickerPage$zh_HK extends Translations$apkPickerPage$en {
  Translations$apkPickerPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '應用程式（APK）';
  @override
  String get excludeSystemApps => '排除系統應用程式';
  @override
  String get excludeAppsWithoutLaunchIntent => '排除唔開得嘅應用程式';
  @override
  String apps({required Object n}) => '${n} 個應用程式';
}

// Path: selectedFilesPage
class Translations$selectedFilesPage$zh_HK extends Translations$selectedFilesPage$en {
  Translations$selectedFilesPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get deleteAll => '全部刪除';
}

// Path: deviceDetailsPage
class Translations$deviceDetailsPage$zh_HK extends Translations$deviceDetailsPage$en {
  Translations$deviceDetailsPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '裝置資料';
  @override
  String get favorite => '收藏';
  @override
  String get verify => '驗證';
  @override
  late final Translations$deviceDetailsPage$info$zh_HK info = Translations$deviceDetailsPage$info$zh_HK.internal(_root);
  @override
  late final Translations$deviceDetailsPage$logs$zh_HK logs = Translations$deviceDetailsPage$logs$zh_HK.internal(_root);
}

// Path: verifyPage
class Translations$verifyPage$zh_HK extends Translations$verifyPage$en {
  Translations$verifyPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '驗證';
  @override
  String get icons => '圖示';
  @override
  String get text => '文字';
  @override
  String get question => '另一部裝置睇落係咪一樣？';
}

// Path: receivePage
class Translations$receivePage$zh_HK extends Translations$receivePage$en {
  Translations$receivePage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get verifyingReceivedData => '正在驗證接收資料';
  @override
  String get idleExpired => '接收工作階段已閒置10分鐘且沒有正在上傳的檔案，因此已過期。請讓傳送端重新發起傳輸；已完成的檔案會保留。';
  @override
  String subTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    n,
    one: '想 send 1 個檔案畀你',
    other: '想 send ${n} 個檔案畀你',
  );
  @override
  String get subTitleMessage => 'send 咗條訊息畀你：';
  @override
  String get subTitleLink => 'send 咗條 link 畀你：';
  @override
  String get canceled => '對方取消咗個請求。';
  @override
  String get destinationUnavailable => '下載目錄暫不可用，請檢查儲存權限、可用空間和儲存位置後重試。';
}

// Path: receiveOptionsPage
class Translations$receiveOptionsPage$zh_HK extends Translations$receiveOptionsPage$en {
  Translations$receiveOptionsPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.settings;
  @override
  String get destination => _root.settingsTab.receive.destination;
  @override
  String get appDirectory => '（LocalSend 資料夾）';
  @override
  String get saveToGallery => _root.settingsTab.receive.saveToGallery;
  @override
  String get saveToGalleryOff => '有資料夾存在，所以自動閂咗。';
}

// Path: sendPage
class Translations$sendPage$zh_HK extends Translations$sendPage$en {
  Translations$sendPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get verifyingSourceData => '正在驗證來源檔案';
  @override
  String calculatingChecksum({required Object curr, required Object n}) => '計緊 checksum（${curr} / ${n}）';
  @override
  String get waiting => '等緊回應……';
  @override
  String get rejected => '對方拒絕咗個請求。';
  @override
  String get tooManyAttempts => _root.web.tooManyAttempts;
  @override
  String get busy => '對方忙緊另一個請求。';
}

// Path: progressPage
class Translations$progressPage$zh_HK extends Translations$progressPage$en {
  Translations$progressPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get titleSending => 'Send 緊……';
  @override
  String get titleReceiving => '接收緊……';
  @override
  String get savedToGallery => '成功 save 咗落相簿';
  @override
  late final Translations$progressPage$total$zh_HK total = Translations$progressPage$total$zh_HK.internal(_root);
  @override
  late final Translations$progressPage$remainingTime$zh_HK remainingTime = Translations$progressPage$remainingTime$zh_HK.internal(_root);
}

// Path: webSharePage
class Translations$webSharePage$zh_HK extends Translations$webSharePage$en {
  Translations$webSharePage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.sendTab.sendModes.link;
  @override
  String get loading => '開緊個 server……';
  @override
  String get stopping => '閂緊個 server……';
  @override
  String get error => '開 server 嗰陣發生錯誤。';
  @override
  String openLink({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    n,
    one: '喺瀏覽器開啟以下連結：',
    other: '喺瀏覽器開啟以下任何一個連結：',
  );
  @override
  String get requests => '請求';
  @override
  String get noRequests => '未有任何請求。';
  @override
  String get encryption => _root.settingsTab.network.encryption;
  @override
  String get autoAccept => '自動接受請求';
  @override
  String get requirePin => '需要密碼';
  @override
  String pinHint({required Object pin}) => '密碼為「${pin}」';
  @override
  String get encryptionHint => 'LocalSend 用嘅係自我簽署憑證。麻煩你喺瀏覽器度允許咗佢。';
  @override
  String pendingRequests({required Object n}) => '仲有 ${n} 個請求未處理';
}

// Path: webReceivePage
class Translations$webReceivePage$zh_HK extends Translations$webReceivePage$en {
  Translations$webReceivePage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '用 link 接收';
}

// Path: aboutPage
class Translations$aboutPage$zh_HK extends Translations$aboutPage$en {
  Translations$aboutPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '關於 LegnaSend';
  @override
  List<String> get description => [
    'LegnaSend 是開源檔案分享工具，提供多網絡介面連結、裝置網絡標籤和連續傳送佇列。',
  ];
  @override
  String get author => '作者';
  @override
  String get contributors => '貢獻者';
  @override
  String get packagers => '封裝人員';
  @override
  String get translators => '翻譯人員';
  @override
  String get upstreamCredits => '開源致謝';
  @override
  String version({required Object version}) => '版本 ${version}';
  @override
  String get licenseNotices => '授權聲明';
  @override
  String get debugging => '診斷';
}

// Path: donationPage
class Translations$donationPage$zh_HK extends Translations$donationPage$en {
  Translations$donationPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.settingsTab.other.donate;
  @override
  String get info => 'LocalSend 唔單只免費、開源，仲係冇廣告添㗎！如果你鍾意呢個 app，不妨捐款贊助我哋開發？';
  @override
  String donate({required Object amount}) => '捐 ${amount}';
  @override
  String get thanks => '多謝支持！';
  @override
  String get restore => '還原 app 內購買';
}

// Path: directoryWorkspaces
class Translations$directoryWorkspaces$zh_HK extends Translations$directoryWorkspaces$en {
  Translations$directoryWorkspaces$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '工作區';
  @override
  String get create => '建立工作區';
  @override
  String get name => '名稱';
  @override
  String get slug => '自訂路徑';
  @override
  String get root => '本地目錄';
  @override
  String get choose => '選擇目錄';
  @override
  String get visible => '索引可見';
  @override
  String get hidden => '索引隱藏';
  @override
  String get hide => '隱藏';
  @override
  String get show => '顯示';
  @override
  String get closed => '已關閉';
  @override
  String get serving => '正在共享';
  @override
  String get previousServing => '舊配置仍在共享';
  @override
  String get invalid => '來源失效';
  @override
  String get syncing => '正在應用配置';
  @override
  String get serverOff => '服務已停止';
  @override
  String get readOnly => '只讀目錄';
  @override
  String get readOnlyHint => '預設唯讀，可開啟上載。';
  @override
  String get empty => '選擇資料夾，建立工作區。';
  @override
  String get failed => '儲存失敗，請檢查路徑和資料夾權限。';
  @override
  String get syncFailed => '設定未生效，原分享設定保持不變。';
  @override
  String get retry => '重試';
  @override
  String get enable => '開啟';
  @override
  String get close => '關閉';
  @override
  String get destroy => '銷燬工作區';
  @override
  String get validate => '檢查目錄';
  @override
  String get stopHint => '停止分享此工作區？來源檔案會保留。';
  @override
  String get hiddenHint => '不在索引中顯示，知道連結仍可存取。';
  @override
  String get closeToEdit => '修改訪問路徑或源目錄前，請先關閉工作區。';
  @override
  String get invalidInput => '請填寫名稱、唯一的字母數字或連字號路徑，並選擇資料夾。';
  @override
  Map<String, String> get reasons => {
    'missing': '目錄不存在',
    'notDirectory': '不是本地目錄',
    'permissionDenied': '目錄許可權不足',
    'grantUnavailable': '目錄授權不可用，請重新選擇資料夾',
    'ioError': '目錄讀取失敗',
    'timeout': '目錄檢查超時',
  };
  @override
  String get access => '存取保護';
  @override
  String get protected => '密碼保護';
  @override
  String get openAccess => '開放存取';
  @override
  String get password => '新密碼或 PIN';
  @override
  String get confirmPassword => '確認密碼';
  @override
  String get keepPassword => '留空保留現有密碼。';
  @override
  String get passwordInvalid => '請輸入 4–128 個字元，兩次輸入應一致。';
  @override
  String get passwordHint => '修改存取保護會中斷目前下載。';
  @override
  String get accessPending => '存取策略待服務確認';
  @override
  String get uploadPermission => '上傳權限';
  @override
  String get allowUpload => '允許網頁上傳';
  @override
  String get uploadHint => '訪客可直接上載，無需逐次確認。已有檔案不會被覆寫。';
  @override
  String get uploadPending => '上傳權限待同步';
  @override
  String get permissionHint => '上載權限';
  @override
  String get startService => '啟動服務';
  @override
  String get moreAddresses => '其他位址';
  @override
  String get restoreAccess => '重新授權目錄';
  @override
  String get openFailed => '瀏覽器開啟失敗，請複製連結開啟。';
}

// Path: changelogPage
class Translations$changelogPage$zh_HK extends Translations$changelogPage$en {
  Translations$changelogPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '更新記錄';
  @override
  String get language => '更新記錄語言';
  @override
  String get followApp => '跟隨應用程式語言';
  @override
  String fallback({required Object language}) => '目前語言的譯文尚未提供，現顯示 ${language}。';
  @override
  String get loadError => '更新記錄載入失敗。';
  @override
  String get retry => '重試';
}

// Path: whatsNewPage
class Translations$whatsNewPage$zh_HK extends Translations$whatsNewPage$en {
  Translations$whatsNewPage$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String title({required Object version}) => '${version} 有咩新嘢';
  @override
  late final Translations$whatsNewPage$changes$zh_HK changes = Translations$whatsNewPage$changes$zh_HK.internal(_root);
}

// Path: dialogs
class Translations$dialogs$zh_HK extends Translations$dialogs$en {
  Translations$dialogs$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$dialogs$addFile$zh_HK addFile = Translations$dialogs$addFile$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$openFile$zh_HK openFile = Translations$dialogs$openFile$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$addressInput$zh_HK addressInput = Translations$dialogs$addressInput$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$cancelSession$zh_HK cancelSession = Translations$dialogs$cancelSession$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$cannotOpenFile$zh_HK cannotOpenFile = Translations$dialogs$cannotOpenFile$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$encryptionDisabledNotice$zh_HK encryptionDisabledNotice =
      Translations$dialogs$encryptionDisabledNotice$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$errorDialog$zh_HK errorDialog = Translations$dialogs$errorDialog$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$favoriteDialog$zh_HK favoriteDialog = Translations$dialogs$favoriteDialog$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$favoriteDeleteDialog$zh_HK favoriteDeleteDialog = Translations$dialogs$favoriteDeleteDialog$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$favoriteEditDialog$zh_HK favoriteEditDialog = Translations$dialogs$favoriteEditDialog$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$fileInfo$zh_HK fileInfo = Translations$dialogs$fileInfo$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$fileNameInput$zh_HK fileNameInput = Translations$dialogs$fileNameInput$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$historyClearDialog$zh_HK historyClearDialog = Translations$dialogs$historyClearDialog$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$localNetworkUnauthorized$zh_HK localNetworkUnauthorized =
      Translations$dialogs$localNetworkUnauthorized$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$messageInput$zh_HK messageInput = Translations$dialogs$messageInput$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$noFiles$zh_HK noFiles = Translations$dialogs$noFiles$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$noPermission$zh_HK noPermission = Translations$dialogs$noPermission$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$notAvailableOnPlatform$zh_HK notAvailableOnPlatform = Translations$dialogs$notAvailableOnPlatform$zh_HK.internal(
    _root,
  );
  @override
  late final Translations$dialogs$qr$zh_HK qr = Translations$dialogs$qr$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$quickActions$zh_HK quickActions = Translations$dialogs$quickActions$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$quickSaveNotice$zh_HK quickSaveNotice = Translations$dialogs$quickSaveNotice$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$quickSaveFromFavoritesNotice$zh_HK quickSaveFromFavoritesNotice =
      Translations$dialogs$quickSaveFromFavoritesNotice$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$pin$zh_HK pin = Translations$dialogs$pin$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$sendModeHelp$zh_HK sendModeHelp = Translations$dialogs$sendModeHelp$zh_HK.internal(_root);
  @override
  late final Translations$dialogs$zoom$zh_HK zoom = Translations$dialogs$zoom$zh_HK.internal(_root);
}

// Path: sanitization
class Translations$sanitization$zh_HK extends Translations$sanitization$en {
  Translations$sanitization$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get empty => '檔案名稱唔可以係吉嘅。';
  @override
  String get invalid => '檔案名稱唔可以包括唔用得嘅字元。';
}

// Path: tray
class Translations$tray$zh_HK extends Translations$tray$en {
  Translations$tray$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get open => _root.general.open;
  @override
  String get close => '退出 LocalSend';
  @override
  String get closeWindows => '離開';
}

// Path: web
class Translations$web$zh_HK extends Translations$web$en {
  Translations$web$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get waiting => _root.sendPage.waiting;
  @override
  String get enterPin => '輸入密碼';
  @override
  String get invalidPin => '密碼無效';
  @override
  String get tooManyAttempts => '嘗試次數過多，請稍後再試';
  @override
  String get rejected => '已遭對方拒絕';
  @override
  String get files => _root.general.files;
  @override
  String get fileName => '檔案名稱';
  @override
  String get size => '大細';
}

// Path: assetPicker
class Translations$assetPicker$zh_HK extends Translations$assetPicker$en {
  Translations$assetPicker$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get confirm => _root.general.confirm;
  @override
  String get cancel => _root.general.cancel;
  @override
  String get edit => _root.general.edit;
  @override
  String get gifIndicator => 'GIF';
  @override
  String get loadFailed => '載入失敗';
  @override
  String get original => '原始檔案';
  @override
  String get preview => '預覽';
  @override
  String get select => '揀選';
  @override
  String get emptyList => '列表冇嘢';
  @override
  String get unSupportedAssetType => '檔案類型唔支援。';
  @override
  String get unableToAccessAll => '無法存取裝置入面所有檔案';
  @override
  String get viewingLimitedAssetsTip => '你淨係可以睇到個 app 能夠存取嘅檔案同相簿。';
  @override
  String get changeAccessibleLimitedAssets => '撳呢度更新可存取檔案';
  @override
  String get accessAllTip => '個 app 只能夠存取裝置入面部分檔案。要存取所有媒體，你要去系統設定開返個權限。';
  @override
  String get goToSystemSettings => '開啟系統設定';
  @override
  String get accessLimitedAssets => '喺限制存取嘅情況下繼續';
  @override
  String get accessiblePathName => '可存取檔案';
  @override
  String get sTypeAudioLabel => '音樂';
  @override
  String get sTypeImageLabel => '相片';
  @override
  String get sTypeVideoLabel => '影片';
  @override
  String get sTypeOtherLabel => '其他媒體';
  @override
  String get sActionPlayHint => '播放';
  @override
  String get sActionPreviewHint => _root.assetPicker.preview;
  @override
  String get sActionSelectHint => _root.assetPicker.select;
  @override
  String get sActionSwitchPathLabel => '更改路徑';
  @override
  String get sActionUseCameraHint => '影相';
  @override
  String get sNameDurationLabel => '持續時間';
  @override
  String get sUnitAssetCountLabel => '數量';
}

// Path: transferActivity
class Translations$transferActivity$zh_HK extends Translations$transferActivity$en {
  Translations$transferActivity$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '傳輸工作';
  @override
  String get send => '傳送';
  @override
  String get receive => '接收';
  @override
  String get empty => '此方向暫無工作';
  @override
  String get preparing => '準備／驗證中';
  @override
  String get waiting => '等待確認';
  @override
  String get transferring => '傳輸中';
  @override
  String get acknowledge => '收起已結束工作提示';
  @override
  String get details => '工作詳情';
  @override
  String get back => '返回工作清單';
  @override
  String get ended => '此工作已結束或已移除。';
  @override
  String get files => '檔案清單';
  @override
  String get accept => '接收所選檔案';
  @override
  String get decline => '拒絕接收';
  @override
  String get failed => '失敗';
  @override
  String get succeeded => '已完成';
  @override
  String get recoveryWaiting => '等待重試';
  @override
  String get recoveryRetryable => '可以重試';
  @override
  String get recoveryAuthorization => '需要重新授權';
  @override
  String get recoverySourceChanged => '來源已變更 · 請新建傳送';
  @override
  String get recoveryInvalidResponse => '還原回應未通過驗證';
  @override
  String get recoveryRetained => '已保留部分資料';
  @override
  String get recoveryRetentionUnknown => '保留狀態未確認';
  @override
  String get recoveryNotRetained => '沒有可重用的檢查點';
}

// Path: webPreview
class Translations$webPreview$zh_HK extends Translations$webPreview$en {
  Translations$webPreview$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get preview => '預覽';
  @override
  String get closePreview => '關閉預覽';
  @override
  String get downloadOriginal => '下載原始檔案';
  @override
  String get previewLoading => '正在載入預覽…';
  @override
  String get previewError => '預覽失敗，請下載原始檔案後開啟。';
  @override
  String get previewUnsupported => '目前瀏覽器或檔案格式不支援預覽。';
  @override
  String get imageZoomIn => '放大';
  @override
  String get imageZoomOut => '縮小';
  @override
  String get imageFit => '適應視窗';
  @override
  String get imageActual => '實際尺寸';
  @override
  String get imageView => '圖片預覽';
  @override
  String get imageScale => '縮放比例';
  @override
  String get imageHint => '拖動平移，雙指或 Ctrl/⌘ + 滾輪縮放。鍵盤：加減、方向鍵，0 適應視窗，1 實際尺寸。';
}

// Path: webTextPreview
class Translations$webTextPreview$zh_HK extends Translations$webTextPreview$en {
  Translations$webTextPreview$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get encoding => '編碼';
  @override
  String get auto => '自動（BOM / UTF-8）';
  @override
  String get previous => '上一節';
  @override
  String get next => '下一節';
  @override
  String get more => '載入更多';
  @override
  String get retry => '重新載入預覽';
  @override
  String get indexed => '已索引';
  @override
  String get lines => '行數';
  @override
  String get section => '節';
  @override
  String get complete => '檔案結尾';
  @override
  String get loading => '正在載入文字…';
  @override
  String get view => '文字預覽';
  @override
  String get range => '此資料來源不支援按範圍讀取文字，請下載原始檔案。';
  @override
  String get changed => '分享檔案已變更，請重新開啟分享後預覽。';
  @override
  String get decode => '文字編碼不符，請選擇其他編碼或下載原始檔案。';
  @override
  String get failed => '文字載入失敗，請檢查連線後重新載入預覽。';
  @override
  String get unsupported => '此瀏覽器不支援串流文字預覽。';
  @override
  String get hint => '僅渲染可見行與少量緩衝行，自動換行讓長文字自然適應頁面寬度。';
  @override
  String get wrap => '自動換行';
  @override
  String get numbers => '顯示行號';
  @override
  String get search => '搜尋內文';
  @override
  String get searchScope => '搜尋範圍';
  @override
  String get loaded => '已索引內容';
  @override
  String get full => '整個檔案';
  @override
  String get find => '尋找';
  @override
  String get stop => '停止搜尋';
  @override
  String get caseSensitive => '區分大小寫';
  @override
  String get previousMatch => '上一個符合項目';
  @override
  String get nextMatch => '下一個符合項目';
  @override
  String get matches => '符合項目';
  @override
  String get scanned => '已掃描';
  @override
  String get searching => '正在搜尋…';
  @override
  String get searchDone => '搜尋完成';
  @override
  String get searchStopped => '搜尋已停止';
  @override
  String get noMatches => '已掃描內容中沒有符合項目';
  @override
  String get searchLimit => '已顯示前 1,000 個符合項目，請縮小關鍵字範圍繼續搜尋。';
  @override
  String get clearSearch => '清除搜尋';
  @override
  String get rendered => '閱讀檢視';
  @override
  String get source => '原始文字';
  @override
  String get markdownHint => 'Markdown 搜尋涵蓋原始文字內文，結果定位到準確的原始文字位置。';
  @override
  String get markdownLimit => '按小節延遲載入完整語法區塊；參照連結隨定義被索引而更新。';
  @override
  String get markdownFailed => '此文件暫未完成排版，可繼續使用原始文字閱讀器。';
  @override
  String get diagramQueued => '圖表 · 接近視口時載入';
  @override
  String get diagramLoading => '正在繪製圖表…';
  @override
  String get diagramReady => '圖表';
  @override
  String get diagramFailed => '此圖表暫未繪製成功，可查看原始碼或重試。';
  @override
  String get diagramLimit => '此圖表超出預覽限制，仍可查看原始碼。';
  @override
  String get diagramSource => '原始碼';
  @override
  String get diagramRender => '圖表';
  @override
  String get diagramRetry => '重試';
  @override
  String get diagramFit => '適應';
  @override
  String get diagramZoomIn => '放大';
  @override
  String get diagramZoomOut => '縮小';
  @override
  String get diagramExpand => '全部展開';
  @override
  String get diagramCollapse => '摺疊分支';
  @override
  String get diagramHint => '拖動平移；使用按鈕或 Ctrl/⌘ + 滾輪縮放。';
  @override
  String get diagramUnavailable => '目前瀏覽器未啟用圖表繪製，已保留原始碼。';
  @override
  String get markdownStreaming => '按小節延遲載入完整語法區塊；參照連結隨定義被索引而更新。';
  @override
  String get markdownParagraphSource => '超大段落 · 以閱讀視窗展示完整原始文字，跨視窗行內語法保持原文。';
  @override
  String get markdownBlockLimit => '目前語法區塊超出閱讀預算，請切換原始文字繼續查看完整內容。';
  @override
  String get markdownScan => '索引參照定義';
  @override
  String get markdownStop => '停止索引';
  @override
  String get markdownSourceWindow => '超大語法區塊 · 以閱讀視窗展示完整原始文字，跨視窗的格式保持原文。';
}

// Path: transportSecurity
class Translations$transportSecurity$zh_HK extends Translations$transportSecurity$en {
  Translations$transportSecurity$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'HTTPS 傳輸（TLS）';
  @override
  String get description => '保護裝置間傳輸連線上的資料，不會加密儲存的檔案，也不會設定檔案密碼。';
  @override
  String get certificate => 'LegnaSend 使用本機產生的自簽署 TLS 憑證，瀏覽器可能顯示此裝置的憑證信任提示。';
  @override
  String get httpTitle => '正在使用 HTTP 傳輸';
  @override
  String get httpDescription => 'HTTPS 傳輸已關閉，目前使用 HTTP，傳輸連線不受 TLS 保護。啟用「HTTPS 傳輸（TLS）」可保護連線，不會變更儲存的檔案。';
  @override
  String get discoveryHint => '請檢查網路是否可達、探索連接埠與多播設定，以及 HTTP/HTTPS 組態。探索失敗時可嘗試目標裝置的 IP 和實際服務連接埠。';
  @override
  String get connectionHint => '請檢查目標 IP 和實際服務連接埠是否可達，以及 HTTP/HTTPS 組態是否相容。Wi-Fi 存取點隔離或防火牆可能阻止裝置間通訊。';
  @override
  String get updateFailed => '傳輸協定切換失敗，請檢查實際服務狀態後重試。';
  @override
  String peerProtocol({required Object protocol}) => '對端 · ${protocol}';
}

// Path: transferSpeed
class Translations$transferSpeed$zh_HK extends Translations$transferSpeed$en {
  Translations$transferSpeed$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String current({required Object speed}) => '目前速度：${speed}';
  @override
  String average({required Object speed}) => '平均速度：${speed}';
  @override
  String get measuring => '正在測速…';
}

// Path: transferNavigation
class Translations$transferNavigation$zh_HK extends Translations$transferNavigation$en {
  Translations$transferNavigation$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get hide => '收起面板';
  @override
  String get keepRunning => '返回和收起不會停止傳輸。';
  @override
  String get sharing => '連結分享中';
  @override
  String get keepSharing => '返回只隱藏頁面，分享繼續執行；可從分享標記重新開啟。';
  @override
  String get stopSharing => '停止連結分享';
  @override
  String get stopTitle => '停止連結分享？';
  @override
  String get stopBody => '僅結束臨時連結的下載工作階段並停止新的網頁上傳；目錄工作區、監聽服務、API 和已核准的原生傳輸繼續運作。';
  @override
  String get restartTitle => '重新啟動分享服務？';
  @override
  String get restartBody => '切換 HTTP／HTTPS 會重新啟動共用監聽器，中斷其活動連線；工作區定義和臨時檔案選擇會保留。';
  @override
  String get unknown => '目前沒有分享';
  @override
  String get replaceTitle => '更新臨時共享存取？';
  @override
  String get replaceBody => '僅結束本臨時共享的下載工作階段，目錄工作區和原生傳輸繼續運作。';
}

// Path: networkEnvironment
class Translations$networkEnvironment$zh_HK extends Translations$networkEnvironment$en {
  Translations$networkEnvironment$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get vpn => '系統 VPN';
  @override
  String get tunnel => 'VPN／隧道介面';
  @override
  String get local => '本機介面';
  @override
  String get proxy => '系統代理';
  @override
  String get title => '網路路徑';
  @override
  String get unknown => '狀態未知';
  @override
  String get detected => '已偵測到';
  @override
  String get notDetected => '未偵測到';
  @override
  String get routeHint => '選擇對方裝置可存取的本機或 VPN 位址。';
}

// Path: linkWorkspace
class Translations$linkWorkspace$zh_HK extends Translations$linkWorkspace$en {
  Translations$linkWorkspace$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '連結工作區';
  @override
  String sharedCount({required Object n}) => '已分享檔案：${n}';
  @override
  String get allowUpload => '允許網頁上傳';
  @override
  String get allowUploadHint => '僅控制新的網頁請求，已批准的傳輸繼續；新請求仍遵循用戶端的接收確認設定。';
  @override
  String get autoReceive => '自動接收網頁上傳';
  @override
  String get autoDownload => '自動批准網頁下載';
  @override
  String get appendHint => '加入的檔案保留在目前工作區，原有檔案連結及已批准的工作階段繼續有效。';
}

// Path: integrationApi
class Translations$integrationApi$zh_HK extends Translations$integrationApi$en {
  Translations$integrationApi$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'API';
  @override
  String get subtitle => '本機程式整合，沿用目前分享連接埠。';
  @override
  String get enable => '啟用 API';
  @override
  String get requireKey => '要求 API 金鑰';
  @override
  String get isolation => 'API 開關不會停止原生傳送或網頁工作區。';
  @override
  String get live => '已生效';
  @override
  String get off => '已停用';
  @override
  String get waiting => '已儲存 · 等待服務';
  @override
  String get syncing => '正在套用策略…';
  @override
  String get previous => '舊策略可能仍在生效';
  @override
  String get failed => '儲存或套用失敗，請在下方重試。';
  @override
  String get corrupt => 'API 設定需要復原。原資料已保留，可重試讀取或明確重設。';
  @override
  String get reset => '重設 API 設定';
  @override
  String get resetHint => '刪除全部 API 金鑰並恢復預設停用狀態，保留原生傳送及工作區檔案。';
  @override
  String get refresh => '重新整理狀態';
  @override
  String get startService => '啟動接收服務';
  @override
  String get addresses => '服務位址';
  @override
  String get addressHint => '使用實際位址；HTTPS 需信任裝置憑證。網路標籤描述介面，不代表已驗證繞過 VPN。';
  @override
  String get policy => '存取與配額';
  @override
  String get editPolicy => '編輯策略';
  @override
  String get fixedWindow => '秒與分鐘固定視窗同時約束；並行是活動回應數，不是連線數或下載頻寬。0 僅取消該項限額，伺服器資源上限仍生效。';
  @override
  String get global => '全域';
  @override
  String get perKey => '每個金鑰';
  @override
  String get anonymous => '匿名來源';
  @override
  String get second => '請求／秒';
  @override
  String get minute => '請求／分鐘';
  @override
  String get concurrent => '活動回應';
  @override
  String get origins => '允許的跨域來源';
  @override
  String get originsHint => '每行一個標準 http(s) 來源，不含路徑；同源呼叫仍允許。';
  @override
  String get anonymousHint => '不帶金鑰時僅可讀取匿名範圍內可見、未保護的工作區。隱藏／密碼工作區及請求歷史不開放，錯誤金鑰不會降級匿名。';
  @override
  String get allowAnonymous => '允許匿名存取？';
  @override
  String get disableHint => '只停止整合 API 回應；其他分享及原 LocalSend 傳送繼續。';
  @override
  String get keys => 'API 金鑰';
  @override
  String get createKey => '產生金鑰';
  @override
  String get keyName => '金鑰名稱';
  @override
  String get empty => '尚未有 API 金鑰。';
  @override
  String get once => '現在儲存此金鑰';
  @override
  String get onceHint => '明文僅在此顯示，不儲存；可重複呼叫，直到撤銷或到期。關閉不會自動複製。';
  @override
  String get revoke => '撤銷金鑰';
  @override
  String get revokeHint => '撤銷此金鑰並結束其活動 API 回應；其他金鑰及原生傳送繼續。';
  @override
  String get pendingKey => '已儲存 · 尚未確認生效';
  @override
  String get removedLive => '已移除的金鑰可能仍生效，需重試套用待處理策略。';
  @override
  String get permissions => '動作權限';
  @override
  String get scopeService => '服務狀態與契約';
  @override
  String get scopeWorkspaces => '工作區描述';
  @override
  String get scopeFiles => '檔案清單與下載';
  @override
  String get scopeRequests => '全域脫敏請求歷史';
  @override
  String get allWorkspaces => '全部現有及未來工作區';
  @override
  String get selectWorkspaces => '工作區範圍';
  @override
  String get grantHint => '僅授予所需動作及工作區。上傳與工作區管理是獨立明確授權；既有及預設密鑰維持唯讀。';
  @override
  String get expiry => '到期時間';
  @override
  String get days30 => '30 天';
  @override
  String get days90 => '90 天';
  @override
  String get never => '不過期';
  @override
  String get expired => '已到期';
  @override
  String get invalid => '請檢查名稱、配額、來源及所選權限／工作區。';
  @override
  String get copy => '複製';
  @override
  String get copied => '已複製';
  @override
  String get close => '完成';
  @override
  String get more => '下一頁金鑰';
  @override
  String get previousPage => '上一頁金鑰';
  @override
  String get readOnly => '讀取與明確授權寫入';
  @override
  String get nextStage => '明確授權的金鑰可上傳、管理本機批准來源的工作區，以及探索裝置和控制自身 API 建立的傳送工作；通用快取／設定介面及無關原生工作控制仍待開發。';
  @override
  String get copyFailed => '複製失敗，可選取文字手動複製。';
  @override
  String get updated => '更新於';
  @override
  String get unconfirmed => '等待服務確認';
  @override
  String get fallback => 'API text is shown in English.';
  @override
  String get documentation => '開發文件';
  @override
  String get directoryContract => '目錄介面契約';
  @override
  String get documentationHint => '離線查閱：設定、權限、各介面、參數、錯誤、重試，以及 cURL／JavaScript／Python 範例。';
  @override
  String get scopeUpload => '上傳檔案（明確寫入權限）';
  @override
  String get scopeManage => '管理工作區資訊與分享狀態';
}

// Path: apiExplorer
class Translations$apiExplorer$zh_HK extends Translations$apiExplorer$en {
  Translations$apiExplorer$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'API 介面瀏覽與測試';
  @override
  String get search => '搜尋介面或說明';
  @override
  String get execute => '執行請求';
  @override
  String get hint => '請求使用實際本機監聽及其鑑權／配額：讀取最多 12 秒，工作區管理 35 秒，上傳依檔案大小設定預算。請求及憑據不儲存。';
  @override
  String get all => '全部';
  @override
  String get service => '服務';
  @override
  String get workspaces => '工作區';
  @override
  String get files => '檔案';
  @override
  String get history => '請求記錄';
  @override
  String get noResults => '沒有符合的介面';
  @override
  String get readOnly => '唯讀測試';
  @override
  String get token => 'API 金鑰（可留空）';
  @override
  String get tokenHint => '貼上已產生金鑰，或留空測試匿名存取。僅在此頁面開啟時保留，不寫入呼叫範例。';
  @override
  String get clear => '清除憑據';
  @override
  String get running => '請求中…';
  @override
  String get reset => '重設參數';
  @override
  String get invalid => '請檢查必填欄位和參數範圍。';
  @override
  String get failed => '請求失敗或服務已變更，請對目前監聽器重試。';
  @override
  String get headers => '回應標頭';
  @override
  String get response => '回應內容';
  @override
  String get truncated => '回應最多顯示 256 KiB，二進位樣本最多 4 KiB；這不是完整下載。';
  @override
  String get binary => '十六進位檔案樣本，不會儲存檔案；預設 Range 為 bytes=0-4095。';
  @override
  String get examples => '呼叫範例';
  @override
  String get responses => '回應契約';
  @override
  String get schemas => '資料模型';
}

// Path: sharedFileManagement
class Translations$sharedFileManagement$zh_HK extends Translations$sharedFileManagement$en {
  Translations$sharedFileManagement$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '分享檔案';
  @override
  String get hint => '撤下或替換檔案，不關閉分享；其他檔案與接收工作繼續。';
  @override
  String get search => '搜尋分享檔案';
  @override
  String get withdraw => '撤下檔案';
  @override
  String get replace => '替換檔案';
  @override
  String get confirmBody => '僅停止此檔案的待處理與活動下載。替換檔案會產生新連結，舊下載不會續傳到新內容；不會刪除來源檔案。';
  @override
  String get selectOne => '請選擇一個替換檔案。';
  @override
  String get changed => '分享或檔案已變更，請重新開啟檔案管理後再試。';
  @override
  String get applied => '分享檔案已更新。';
  @override
  String get failed => '更新未確認，保留原清單；請重試或重新開啟分享。';
  @override
  String get empty => '沒有符合的分享檔案。';
  @override
  String get previous => '上一頁';
  @override
  String get next => '下一頁';
}

// Path: sendQueue
class Translations$sendQueue$zh_HK extends Translations$sendQueue$en {
  Translations$sendQueue$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get singleFileRetryNewTask => '將此檔案作為新傳輸工作重試';
  @override
  String get singleFileRetryStarted => '已建立新的傳輸工作，已完成檔案保持不變。';
  @override
  String get title => '傳送佇列';
  @override
  String get queued => '排隊中';
  @override
  String get running => '傳送中';
  @override
  String get succeeded => '已完成';
  @override
  String get failed => '傳送失敗';
  @override
  String get canceled => '已取消';
  @override
  String get retry => '重試未完成檔案';
  @override
  String files({required Object n}) => '${n} 個檔案';
  @override
  String drop({required Object device}) => '放開以傳送給 ${device}';
  @override
  String added({required Object device, required Object n}) => '已加入佇列：${device}，${n} 個檔案';
}

// Path: receiveTab.infoBox
class Translations$receiveTab$infoBox$zh_HK extends Translations$receiveTab$infoBox$en {
  Translations$receiveTab$infoBox$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get ip => 'IP：';
  @override
  String get port => 'Port：';
  @override
  String get alias => '名：';
}

// Path: receiveTab.quickSave
class Translations$receiveTab$quickSave$zh_HK extends Translations$receiveTab$quickSave$en {
  Translations$receiveTab$quickSave$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get off => _root.general.off;
  @override
  String get favorites => '已收藏裝置';
  @override
  String get on => _root.general.on;
}

// Path: sendTab.selection
class Translations$sendTab$selection$zh_HK extends Translations$sendTab$selection$en {
  Translations$sendTab$selection$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '揀選';
  @override
  String files({required Object files}) => '檔案：${files}';
  @override
  String size({required Object size}) => '大細：${size}';
}

// Path: sendTab.picker
class Translations$sendTab$picker$zh_HK extends Translations$sendTab$picker$en {
  Translations$sendTab$picker$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get file => '檔案';
  @override
  String get folder => '資料夾';
  @override
  String get media => '媒體';
  @override
  String get text => '文字';
  @override
  String get app => '應用程式';
  @override
  String get clipboard => '貼上';
}

// Path: sendTab.sendModes
class Translations$sendTab$sendModes$zh_HK extends Translations$sendTab$sendModes$en {
  Translations$sendTab$sendModes$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get single => '單一接收者';
  @override
  String get multiple => '多個接收者';
  @override
  String get link => '用 link 分享';
}

// Path: settingsTab.general
class Translations$settingsTab$general$zh_HK extends Translations$settingsTab$general$en {
  Translations$settingsTab$general$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '一般';
  @override
  String get brightness => '亮度';
  @override
  late final Translations$settingsTab$general$brightnessOptions$zh_HK brightnessOptions =
      Translations$settingsTab$general$brightnessOptions$zh_HK.internal(_root);
  @override
  String get color => '色彩';
  @override
  late final Translations$settingsTab$general$colorOptions$zh_HK colorOptions = Translations$settingsTab$general$colorOptions$zh_HK.internal(_root);
  @override
  String get language => '語言';
  @override
  late final Translations$settingsTab$general$languageOptions$zh_HK languageOptions = Translations$settingsTab$general$languageOptions$zh_HK.internal(
    _root,
  );
  @override
  String get saveWindowPlacement => '退出嗰陣記低視窗位置';
  @override
  String get saveWindowPlacementWindows => '離開嗰陣記低視窗位置';
  @override
  String get minimizeToTray => '關閉嗰陣縮細做通知圖示';
  @override
  String get launchAtStartup => '開機自動啟動';
  @override
  String get launchMinimized => '自動啟動成通知圖示';
  @override
  String get showInContextMenu => '喺檔案功能表嘅「傳送到」項目顯示 LocalSend';
  @override
  String get animations => '動畫';
}

// Path: settingsTab.receive
class Translations$settingsTab$receive$zh_HK extends Translations$settingsTab$receive$en {
  Translations$settingsTab$receive$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '接收';
  @override
  String get quickSave => _root.general.quickSave;
  @override
  String get quickSaveFromFavorites => _root.general.quickSaveFromFavorites;
  @override
  String get requirePin => _root.webSharePage.requirePin;
  @override
  String get autoFinish => '完成後自動關閉傳輸畫面';
  @override
  String get destination => '儲存位置';
  @override
  String get downloads => '（下載資料夾）';
  @override
  String get saveToGallery => 'Save 落相簿';
  @override
  String get saveToHistory => 'Save 去歷史紀錄';
  @override
  String get verifyChecksums => '接收檔案嗰陣驗證 checksum';
}

// Path: settingsTab.send
class Translations$settingsTab$send$zh_HK extends Translations$settingsTab$send$en {
  Translations$settingsTab$send$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '傳送';
  @override
  String get shareViaLinkAutoAccept => '用 link 分享檔案嗰陣自動接收';
  @override
  String get createChecksums => '傳送檔案嗰陣建立 checksum';
}

// Path: settingsTab.network
class Translations$settingsTab$network$zh_HK extends Translations$settingsTab$network$en {
  Translations$settingsTab$network$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '網絡';
  @override
  String get needRestart => '熄咗個 server 再開過，設定先會生效！';
  @override
  String get server => 'Server';
  @override
  String get alias => '名';
  @override
  String get deviceType => '裝置類型';
  @override
  String get deviceModel => '裝置型號';
  @override
  String get port => 'Port';
  @override
  String get network => '網絡';
  @override
  late final Translations$settingsTab$network$networkOptions$zh_HK networkOptions = Translations$settingsTab$network$networkOptions$zh_HK.internal(
    _root,
  );
  @override
  String get discoveryTimeout => '裝置搜尋逾時';
  @override
  String get useSystemName => '用系統名稱';
  @override
  String get generateRandomAlias => '求其改個名';
  @override
  String portWarning({required Object defaultPort}) => '改 port 嘅話其他裝置有機會偵測唔到你。（預設：${defaultPort}）';
  @override
  String get encryption => '加密傳送';
  @override
  String get multicastGroup => '多播 IP 地址';
  @override
  String multicastGroupWarning({required Object defaultMulticast}) => '用自訂多播地址嘅話其他裝置有機會偵測唔到你。（預設：${defaultMulticast}）';
}

// Path: settingsTab.other
class Translations$settingsTab$other$zh_HK extends Translations$settingsTab$other$en {
  Translations$settingsTab$other$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '其他';
  @override
  String get support => '支援 LocalSend';
  @override
  String get donate => '捐款';
  @override
  String get privacyPolicy => '私隱權政策';
  @override
  String get termsOfUse => '服務條款';
}

// Path: troubleshootPage.firewall
class Translations$troubleshootPage$firewall$zh_HK extends Translations$troubleshootPage$firewall$en {
  Translations$troubleshootPage$firewall$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '我 send 到嘢但係接收唔到。';
  @override
  String solution({required Object port}) => '應該係防火牆嘅問題，可以透過允許接受 port ${port} 嘅連線（UDP 同 TCP）嚟解決。';
  @override
  String get openFirewall => '開啟防火牆設定';
}

// Path: troubleshootPage.noDiscovery
class Translations$troubleshootPage$noDiscovery$zh_HK extends Translations$troubleshootPage$noDiscovery$en {
  Translations$troubleshootPage$noDiscovery$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '呢部機偵測唔到其他裝置。';
  @override
  String get solution => '請確保所有裝置都駁緊同一個 Wi‑Fi 網絡同用緊相同嘅設定（port、多播 IP 地址同有冇開加密傳送）。你亦都可以試下人手輸入目標裝置嘅 IP 地址。如果噉樣 work，就可以收藏呢部裝置，等佢日後可以自動偵測到，唔使再輸入。';
}

// Path: troubleshootPage.noConnection
class Translations$troubleshootPage$noConnection$zh_HK extends Translations$troubleshootPage$noConnection$en {
  Translations$troubleshootPage$noConnection$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '兩部裝置都偵測唔到同 send 唔到嘢畀對方。';
  @override
  String get solution =>
      '如果兩邊都發生同樣嘅情況，你要 check 清楚兩邊係咪駁緊同一個 Wi‑Fi 網絡同用緊相同嘅設定（port、多播 IP 地址同有冇開加密傳送）。亦可能係個 Wi‑Fi 唔畀裝置之間通訊，呢種情況下要喺 router 嗰邊熄咗「接入點 (AP) 隔離」模式至得。';
}

// Path: receiveHistoryPage.entryActions
class Translations$receiveHistoryPage$entryActions$zh_HK extends Translations$receiveHistoryPage$entryActions$en {
  Translations$receiveHistoryPage$entryActions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get open => _root.dialogs.openFile.title;
  @override
  String get showInFolder => '喺檔案瀏覽器顯示';
  @override
  String get info => '資訊';
  @override
  String get deleteFromHistory => '刪走呢筆記錄';
}

// Path: deviceDetailsPage.info
class Translations$deviceDetailsPage$info$zh_HK extends Translations$deviceDetailsPage$info$en {
  Translations$deviceDetailsPage$info$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get name => '名稱';
  @override
  String get address => '地址';
  @override
  String get version => '版本';
  @override
  String protocol({required Object version}) => 'Protocol v${version}';
}

// Path: deviceDetailsPage.logs
class Translations$deviceDetailsPage$logs$zh_HK extends Translations$deviceDetailsPage$logs$en {
  Translations$deviceDetailsPage$logs$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '記錄';
  @override
  String get empty => '冇任何記錄。';
  @override
  String discovered({required Object protocol, required Object host}) => '透過 ${protocol} (${host}) 偵測到';
  @override
  String updated({required Object protocol, required Object host}) => '透過 ${protocol} (${host}) 更新';
}

// Path: progressPage.total
class Translations$progressPage$total$zh_HK extends Translations$progressPage$total$en {
  Translations$progressPage$total$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$progressPage$total$title$zh_HK title = Translations$progressPage$total$title$zh_HK.internal(_root);
  @override
  String count({required Object curr, required Object n}) => '檔案：${curr} / ${n}';
  @override
  String size({required Object curr, required Object n}) => '大細：${curr} / ${n}';
  @override
  String speed({required Object speed}) => '速度：${speed}/s';
}

// Path: progressPage.remainingTime
class Translations$progressPage$remainingTime$zh_HK extends Translations$progressPage$remainingTime$en {
  Translations$progressPage$remainingTime$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String minutesUnit({required num m}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    m,
    other: '${m} 分鐘',
  );
  @override
  String hoursUnit({required num h}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    h,
    other: '${h} 個鐘頭',
  );
  @override
  String minutes({required Object m, required Object ss}) => '${m}:${ss}';
  @override
  String hours({required num h, required num m}) =>
      '${_root.progressPage.remainingTime.hoursUnit(h: h)} ${_root.progressPage.remainingTime.minutesUnit(m: m)}';
}

// Path: whatsNewPage.changes
class Translations$whatsNewPage$changes$zh_HK extends Translations$whatsNewPage$changes$en {
  Translations$whatsNewPage$changes$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$whatsNewPage$changes$v1_0_0$zh_HK v1_0_0 = Translations$whatsNewPage$changes$v1_0_0$zh_HK.internal(_root);
}

// Path: dialogs.addFile
class Translations$dialogs$addFile$zh_HK extends Translations$dialogs$addFile$en {
  Translations$dialogs$addFile$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '將檔案加至選擇';
  @override
  String get content => '想加入咩檔案？';
}

// Path: dialogs.openFile
class Translations$dialogs$openFile$zh_HK extends Translations$dialogs$openFile$en {
  Translations$dialogs$openFile$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '開啟檔案';
  @override
  String get content => '你係咪要開啟接收咗嘅檔案？';
}

// Path: dialogs.addressInput
class Translations$dialogs$addressInput$zh_HK extends Translations$dialogs$addressInput$en {
  Translations$dialogs$addressInput$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '輸入地址';
  @override
  String get hashtag => 'Hashtag';
  @override
  String get ip => 'IP 地址';
  @override
  String get recentlyUsed => '輸入記錄：';
}

// Path: dialogs.cancelSession
class Translations$dialogs$cancelSession$zh_HK extends Translations$dialogs$cancelSession$en {
  Translations$dialogs$cancelSession$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '取消檔案傳輸';
  @override
  String get content => '你係咪要放棄傳輸檔案？';
}

// Path: dialogs.cannotOpenFile
class Translations$dialogs$cannotOpenFile$zh_HK extends Translations$dialogs$cannotOpenFile$en {
  Translations$dialogs$cannotOpenFile$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '無法開啟檔案';
  @override
  String content({required Object file}) => '檔案「${file}」開唔到喎，係咪畀人郁過、改過名或者剷走咗？';
}

// Path: dialogs.encryptionDisabledNotice
class Translations$dialogs$encryptionDisabledNotice$zh_HK extends Translations$dialogs$encryptionDisabledNotice$en {
  Translations$dialogs$encryptionDisabledNotice$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '加密已停用';
  @override
  String get content => '而家會透過未經加密嘅 HTTP 協定嚟通訊。要用 HTTPS 請開返加密。';
}

// Path: dialogs.errorDialog
class Translations$dialogs$errorDialog$zh_HK extends Translations$dialogs$errorDialog$en {
  Translations$dialogs$errorDialog$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.error;
}

// Path: dialogs.favoriteDialog
class Translations$dialogs$favoriteDialog$zh_HK extends Translations$dialogs$favoriteDialog$en {
  Translations$dialogs$favoriteDialog$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '收藏';
  @override
  String get noFavorites => '未收藏任何裝置。';
  @override
  String get addFavorite => _root.general.add;
}

// Path: dialogs.favoriteDeleteDialog
class Translations$dialogs$favoriteDeleteDialog$zh_HK extends Translations$dialogs$favoriteDeleteDialog$en {
  Translations$dialogs$favoriteDeleteDialog$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '取消收藏裝置';
  @override
  String content({required Object name}) => '你係咪要取消收藏裝置「${name}」？';
}

// Path: dialogs.favoriteEditDialog
class Translations$dialogs$favoriteEditDialog$zh_HK extends Translations$dialogs$favoriteEditDialog$en {
  Translations$dialogs$favoriteEditDialog$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get titleAdd => '新增至收藏';
  @override
  String get titleEdit => '編輯';
  @override
  String get name => '名';
  @override
  String get auto => '（自動）';
  @override
  String get ip => 'IP 地址';
  @override
  String get port => 'Port';
}

// Path: dialogs.fileInfo
class Translations$dialogs$fileInfo$zh_HK extends Translations$dialogs$fileInfo$en {
  Translations$dialogs$fileInfo$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '檔案資訊';
  @override
  String get fileName => '檔案名稱：';
  @override
  String get path => '路徑：';
  @override
  String get size => '大小：';
  @override
  String get sender => '傳送者：';
  @override
  String get time => '時間：';
}

// Path: dialogs.fileNameInput
class Translations$dialogs$fileNameInput$zh_HK extends Translations$dialogs$fileNameInput$en {
  Translations$dialogs$fileNameInput$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '輸入檔案名稱';
  @override
  String original({required Object original}) => '原名：${original}';
}

// Path: dialogs.historyClearDialog
class Translations$dialogs$historyClearDialog$zh_HK extends Translations$dialogs$historyClearDialog$en {
  Translations$dialogs$historyClearDialog$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '清除歷史記錄';
  @override
  String get content => '你係咪真係要剷走全部歷史記錄？';
}

// Path: dialogs.localNetworkUnauthorized
class Translations$dialogs$localNetworkUnauthorized$zh_HK extends Translations$dialogs$localNetworkUnauthorized$en {
  Translations$dialogs$localNetworkUnauthorized$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.dialogs.noPermission.title;
  @override
  String get description => '喺冇權掃描區域網絡嘅情況下 LocalSend 唔會偵測到其他裝置。麻煩你喺系統設定開返呢個權限。';
  @override
  String get gotoSettings => '開啟系統設定';
}

// Path: dialogs.messageInput
class Translations$dialogs$messageInput$zh_HK extends Translations$dialogs$messageInput$en {
  Translations$dialogs$messageInput$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '輸入訊息';
  @override
  String get multiline => '多行';
}

// Path: dialogs.noFiles
class Translations$dialogs$noFiles$zh_HK extends Translations$dialogs$noFiles$en {
  Translations$dialogs$noFiles$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '冇揀選檔案';
  @override
  String get content => '最少需要揀選一個檔案。';
}

// Path: dialogs.noPermission
class Translations$dialogs$noPermission$zh_HK extends Translations$dialogs$noPermission$en {
  Translations$dialogs$noPermission$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '權限閂咗';
  @override
  String get content => '你冇畀足夠權限我哋進行處理。麻煩你喺系統設定開返啲權限。';
}

// Path: dialogs.notAvailableOnPlatform
class Translations$dialogs$notAvailableOnPlatform$zh_HK extends Translations$dialogs$notAvailableOnPlatform$en {
  Translations$dialogs$notAvailableOnPlatform$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '無法使用';
  @override
  String get content => '此功能只適用於：';
}

// Path: dialogs.qr
class Translations$dialogs$qr$zh_HK extends Translations$dialogs$qr$en {
  Translations$dialogs$qr$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'QR Code';
}

// Path: dialogs.quickActions
class Translations$dialogs$quickActions$zh_HK extends Translations$dialogs$quickActions$en {
  Translations$dialogs$quickActions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '快速動作';
  @override
  String get counter => '計數器';
  @override
  String get prefix => '前綴';
  @override
  String get padZero => '補零';
  @override
  String get sortBeforeCount => '事前跟字母排序';
  @override
  String get random => '隨機';
}

// Path: dialogs.quickSaveNotice
class Translations$dialogs$quickSaveNotice$zh_HK extends Translations$dialogs$quickSaveNotice$en {
  Translations$dialogs$quickSaveNotice$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.quickSave;
  @override
  String get content => '自動接受所有檔案傳輸請求。留意返，噉樣會令呢個網絡嘅所有人都 send 得嘢畀你。';
}

// Path: dialogs.quickSaveFromFavoritesNotice
class Translations$dialogs$quickSaveFromFavoritesNotice$zh_HK extends Translations$dialogs$quickSaveFromFavoritesNotice$en {
  Translations$dialogs$quickSaveFromFavoritesNotice$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.quickSaveFromFavorites;
  @override
  List<String> get content => [
    '自動接受已收藏裝置嘅檔案傳輸請求。',
    '警告：呢個選項目前並非絕對安全，黑客只要攞到你任何一部已收藏裝置嘅指紋，就可以無限制噉 send 嘢畀你。',
    '不過，揀已收藏裝置點都安全過揀所有裝置嘅。',
  ];
}

// Path: dialogs.pin
class Translations$dialogs$pin$zh_HK extends Translations$dialogs$pin$en {
  Translations$dialogs$pin$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.web.enterPin;
}

// Path: dialogs.sendModeHelp
class Translations$dialogs$sendModeHelp$zh_HK extends Translations$dialogs$sendModeHelp$en {
  Translations$dialogs$sendModeHelp$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.sendTab.sendMode;
  @override
  String get single => '淨係 send 畀一部裝置，傳輸完成後會清除揀選項目。';
  @override
  String get multiple => '一次過 send 畀多部裝置，揀選項目會一路保留。';
  @override
  String get link => '冇裝 LocalSend 嘅裝置可以透過條 link 嚟 download 返揀選嘅項目。';
}

// Path: dialogs.zoom
class Translations$dialogs$zoom$zh_HK extends Translations$dialogs$zoom$en {
  Translations$dialogs$zoom$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get title => '網址';
}

// Path: settingsTab.general.brightnessOptions
class Translations$settingsTab$general$brightnessOptions$zh_HK extends Translations$settingsTab$general$brightnessOptions$en {
  Translations$settingsTab$general$brightnessOptions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟機';
  @override
  String get dark => '暗色';
  @override
  String get light => '亮色';
}

// Path: settingsTab.general.colorOptions
class Translations$settingsTab$general$colorOptions$zh_HK extends Translations$settingsTab$general$colorOptions$en {
  Translations$settingsTab$general$colorOptions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟機';
  @override
  String get oled => 'OLED';
  @override
  String get custom => '自訂';
}

// Path: settingsTab.general.languageOptions
class Translations$settingsTab$general$languageOptions$zh_HK extends Translations$settingsTab$general$languageOptions$en {
  Translations$settingsTab$general$languageOptions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟機';
}

// Path: settingsTab.network.networkOptions
class Translations$settingsTab$network$networkOptions$zh_HK extends Translations$settingsTab$network$networkOptions$en {
  Translations$settingsTab$network$networkOptions$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String get all => '全部';
  @override
  String get filtered => '已篩選';
}

// Path: progressPage.total.title
class Translations$progressPage$total$title$zh_HK extends Translations$progressPage$total$title$en {
  Translations$progressPage$total$title$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  String sending({required Object time}) => '進度：${time}';
  @override
  String get finishedError => '搞掂，不過有 error';
  @override
  String get canceledSender => '傳送者取消咗';
  @override
  String get canceledReceiver => '接收者取消咗';
}

// Path: whatsNewPage.changes.v1_0_0
class Translations$whatsNewPage$changes$v1_0_0$zh_HK extends Translations$whatsNewPage$changes$v1_0_0$en with WhatsNewStrings {
  Translations$whatsNewPage$changes$v1_0_0$zh_HK.internal(TranslationsZhHk root) : this._root = root, super.internal(root);

  final TranslationsZhHk _root; // ignore: unused_field

  // Translations
  @override
  List<String> get changes => [
    '工作區自動填寫名稱，支援自訂路徑和一鍵複製連結。',
    'macOS 記住工作區目錄授權，可在工作區頁重新啟動分享服務。',
    '開啟工作區上載後，已授權訪客直接上載、重試，不再反覆確認。',
    '手機相簿支援批量選擇，桌面可多選圖片和影片。',
    '檔案與資料夾排隊傳送，統一管理傳送和接收。',
    '瀏覽器內預覽、搜尋和下載分享內容。',
    '優化工作區表單，減少解釋性文案。',
  ];
}
