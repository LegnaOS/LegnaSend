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
class TranslationsZhCn extends Translations with BaseTranslations<AppLocale, Translations> {
  /// You can call this constructor and build your own translation instance of this locale.
  /// Constructing via the enum [AppLocale.build] is preferred.
  TranslationsZhCn({
    Map<String, Node>? overrides,
    PluralResolver? cardinalResolver,
    PluralResolver? ordinalResolver,
    TranslationMetadata<AppLocale, Translations>? meta,
  }) : assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
       $meta =
           meta ??
           TranslationMetadata(
             locale: AppLocale.zhCn,
             overrides: overrides ?? {},
             cardinalResolver: cardinalResolver,
             ordinalResolver: ordinalResolver,
           ),
       super(cardinalResolver: cardinalResolver, ordinalResolver: ordinalResolver);

  /// Metadata for the translations of <zh-CN>.
  @override
  final TranslationMetadata<AppLocale, Translations> $meta;

  late final TranslationsZhCn _root = this; // ignore: unused_field

  @override
  TranslationsZhCn $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => TranslationsZhCn(meta: meta ?? this.$meta);

  // Translations
  @override
  String get appName => 'LegnaSend';
  @override
  late final Translations$general$zh_CN general = Translations$general$zh_CN.internal(_root);
  @override
  late final Translations$receiveTab$zh_CN receiveTab = Translations$receiveTab$zh_CN.internal(_root);
  @override
  late final Translations$sendTab$zh_CN sendTab = Translations$sendTab$zh_CN.internal(_root);
  @override
  late final Translations$settingsTab$zh_CN settingsTab = Translations$settingsTab$zh_CN.internal(_root);
  @override
  late final Translations$troubleshootPage$zh_CN troubleshootPage = Translations$troubleshootPage$zh_CN.internal(_root);
  @override
  late final Translations$networkInterfacesPage$zh_CN networkInterfacesPage = Translations$networkInterfacesPage$zh_CN.internal(_root);
  @override
  late final Translations$receiveHistoryPage$zh_CN receiveHistoryPage = Translations$receiveHistoryPage$zh_CN.internal(_root);
  @override
  late final Translations$apkPickerPage$zh_CN apkPickerPage = Translations$apkPickerPage$zh_CN.internal(_root);
  @override
  late final Translations$selectedFilesPage$zh_CN selectedFilesPage = Translations$selectedFilesPage$zh_CN.internal(_root);
  @override
  late final Translations$deviceDetailsPage$zh_CN deviceDetailsPage = Translations$deviceDetailsPage$zh_CN.internal(_root);
  @override
  late final Translations$verifyPage$zh_CN verifyPage = Translations$verifyPage$zh_CN.internal(_root);
  @override
  late final Translations$receivePage$zh_CN receivePage = Translations$receivePage$zh_CN.internal(_root);
  @override
  late final Translations$receiveOptionsPage$zh_CN receiveOptionsPage = Translations$receiveOptionsPage$zh_CN.internal(_root);
  @override
  late final Translations$sendPage$zh_CN sendPage = Translations$sendPage$zh_CN.internal(_root);
  @override
  late final Translations$progressPage$zh_CN progressPage = Translations$progressPage$zh_CN.internal(_root);
  @override
  late final Translations$webSharePage$zh_CN webSharePage = Translations$webSharePage$zh_CN.internal(_root);
  @override
  late final Translations$webReceivePage$zh_CN webReceivePage = Translations$webReceivePage$zh_CN.internal(_root);
  @override
  late final Translations$aboutPage$zh_CN aboutPage = Translations$aboutPage$zh_CN.internal(_root);
  @override
  late final Translations$donationPage$zh_CN donationPage = Translations$donationPage$zh_CN.internal(_root);
  @override
  late final Translations$directoryWorkspaces$zh_CN directoryWorkspaces = Translations$directoryWorkspaces$zh_CN.internal(_root);
  @override
  late final Translations$changelogPage$zh_CN changelogPage = Translations$changelogPage$zh_CN.internal(_root);
  @override
  late final Translations$whatsNewPage$zh_CN whatsNewPage = Translations$whatsNewPage$zh_CN.internal(_root);
  @override
  late final Translations$aliasGenerator$zh_CN aliasGenerator = Translations$aliasGenerator$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$zh_CN dialogs = Translations$dialogs$zh_CN.internal(_root);
  @override
  late final Translations$sanitization$zh_CN sanitization = Translations$sanitization$zh_CN.internal(_root);
  @override
  late final Translations$tray$zh_CN tray = Translations$tray$zh_CN.internal(_root);
  @override
  late final Translations$web$zh_CN web = Translations$web$zh_CN.internal(_root);
  @override
  late final Translations$assetPicker$zh_CN assetPicker = Translations$assetPicker$zh_CN.internal(_root);
  @override
  late final Translations$networkLabels$zh_CN networkLabels = Translations$networkLabels$zh_CN.internal(_root);
  @override
  late final Translations$sendQueue$zh_CN sendQueue = Translations$sendQueue$zh_CN.internal(_root);
  @override
  late final Translations$transferActivity$zh_CN transferActivity = Translations$transferActivity$zh_CN.internal(_root);
  @override
  late final Translations$webPreview$zh_CN webPreview = Translations$webPreview$zh_CN.internal(_root);
  @override
  late final Translations$webTextPreview$zh_CN webTextPreview = Translations$webTextPreview$zh_CN.internal(_root);
  @override
  late final Translations$transportSecurity$zh_CN transportSecurity = Translations$transportSecurity$zh_CN.internal(_root);
  @override
  late final Translations$transferSpeed$zh_CN transferSpeed = Translations$transferSpeed$zh_CN.internal(_root);
  @override
  late final Translations$transferNavigation$zh_CN transferNavigation = Translations$transferNavigation$zh_CN.internal(_root);
  @override
  late final Translations$networkEnvironment$zh_CN networkEnvironment = Translations$networkEnvironment$zh_CN.internal(_root);
  @override
  late final Translations$linkWorkspace$zh_CN linkWorkspace = Translations$linkWorkspace$zh_CN.internal(_root);
  @override
  late final Translations$integrationApi$zh_CN integrationApi = Translations$integrationApi$zh_CN.internal(_root);
  @override
  late final Translations$apiExplorer$zh_CN apiExplorer = Translations$apiExplorer$zh_CN.internal(_root);
  @override
  late final Translations$sharedFileManagement$zh_CN sharedFileManagement = Translations$sharedFileManagement$zh_CN.internal(_root);
}

// Path: general
class Translations$general$zh_CN extends Translations$general$en {
  Translations$general$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get accept => '接受';
  @override
  String get accepted => '已接受';
  @override
  String get add => '添加';
  @override
  String get advanced => '高级';
  @override
  String get cancel => '取消';
  @override
  String get close => '关闭';
  @override
  String get confirm => '确认';
  @override
  String get continueStr => '继续';
  @override
  String get copy => '复制';
  @override
  String get copiedToClipboard => '已复制到剪贴板';
  @override
  String get decline => '拒绝';
  @override
  String get done => '完成';
  @override
  String get delete => '删除';
  @override
  String get edit => '编辑';
  @override
  String get error => '错误';
  @override
  String get example => '示例';
  @override
  String get files => '文件';
  @override
  String get finished => '已完成';
  @override
  String get hide => '隐藏';
  @override
  String get off => '关';
  @override
  String get offline => '离线';
  @override
  String get on => '开';
  @override
  String get online => '在线';
  @override
  String get open => '打开';
  @override
  String get queue => '队列';
  @override
  String get quickSave => '自动保存';
  @override
  String get quickSaveFromFavorites => '自动保存来自“收藏夹(白名单)”设备的文件';
  @override
  String get renamed => '重命名成功';
  @override
  String get reset => '重置';
  @override
  String get restart => '重启';
  @override
  String get settings => '设置';
  @override
  String get skipped => '已跳过';
  @override
  String get start => '开始';
  @override
  String get stop => '停止';
  @override
  String get save => '保存';
  @override
  String get unchanged => '未更改';
  @override
  String get unknown => '未知';
  @override
  String get noItemInClipboard => '剪贴板为空';
}

// Path: receiveTab
class Translations$receiveTab$zh_CN extends Translations$receiveTab$en {
  Translations$receiveTab$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '接收';
  @override
  late final Translations$receiveTab$infoBox$zh_CN infoBox = Translations$receiveTab$infoBox$zh_CN.internal(_root);
  @override
  late final Translations$receiveTab$quickSave$zh_CN quickSave = Translations$receiveTab$quickSave$zh_CN.internal(_root);
  @override
  String get link => '链接工作区';
}

// Path: sendTab
class Translations$sendTab$zh_CN extends Translations$sendTab$en {
  Translations$sendTab$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '发送';
  @override
  late final Translations$sendTab$selection$zh_CN selection = Translations$sendTab$selection$zh_CN.internal(_root);
  @override
  late final Translations$sendTab$picker$zh_CN picker = Translations$sendTab$picker$zh_CN.internal(_root);
  @override
  String get shareIntentInfo => '你也可以通过移动设备中的“分享”功能更简单地发送文件。';
  @override
  String get nearbyDevices => '附近的设备';
  @override
  String get thisDevice => '这台设备';
  @override
  String get scan => '扫描设备';
  @override
  String get manualSending => '手动发送';
  @override
  String get sendMode => '发送模式';
  @override
  late final Translations$sendTab$sendModes$zh_CN sendModes = Translations$sendTab$sendModes$zh_CN.internal(_root);
  @override
  String get sendModeHelp => '提示';
  @override
  String get help => '请确保目标连接到同一个 Wi‑Fi 网络。';
  @override
  String get placeItems => '列出要分享的项目。';
}

// Path: settingsTab
class Translations$settingsTab$zh_CN extends Translations$settingsTab$en {
  Translations$settingsTab$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '设置';
  @override
  late final Translations$settingsTab$general$zh_CN general = Translations$settingsTab$general$zh_CN.internal(_root);
  @override
  late final Translations$settingsTab$receive$zh_CN receive = Translations$settingsTab$receive$zh_CN.internal(_root);
  @override
  late final Translations$settingsTab$send$zh_CN send = Translations$settingsTab$send$zh_CN.internal(_root);
  @override
  late final Translations$settingsTab$network$zh_CN network = Translations$settingsTab$network$zh_CN.internal(_root);
  @override
  late final Translations$settingsTab$other$zh_CN other = Translations$settingsTab$other$zh_CN.internal(_root);
  @override
  String get advancedSettings => '高级设置';
}

// Path: troubleshootPage
class Translations$troubleshootPage$zh_CN extends Translations$troubleshootPage$en {
  Translations$troubleshootPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '故障排除';
  @override
  String get subTitle => '应用没有按预期工作？您可以在这里找到常用解决方案。';
  @override
  String get solution => '解决方案：';
  @override
  String get fixButton => '自动修复';
  @override
  late final Translations$troubleshootPage$firewall$zh_CN firewall = Translations$troubleshootPage$firewall$zh_CN.internal(_root);
  @override
  late final Translations$troubleshootPage$noDiscovery$zh_CN noDiscovery = Translations$troubleshootPage$noDiscovery$zh_CN.internal(_root);
  @override
  late final Translations$troubleshootPage$noConnection$zh_CN noConnection = Translations$troubleshootPage$noConnection$zh_CN.internal(_root);
}

// Path: networkInterfacesPage
class Translations$networkInterfacesPage$zh_CN extends Translations$networkInterfacesPage$en {
  Translations$networkInterfacesPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '网络接口';
  @override
  String get info => '默认情况下，LocalSend 使用所有可用的网络接口。您可以在此处排除不需要的网络接口。您需要重新启动服务器以应用更改。';
  @override
  String get preview => '预览';
  @override
  String get whitelist => '白名单';
  @override
  String get blacklist => '黑名单';
}

// Path: receiveHistoryPage
class Translations$receiveHistoryPage$zh_CN extends Translations$receiveHistoryPage$en {
  Translations$receiveHistoryPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '历史';
  @override
  String get openFolder => '打开目录';
  @override
  String get deleteHistory => '删除历史记录';
  @override
  String get empty => '无历史记录。';
  @override
  late final Translations$receiveHistoryPage$entryActions$zh_CN entryActions = Translations$receiveHistoryPage$entryActions$zh_CN.internal(_root);
}

// Path: apkPickerPage
class Translations$apkPickerPage$zh_CN extends Translations$apkPickerPage$en {
  Translations$apkPickerPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '应用（APK）';
  @override
  String get excludeSystemApps => '排除系统应用';
  @override
  String get excludeAppsWithoutLaunchIntent => '排除无法启动的应用';
  @override
  String apps({required Object n}) => '${n} 个应用';
}

// Path: selectedFilesPage
class Translations$selectedFilesPage$zh_CN extends Translations$selectedFilesPage$en {
  Translations$selectedFilesPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get deleteAll => '全部删除';
}

// Path: deviceDetailsPage
class Translations$deviceDetailsPage$zh_CN extends Translations$deviceDetailsPage$en {
  Translations$deviceDetailsPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '设备详情';
  @override
  String get favorite => '收藏';
  @override
  String get verify => '验证';
  @override
  late final Translations$deviceDetailsPage$info$zh_CN info = Translations$deviceDetailsPage$info$zh_CN.internal(_root);
  @override
  late final Translations$deviceDetailsPage$logs$zh_CN logs = Translations$deviceDetailsPage$logs$zh_CN.internal(_root);
}

// Path: verifyPage
class Translations$verifyPage$zh_CN extends Translations$verifyPage$en {
  Translations$verifyPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '验证';
  @override
  String get icons => '图标';
  @override
  String get text => '文本';
  @override
  String get question => '在另一台设备上显示的内容相同吗？';
}

// Path: receivePage
class Translations$receivePage$zh_CN extends Translations$receivePage$en {
  Translations$receivePage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get verifyingReceivedData => '正在校验接收数据';
  @override
  String get idleExpired => '接收会话已闲置10分钟且没有正在上传的文件，因此已过期。请让发送端重新发起传输；已完成的文件会保留。';
  @override
  String subTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    n,
    one: '想要发送给你一个文件',
    other: '想要发送给你 ${n} 个文件',
  );
  @override
  String get subTitleMessage => '发送给你了一条消息：';
  @override
  String get subTitleLink => '发送给你了一个链接：';
  @override
  String get canceled => '发送者取消了请求。';
  @override
  String get destinationUnavailable => '下载目录暂不可用，请检查存储权限、可用空间和保存位置后重试。';
}

// Path: receiveOptionsPage
class Translations$receiveOptionsPage$zh_CN extends Translations$receiveOptionsPage$en {
  Translations$receiveOptionsPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '设置';
  @override
  String get destination => _root.settingsTab.receive.destination;
  @override
  String get appDirectory => '(LocalSend 文件夹)';
  @override
  String get saveToGallery => _root.settingsTab.receive.saveToGallery;
  @override
  String get saveToGalleryOff => '由于分享内容中存在文件夹，已自动关闭。';
}

// Path: sendPage
class Translations$sendPage$zh_CN extends Translations$sendPage$en {
  Translations$sendPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get verifyingSourceData => '正在校验源文件';
  @override
  String calculatingChecksum({required Object curr, required Object n}) => '正在计算校验和（${curr} / ${n}）';
  @override
  String get waiting => '等待响应中……';
  @override
  String get rejected => '对方拒绝了请求。';
  @override
  String get tooManyAttempts => _root.web.tooManyAttempts;
  @override
  String get busy => '对方正在处理另一个请求。';
}

// Path: progressPage
class Translations$progressPage$zh_CN extends Translations$progressPage$en {
  Translations$progressPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get titleSending => '正在发送文件';
  @override
  String get titleReceiving => '正在接收文件';
  @override
  String get savedToGallery => '已保存到相册';
  @override
  late final Translations$progressPage$total$zh_CN total = Translations$progressPage$total$zh_CN.internal(_root);
  @override
  late final Translations$progressPage$remainingTime$zh_CN remainingTime = Translations$progressPage$remainingTime$zh_CN.internal(_root);
}

// Path: webSharePage
class Translations$webSharePage$zh_CN extends Translations$webSharePage$en {
  Translations$webSharePage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '分享为链接';
  @override
  String get loading => '正在启动服务器……';
  @override
  String get stopping => '正在停止服务器……';
  @override
  String get error => '在启动服务器过程中发生了错误。';
  @override
  String openLink({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    n,
    one: '在浏览器中打开链接：',
    other: '在浏览器中打开其中一个链接：',
  );
  @override
  String get requests => '请求';
  @override
  String get noRequests => '尚无请求。';
  @override
  String get encryption => _root.settingsTab.network.encryption;
  @override
  String get autoAccept => '自动接受请求';
  @override
  String get requirePin => '启用 PIN 密码';
  @override
  String pinHint({required Object pin}) => 'PIN 为 “${pin}”';
  @override
  String get encryptionHint => 'LocalSend 使用自签名证书。您需要在浏览器中允许它。';
  @override
  String pendingRequests({required Object n}) => '待处理请求：${n}';
}

// Path: webReceivePage
class Translations$webReceivePage$zh_CN extends Translations$webReceivePage$en {
  Translations$webReceivePage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '通过链接接收';
}

// Path: aboutPage
class Translations$aboutPage$zh_CN extends Translations$aboutPage$en {
  Translations$aboutPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '关于 LegnaSend';
  @override
  List<String> get description => [
    'LegnaSend 是开源文件共享工具，提供多网卡链接、设备网络标签和连续发送队列。',
  ];
  @override
  String get author => '作者';
  @override
  String get contributors => '贡献者';
  @override
  String get packagers => '打包者';
  @override
  String get translators => '翻译者';
  @override
  String get upstreamCredits => '开源致谢';
  @override
  String version({required Object version}) => '版本 ${version}';
  @override
  String get licenseNotices => '许可证声明';
  @override
  String get debugging => '诊断';
}

// Path: donationPage
class Translations$donationPage$zh_CN extends Translations$donationPage$en {
  Translations$donationPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '捐赠';
  @override
  String get info => 'LocalSend 免费、开源、无广告。如果您喜欢这款应用程序，可以捐款支持开发。';
  @override
  String donate({required Object amount}) => '捐款 ${amount}';
  @override
  String get thanks => '非常感谢您的支持！';
  @override
  String get restore => '恢复购买';
}

// Path: directoryWorkspaces
class Translations$directoryWorkspaces$zh_CN extends Translations$directoryWorkspaces$en {
  Translations$directoryWorkspaces$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '工作区';
  @override
  String get create => '创建工作区';
  @override
  String get name => '名称';
  @override
  String get slug => '自定义路径';
  @override
  String get root => '本地目录';
  @override
  String get choose => '选择目录';
  @override
  String get visible => '索引可见';
  @override
  String get hidden => '索引隐藏';
  @override
  String get hide => '隐藏';
  @override
  String get show => '显示';
  @override
  String get closed => '已关闭';
  @override
  String get serving => '正在共享';
  @override
  String get previousServing => '旧配置仍在共享';
  @override
  String get invalid => '来源失效';
  @override
  String get syncing => '正在应用配置';
  @override
  String get serverOff => '服务已停止';
  @override
  String get readOnly => '只读目录';
  @override
  String get readOnlyHint => '默认只读，可开启上传。';
  @override
  String get empty => '选择文件夹，创建工作区。';
  @override
  String get failed => '保存失败，请检查路径和文件夹权限。';
  @override
  String get syncFailed => '设置未生效，原共享设置保持不变。';
  @override
  String get retry => '重试';
  @override
  String get enable => '开启';
  @override
  String get close => '关闭';
  @override
  String get destroy => '销毁工作区';
  @override
  String get validate => '检查目录';
  @override
  String get stopHint => '停止共享此工作区？源文件会保留。';
  @override
  String get hiddenHint => '不在索引中展示，知道链接仍可访问。';
  @override
  String get closeToEdit => '修改访问路径或源目录前，请先关闭工作区。';
  @override
  String get invalidInput => '请填写名称、唯一的字母数字或连字符路径，并选择文件夹。';
  @override
  Map<String, String> get reasons => {
    'missing': '目录不存在',
    'notDirectory': '不是本地目录',
    'permissionDenied': '目录权限不足',
    'grantUnavailable': '目录授权不可用，请重新选择文件夹',
    'ioError': '目录读取失败',
    'timeout': '目录检查超时',
  };
  @override
  String get access => '访问保护';
  @override
  String get protected => '密码保护';
  @override
  String get openAccess => '开放访问';
  @override
  String get password => '新密码或 PIN';
  @override
  String get confirmPassword => '确认密码';
  @override
  String get keepPassword => '留空保留现有密码。';
  @override
  String get passwordInvalid => '请输入 4–128 个字符，两次输入应一致。';
  @override
  String get passwordHint => '修改访问保护会中断当前下载。';
  @override
  String get accessPending => '访问策略待服务确认';
  @override
  String get uploadPermission => '上传权限';
  @override
  String get allowUpload => '允许网页上传';
  @override
  String get uploadHint => '访客可直接上传，无需逐次确认。已有文件不会被覆盖。';
  @override
  String get uploadPending => '上传权限待同步';
  @override
  String get permissionHint => '上传权限';
  @override
  String get startService => '启动服务';
}

// Path: changelogPage
class Translations$changelogPage$zh_CN extends Translations$changelogPage$en {
  Translations$changelogPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '更新日志';
  @override
  String get language => '更新记录语言';
  @override
  String get followApp => '跟随应用语言';
  @override
  String fallback({required Object language}) => '当前语言的译文尚未提供，现显示 ${language}。';
  @override
  String get loadError => '更新记录加载失败。';
  @override
  String get retry => '重试';
}

// Path: whatsNewPage
class Translations$whatsNewPage$zh_CN extends Translations$whatsNewPage$en {
  Translations$whatsNewPage$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String title({required Object version}) => '${version} 中的新增功能';
  @override
  late final Translations$whatsNewPage$changes$zh_CN changes = Translations$whatsNewPage$changes$zh_CN.internal(_root);
}

// Path: aliasGenerator
class Translations$aliasGenerator$zh_CN extends Translations$aliasGenerator$en {
  Translations$aliasGenerator$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  List<String> get adjectives => [
    '迷人',
    '美丽',
    '巨大',
    '明亮',
    '干净',
    '聪明',
    '帅气',
    '可爱',
    '狡猾',
    '坚定',
    '有活力',
    '高效',
    '极好',
    '快速',
    '不错',
    '新鲜',
    '好',
    '华丽',
    '伟大',
    '英俊',
    '炽热',
    '善良',
    '诚实',
    '神秘',
    '整洁',
    '开心',
    '耐心',
    '漂亮',
    '强大',
    '富有',
    '秘密',
    '聪明',
    '稳固',
    '特别',
    '战略性',
    '强大',
    '整洁',
    '智慧',
  ];
  @override
  List<String> get fruits => [
    '苹果',
    '鳄梨',
    '香蕉',
    '黑莓',
    '蓝莓',
    '西兰花',
    '胡萝卜',
    '樱桃',
    '椰子',
    '葡萄',
    '柠檬',
    '莴苣',
    '芒果',
    '甜瓜',
    '蘑菇',
    '洋葱',
    '橙子',
    '木瓜',
    '桃子',
    '梨',
    '菠萝',
    '土豆',
    '南瓜',
    '覆盆子',
    '草莓',
    '番茄',
  ];
  @override
  String combination({required Object adjective, required Object fruit}) => '${adjective}的${fruit}';
}

// Path: dialogs
class Translations$dialogs$zh_CN extends Translations$dialogs$en {
  Translations$dialogs$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$dialogs$addFile$zh_CN addFile = Translations$dialogs$addFile$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$openFile$zh_CN openFile = Translations$dialogs$openFile$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$addressInput$zh_CN addressInput = Translations$dialogs$addressInput$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$cancelSession$zh_CN cancelSession = Translations$dialogs$cancelSession$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$cannotOpenFile$zh_CN cannotOpenFile = Translations$dialogs$cannotOpenFile$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$encryptionDisabledNotice$zh_CN encryptionDisabledNotice =
      Translations$dialogs$encryptionDisabledNotice$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$errorDialog$zh_CN errorDialog = Translations$dialogs$errorDialog$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$favoriteDialog$zh_CN favoriteDialog = Translations$dialogs$favoriteDialog$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$favoriteDeleteDialog$zh_CN favoriteDeleteDialog = Translations$dialogs$favoriteDeleteDialog$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$favoriteEditDialog$zh_CN favoriteEditDialog = Translations$dialogs$favoriteEditDialog$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$fileInfo$zh_CN fileInfo = Translations$dialogs$fileInfo$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$fileNameInput$zh_CN fileNameInput = Translations$dialogs$fileNameInput$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$historyClearDialog$zh_CN historyClearDialog = Translations$dialogs$historyClearDialog$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$localNetworkUnauthorized$zh_CN localNetworkUnauthorized =
      Translations$dialogs$localNetworkUnauthorized$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$messageInput$zh_CN messageInput = Translations$dialogs$messageInput$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$noFiles$zh_CN noFiles = Translations$dialogs$noFiles$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$noPermission$zh_CN noPermission = Translations$dialogs$noPermission$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$notAvailableOnPlatform$zh_CN notAvailableOnPlatform = Translations$dialogs$notAvailableOnPlatform$zh_CN.internal(
    _root,
  );
  @override
  late final Translations$dialogs$qr$zh_CN qr = Translations$dialogs$qr$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$quickActions$zh_CN quickActions = Translations$dialogs$quickActions$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$quickSaveNotice$zh_CN quickSaveNotice = Translations$dialogs$quickSaveNotice$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$quickSaveFromFavoritesNotice$zh_CN quickSaveFromFavoritesNotice =
      Translations$dialogs$quickSaveFromFavoritesNotice$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$pin$zh_CN pin = Translations$dialogs$pin$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$sendModeHelp$zh_CN sendModeHelp = Translations$dialogs$sendModeHelp$zh_CN.internal(_root);
  @override
  late final Translations$dialogs$zoom$zh_CN zoom = Translations$dialogs$zoom$zh_CN.internal(_root);
}

// Path: sanitization
class Translations$sanitization$zh_CN extends Translations$sanitization$en {
  Translations$sanitization$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get empty => '文件名不能为空';
  @override
  String get invalid => '文件名包含无效字符';
}

// Path: tray
class Translations$tray$zh_CN extends Translations$tray$en {
  Translations$tray$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get open => _root.general.open;
  @override
  String get close => '退出 LocalSend';
  @override
  String get closeWindows => '退出';
}

// Path: web
class Translations$web$zh_CN extends Translations$web$en {
  Translations$web$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get waiting => _root.sendPage.waiting;
  @override
  String get enterPin => '输入 PIN';
  @override
  String get invalidPin => 'PIN 无效';
  @override
  String get tooManyAttempts => '尝试次数过多';
  @override
  String get rejected => '已拒绝';
  @override
  String get files => '文件';
  @override
  String get fileName => '文件名';
  @override
  String get size => '大小';
}

// Path: assetPicker
class Translations$assetPicker$zh_CN extends Translations$assetPicker$en {
  Translations$assetPicker$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get confirm => '确认';
  @override
  String get cancel => '取消';
  @override
  String get edit => '编辑';
  @override
  String get gifIndicator => 'GIF';
  @override
  String get loadFailed => '加载失败';
  @override
  String get original => '原文件';
  @override
  String get preview => '预览';
  @override
  String get select => '选择';
  @override
  String get emptyList => '清空列表';
  @override
  String get unSupportedAssetType => '不支持该文件格式';
  @override
  String get unableToAccessAll => '无法访问设备上的所有文件';
  @override
  String get viewingLimitedAssetsTip => '应用程序仅能查看您允许的文件和相册。';
  @override
  String get changeAccessibleLimitedAssets => '点击以更改可访问文件范围';
  @override
  String get accessAllTip => '应用程序只能访问设备上的部分文件，请转到系统设置并允许该应用访问设备上的所有媒体文件。';
  @override
  String get goToSystemSettings => '转到系统设置';
  @override
  String get accessLimitedAssets => '继续受限访问';
  @override
  String get accessiblePathName => '可访问的文件';
  @override
  String get sTypeAudioLabel => '音频';
  @override
  String get sTypeImageLabel => '图片';
  @override
  String get sTypeVideoLabel => '视频';
  @override
  String get sTypeOtherLabel => '其他媒体文件';
  @override
  String get sActionPlayHint => '播放';
  @override
  String get sActionPreviewHint => '预览';
  @override
  String get sActionSelectHint => '选择';
  @override
  String get sActionSwitchPathLabel => '更改路径';
  @override
  String get sActionUseCameraHint => '使用摄像头';
  @override
  String get sNameDurationLabel => '时长';
  @override
  String get sUnitAssetCountLabel => '计数';
}

// Path: networkLabels
class Translations$networkLabels$zh_CN extends Translations$networkLabels$en {
  Translations$networkLabels$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get refresh => '刷新网络';
  @override
  String get noAddress => '暂无可用 IPv4 地址，请连接网络后刷新。';
  @override
  String get unknownSubnet => '网段未知';
  @override
  String get networkMatch => '匹配的本地网络（实际路由由操作系统选择）';
  @override
  String get routedOrUnknown => '跨路由 / 网络未知';
  @override
  String get overlappingNetworks => '多个网卡匹配 · 路由未确认';
}

// Path: sendQueue
class Translations$sendQueue$zh_CN extends Translations$sendQueue$en {
  Translations$sendQueue$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get singleFileRetryNewTask => '将此文件作为新传输任务重试';
  @override
  String get singleFileRetryStarted => '已创建新的传输任务，已完成文件保持不变。';
  @override
  String get title => '发送队列';
  @override
  String get queued => '排队中';
  @override
  String get running => '发送中';
  @override
  String get succeeded => '已完成';
  @override
  String get failed => '发送失败';
  @override
  String get canceled => '已取消';
  @override
  String get retry => '重试未完成文件';
  @override
  String files({required Object n}) => '${n} 个文件';
  @override
  String drop({required Object device}) => '松开发送给 ${device}';
  @override
  String added({required Object device, required Object n}) => '已加入队列：${device}，${n} 个文件';
}

// Path: transferActivity
class Translations$transferActivity$zh_CN extends Translations$transferActivity$en {
  Translations$transferActivity$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '传输任务';
  @override
  String get send => '发送';
  @override
  String get receive => '接收';
  @override
  String get empty => '该方向暂无任务';
  @override
  String get preparing => '准备／校验中';
  @override
  String get waiting => '等待确认';
  @override
  String get transferring => '传输中';
  @override
  String get acknowledge => '收起已结束任务提示';
  @override
  String get details => '任务详情';
  @override
  String get back => '返回任务列表';
  @override
  String get ended => '该任务已结束或已移除。';
  @override
  String get files => '文件清单';
  @override
  String get accept => '接收所选文件';
  @override
  String get decline => '拒绝接收';
  @override
  String get failed => '失败';
  @override
  String get succeeded => '已完成';
  @override
  String get recoveryWaiting => '等待重试';
  @override
  String get recoveryRetryable => '可以重试';
  @override
  String get recoveryAuthorization => '需要重新授权';
  @override
  String get recoverySourceChanged => '来源已变化 · 请新建发送';
  @override
  String get recoveryInvalidResponse => '恢复响应未通过校验';
  @override
  String get recoveryRetained => '已保留部分数据';
  @override
  String get recoveryRetentionUnknown => '保留状态未确认';
  @override
  String get recoveryNotRetained => '无可复用检查点';
  @override
  String get retrying => '等待重连';
  @override
  String get sourceEnded => '源已失效';
}

// Path: webPreview
class Translations$webPreview$zh_CN extends Translations$webPreview$en {
  Translations$webPreview$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get preview => '预览';
  @override
  String get closePreview => '关闭预览';
  @override
  String get downloadOriginal => '下载原文件';
  @override
  String get previewLoading => '正在加载预览…';
  @override
  String get previewError => '预览失败，请下载原文件后打开。';
  @override
  String get previewUnsupported => '当前浏览器或文件格式不支持预览。';
  @override
  String get imageZoomIn => '放大';
  @override
  String get imageZoomOut => '缩小';
  @override
  String get imageFit => '适应窗口';
  @override
  String get imageActual => '实际尺寸';
  @override
  String get imageView => '图片预览';
  @override
  String get imageScale => '缩放比例';
  @override
  String get imageHint => '拖动平移，双指或 Ctrl/⌘ + 滚轮缩放。键盘：加减、方向键，0 适应窗口，1 实际尺寸。';
}

// Path: webTextPreview
class Translations$webTextPreview$zh_CN extends Translations$webTextPreview$en {
  Translations$webTextPreview$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get encoding => '编码';
  @override
  String get auto => '自动（BOM / UTF-8）';
  @override
  String get previous => '上一节';
  @override
  String get next => '下一节';
  @override
  String get more => '加载更多';
  @override
  String get retry => '重新加载预览';
  @override
  String get indexed => '已索引';
  @override
  String get lines => '行数';
  @override
  String get section => '节';
  @override
  String get complete => '文件末尾';
  @override
  String get loading => '正在加载文本…';
  @override
  String get view => '文本预览';
  @override
  String get range => '此数据源不支持按范围读取文本，请下载原文件。';
  @override
  String get changed => '共享文件已变化，请重新打开共享后预览。';
  @override
  String get decode => '文本编码不匹配，请选择其他编码或下载原文件。';
  @override
  String get failed => '文本加载失败，请检查连接后重新加载预览。';
  @override
  String get unsupported => '此浏览器不支持流式文本预览。';
  @override
  String get hint => '仅渲染可见行与少量缓冲行，自动换行让长文本自然适应页面宽度。';
  @override
  String get wrap => '自动换行';
  @override
  String get numbers => '显示行号';
  @override
  String get search => '搜索正文内容';
  @override
  String get searchScope => '搜索范围';
  @override
  String get loaded => '已索引内容';
  @override
  String get full => '整个文件';
  @override
  String get find => '查找';
  @override
  String get stop => '停止搜索';
  @override
  String get caseSensitive => '区分大小写';
  @override
  String get previousMatch => '上一个匹配';
  @override
  String get nextMatch => '下一个匹配';
  @override
  String get matches => '匹配';
  @override
  String get scanned => '已扫描';
  @override
  String get searching => '正在搜索…';
  @override
  String get searchDone => '搜索完成';
  @override
  String get searchStopped => '搜索已停止';
  @override
  String get noMatches => '已扫描内容中没有匹配';
  @override
  String get searchLimit => '已显示前 1,000 个匹配，请缩小关键词范围继续查找。';
  @override
  String get clearSearch => '清空搜索';
  @override
  String get rendered => '阅读视图';
  @override
  String get source => '源文本';
  @override
  String get markdownHint => 'Markdown 搜索覆盖源文本正文，结果定位到准确的源文本位置。';
  @override
  String get markdownLimit => '按小节懒加载完整语法块；引用链接随定义被索引而更新。';
  @override
  String get markdownFailed => '此文档暂未完成排版，可继续使用源文本阅读器。';
  @override
  String get diagramQueued => '图表 · 接近视口时加载';
  @override
  String get diagramLoading => '正在绘制图表…';
  @override
  String get diagramReady => '图表';
  @override
  String get diagramFailed => '此图表暂未绘制成功，可查看源代码或重试。';
  @override
  String get diagramLimit => '此图表超出预览限制，仍可查看源代码。';
  @override
  String get diagramSource => '源代码';
  @override
  String get diagramRender => '图表';
  @override
  String get diagramRetry => '重试';
  @override
  String get diagramFit => '适应';
  @override
  String get diagramZoomIn => '放大';
  @override
  String get diagramZoomOut => '缩小';
  @override
  String get diagramExpand => '全部展开';
  @override
  String get diagramCollapse => '折叠分支';
  @override
  String get diagramHint => '拖动平移；使用按钮或 Ctrl/⌘ + 滚轮缩放。';
  @override
  String get diagramUnavailable => '当前浏览器未启用图表渲染，已保留源代码。';
  @override
  String get markdownStreaming => '按小节懒加载完整语法块；引用链接随定义被索引而更新。';
  @override
  String get markdownParagraphSource => '超大段落 · 以阅读窗口展示完整源文本，跨窗口行内语法保持原文。';
  @override
  String get markdownBlockLimit => '当前语法块超出阅读预算，请切换源文本继续查看完整内容。';
  @override
  String get markdownScan => '索引引用定义';
  @override
  String get markdownStop => '停止索引';
  @override
  String get markdownSourceWindow => '超大语法块 · 以阅读窗口展示完整源文本，跨窗口的格式保持原文。';
}

// Path: transportSecurity
class Translations$transportSecurity$zh_CN extends Translations$transportSecurity$en {
  Translations$transportSecurity$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'HTTPS 传输（TLS）';
  @override
  String get description => '保护设备间传输链路上的数据，不对保存的文件加密，也不会给文件设置密码。';
  @override
  String get certificate => 'LegnaSend 使用本机生成的自签名 TLS 证书，浏览器可能显示此设备的证书信任提示。';
  @override
  String get httpTitle => '正在使用 HTTP 传输';
  @override
  String get httpDescription => 'HTTPS 传输已关闭，当前使用 HTTP，传输链路不受 TLS 保护。开启“HTTPS 传输（TLS）”可保护连接，不会改变保存的文件。';
  @override
  String get discoveryHint => '请检查网络是否可达、发现端口与多播设置以及 HTTP/HTTPS 配置。发现失败时可尝试目标设备的 IP 和实际服务端口。';
  @override
  String get connectionHint => '请检查目标 IP 和实际服务端口是否可达，以及 HTTP/HTTPS 配置是否兼容。Wi-Fi 接入点隔离或防火墙可能阻止设备间通信。';
  @override
  String get updateFailed => '传输协议切换失败，请检查实际服务状态后重试。';
  @override
  String peerProtocol({required Object protocol}) => '对端 · ${protocol}';
}

// Path: transferSpeed
class Translations$transferSpeed$zh_CN extends Translations$transferSpeed$en {
  Translations$transferSpeed$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String current({required Object speed}) => '当前速度：${speed}';
  @override
  String average({required Object speed}) => '平均速度：${speed}';
  @override
  String get measuring => '正在测速…';
}

// Path: transferNavigation
class Translations$transferNavigation$zh_CN extends Translations$transferNavigation$en {
  Translations$transferNavigation$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get hide => '收起面板';
  @override
  String get keepRunning => '返回和收起不会停止传输。';
  @override
  String get sharing => '链接共享中';
  @override
  String get keepSharing => '返回只隐藏页面，共享继续运行；可从共享悬标重新打开。';
  @override
  String get stopSharing => '停止链接共享';
  @override
  String get stopTitle => '停止链接共享？';
  @override
  String get stopBody => '仅结束临时链接的下载会话并停止新的网页上传；目录工作区、监听服务、API 和已批准的原生传输继续运行。';
  @override
  String get restartTitle => '重新启动共享服务？';
  @override
  String get restartBody => '切换 HTTP／HTTPS 会重启共用监听器，中断其活动连接；工作区定义和临时文件选择会保留。';
  @override
  String get unknown => '当前没有共享';
  @override
  String get replaceTitle => '更新临时共享访问？';
  @override
  String get replaceBody => '仅结束本临时共享的下载会话，目录工作区和原生传输继续运行。';
}

// Path: networkEnvironment
class Translations$networkEnvironment$zh_CN extends Translations$networkEnvironment$en {
  Translations$networkEnvironment$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get vpn => '系统 VPN';
  @override
  String get tunnel => 'VPN／隧道接口';
  @override
  String get local => '本地接口';
  @override
  String get proxy => '系统代理';
  @override
  String get title => '网络路径';
  @override
  String get unknown => '状态未知';
  @override
  String get detected => '已检测到';
  @override
  String get notDetected => '未检测到';
  @override
  String get routeHint => '选择对方设备可访问的本地或 VPN 地址。';
}

// Path: linkWorkspace
class Translations$linkWorkspace$zh_CN extends Translations$linkWorkspace$en {
  Translations$linkWorkspace$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '链接工作区';
  @override
  String sharedCount({required Object n}) => '已分享文件：${n}';
  @override
  String get allowUpload => '允许网页上传';
  @override
  String get allowUploadHint => '仅控制新的网页请求，已批准的传输继续；新请求仍遵循客户端的接收确认设置。';
  @override
  String get autoReceive => '自动接收网页上传';
  @override
  String get autoDownload => '自动批准网页下载';
  @override
  String get appendHint => '追加文件保留在当前工作区，已有文件链接和已批准会话继续有效。';
}

// Path: integrationApi
class Translations$integrationApi$zh_CN extends Translations$integrationApi$en {
  Translations$integrationApi$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'API';
  @override
  String get subtitle => '本地程序集成，沿用当前共享端口。';
  @override
  String get enable => '启用 API';
  @override
  String get requireKey => '要求 API 密钥';
  @override
  String get isolation => 'API 开关不会停止原生传送或网页工作区。';
  @override
  String get live => '已生效';
  @override
  String get off => '已禁用';
  @override
  String get waiting => '已保存 · 等待服务';
  @override
  String get syncing => '正在应用策略…';
  @override
  String get previous => '旧策略可能仍在生效';
  @override
  String get failed => '保存或应用失败，请在下方重试。';
  @override
  String get corrupt => 'API 配置需要恢复。原数据已保留，可重试读取或明确重置。';
  @override
  String get reset => '重置 API 配置';
  @override
  String get resetHint => '删除全部 API 密钥并恢复默认禁用状态，保留原生传送和工作区文件。';
  @override
  String get refresh => '刷新状态';
  @override
  String get startService => '启动接收服务';
  @override
  String get addresses => '服务地址';
  @override
  String get addressHint => '使用实际地址；HTTPS 需信任设备证书。网络标签描述接口，不代表已验证绕过 VPN。';
  @override
  String get policy => '访问与限额';
  @override
  String get editPolicy => '编辑策略';
  @override
  String get fixedWindow => '秒与分钟固定窗口同时约束；并发是活动响应数，不是连接数或下载带宽。0 仅取消该项限额，服务器资源上限仍生效。';
  @override
  String get global => '全局';
  @override
  String get perKey => '每个密钥';
  @override
  String get anonymous => '匿名来源';
  @override
  String get second => '请求／秒';
  @override
  String get minute => '请求／分钟';
  @override
  String get concurrent => '活动响应';
  @override
  String get origins => '允许的跨域来源';
  @override
  String get originsHint => '每行一个规范 http(s) 来源，不含路径；同源调用仍允许。';
  @override
  String get anonymousHint => '不带密钥时仅可读取匿名范围内可见、未保护的工作区。隐藏／密码工作区和请求历史不开放，错误密钥不会降级匿名。';
  @override
  String get allowAnonymous => '允许匿名访问？';
  @override
  String get disableHint => '只停止集成 API 响应；其他共享及原 LocalSend 传送继续。';
  @override
  String get keys => 'API 密钥';
  @override
  String get createKey => '生成密钥';
  @override
  String get keyName => '密钥名称';
  @override
  String get empty => '还没有 API 密钥。';
  @override
  String get once => '现在保存此密钥';
  @override
  String get onceHint => '明文仅在此展示，不保存；可重复调用，直到撤销或到期。关闭不会自动复制。';
  @override
  String get revoke => '撤销密钥';
  @override
  String get revokeHint => '撤销此密钥并结束其活动 API 响应；其他密钥和原生传送继续。';
  @override
  String get pendingKey => '已保存 · 尚未确认生效';
  @override
  String get removedLive => '已移除的密钥可能仍生效，需重试应用待处理策略。';
  @override
  String get permissions => '动作权限';
  @override
  String get scopeService => '服务状态与契约';
  @override
  String get scopeWorkspaces => '工作区描述';
  @override
  String get scopeFiles => '文件清单与下载';
  @override
  String get scopeRequests => '全局脱敏请求历史';
  @override
  String get allWorkspaces => '全部现有及未来工作区';
  @override
  String get selectWorkspaces => '工作区范围';
  @override
  String get grantHint => '仅授予所需动作和工作区。上传及工作区管理是独立的明确授权；已有和默认密钥保持只读。';
  @override
  String get expiry => '到期时间';
  @override
  String get days30 => '30 天';
  @override
  String get days90 => '90 天';
  @override
  String get never => '不过期';
  @override
  String get expired => '已到期';
  @override
  String get invalid => '请检查名称、限额、来源和所选权限／工作区。';
  @override
  String get copy => '复制';
  @override
  String get copied => '已复制';
  @override
  String get close => '完成';
  @override
  String get more => '下一页密钥';
  @override
  String get previousPage => '上一页密钥';
  @override
  String get readOnly => '读取与明确授权写入';
  @override
  String get nextStage => '明确授权的密钥可上传、管理本机批准来源的工作区，以及发现设备和控制自身 API 创建的发送任务；通用缓存／设置接口及无关原生任务控制仍待开发。';
  @override
  String get copyFailed => '复制失败，可选中文本手动复制。';
  @override
  String get updated => '更新于';
  @override
  String get unconfirmed => '等待服务确认';
  @override
  String get fallback => 'API text is shown in English.';
  @override
  String get documentation => '开发文档';
  @override
  String get directoryContract => '目录接口契约';
  @override
  String get documentationHint => '离线查阅：配置、权限、各接口、参数、错误、重试，以及 cURL／JavaScript／Python 示例。';
  @override
  String get scopeUpload => '上传文件（明确写权限）';
  @override
  String get scopeManage => '管理工作区信息与共享状态';
}

// Path: apiExplorer
class Translations$apiExplorer$zh_CN extends Translations$apiExplorer$en {
  Translations$apiExplorer$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'API 接口浏览与测试';
  @override
  String get search => '搜索接口或说明';
  @override
  String get execute => '执行请求';
  @override
  String get hint => '请求使用实际本机监听及其鉴权／配额：读取最多 12 秒，工作区管理 35 秒，上传按文件大小设置预算。请求和凭据不保存。';
  @override
  String get all => '全部';
  @override
  String get service => '服务';
  @override
  String get workspaces => '工作区';
  @override
  String get files => '文件';
  @override
  String get history => '请求记录';
  @override
  String get noResults => '没有匹配接口';
  @override
  String get readOnly => '只读测试';
  @override
  String get token => 'API 密钥（可留空）';
  @override
  String get tokenHint => '粘贴已生成密钥，或留空测试匿名访问。仅在此页面打开时保留，不写入调用示例。';
  @override
  String get clear => '清除凭据';
  @override
  String get running => '请求中…';
  @override
  String get reset => '重置参数';
  @override
  String get invalid => '请检查必填字段和参数范围。';
  @override
  String get failed => '请求失败或服务已变化，请对当前监听器重试。';
  @override
  String get headers => '响应头';
  @override
  String get response => '响应内容';
  @override
  String get truncated => '响应最多显示 256 KiB，二进制样本最多 4 KiB；这不是完整下载。';
  @override
  String get binary => '十六进制文件样本，不会保存文件；默认 Range 为 bytes=0-4095。';
  @override
  String get examples => '调用示例';
  @override
  String get responses => '响应契约';
  @override
  String get schemas => '数据模型';
}

// Path: sharedFileManagement
class Translations$sharedFileManagement$zh_CN extends Translations$sharedFileManagement$en {
  Translations$sharedFileManagement$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '共享文件';
  @override
  String get hint => '撤下或替换文件，不关闭共享；其他文件和接收任务继续。';
  @override
  String get search => '搜索共享文件';
  @override
  String get withdraw => '撤下文件';
  @override
  String get replace => '替换文件';
  @override
  String get confirmBody => '仅停止此文件的待处理和活动下载。替换文件会生成新链接，旧下载不会续传到新内容；不会删除源文件。';
  @override
  String get selectOne => '请选择一个替换文件。';
  @override
  String get changed => '共享或文件已变化，请重新打开文件管理后再试。';
  @override
  String get applied => '共享文件已更新。';
  @override
  String get failed => '更新未确认，保留原清单；请重试或重新打开共享。';
  @override
  String get empty => '没有匹配的共享文件。';
  @override
  String get previous => '上一页';
  @override
  String get next => '下一页';
}

// Path: receiveTab.infoBox
class Translations$receiveTab$infoBox$zh_CN extends Translations$receiveTab$infoBox$en {
  Translations$receiveTab$infoBox$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get ip => 'IP：';
  @override
  String get port => '端口：';
  @override
  String get alias => '设备名称：';
}

// Path: receiveTab.quickSave
class Translations$receiveTab$quickSave$zh_CN extends Translations$receiveTab$quickSave$en {
  Translations$receiveTab$quickSave$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get off => _root.general.off;
  @override
  String get favorites => '收藏夹';
  @override
  String get on => _root.general.on;
}

// Path: sendTab.selection
class Translations$sendTab$selection$zh_CN extends Translations$sendTab$selection$en {
  Translations$sendTab$selection$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '选择';
  @override
  String files({required Object files}) => '文件：${files}';
  @override
  String size({required Object size}) => '大小：${size}';
}

// Path: sendTab.picker
class Translations$sendTab$picker$zh_CN extends Translations$sendTab$picker$en {
  Translations$sendTab$picker$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get file => '文件';
  @override
  String get folder => '文件夹';
  @override
  String get media => '媒体';
  @override
  String get text => '文本';
  @override
  String get app => '应用';
  @override
  String get clipboard => '剪贴板';
}

// Path: sendTab.sendModes
class Translations$sendTab$sendModes$zh_CN extends Translations$sendTab$sendModes$en {
  Translations$sendTab$sendModes$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get single => '一个接收者';
  @override
  String get multiple => '多个接收者';
  @override
  String get link => '通过链接分享';
}

// Path: settingsTab.general
class Translations$settingsTab$general$zh_CN extends Translations$settingsTab$general$en {
  Translations$settingsTab$general$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '通用';
  @override
  String get brightness => '主题';
  @override
  late final Translations$settingsTab$general$brightnessOptions$zh_CN brightnessOptions =
      Translations$settingsTab$general$brightnessOptions$zh_CN.internal(_root);
  @override
  String get color => '颜色';
  @override
  late final Translations$settingsTab$general$colorOptions$zh_CN colorOptions = Translations$settingsTab$general$colorOptions$zh_CN.internal(_root);
  @override
  String get language => '语言';
  @override
  late final Translations$settingsTab$general$languageOptions$zh_CN languageOptions = Translations$settingsTab$general$languageOptions$zh_CN.internal(
    _root,
  );
  @override
  String get saveWindowPlacement => '退出时保存窗口位置';
  @override
  String get saveWindowPlacementWindows => '退出时保存窗口位置';
  @override
  String get minimizeToTray => '关闭时最小化到系统托盘';
  @override
  String get launchAtStartup => '登录系统后自动启动程序';
  @override
  String get launchMinimized => '启动时最小化到任务栏';
  @override
  String get showInContextMenu => '在“发送到...”文件菜单中显示 LocalSend';
  @override
  String get animations => '动画效果';
}

// Path: settingsTab.receive
class Translations$settingsTab$receive$zh_CN extends Translations$settingsTab$receive$en {
  Translations$settingsTab$receive$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

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
  String get autoFinish => '自动完成传输任务';
  @override
  String get destination => '保存目录';
  @override
  String get downloads => '(下载)';
  @override
  String get saveToGallery => '保存到相册';
  @override
  String get saveToHistory => '保存到历史记录';
  @override
  String get verifyChecksums => '接收文件时验证校验和';
}

// Path: settingsTab.send
class Translations$settingsTab$send$zh_CN extends Translations$settingsTab$send$en {
  Translations$settingsTab$send$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '发送';
  @override
  String get shareViaLinkAutoAccept => '通过链接分享：自动同意接收请求';
  @override
  String get createChecksums => '发送文件时创建校验和';
}

// Path: settingsTab.network
class Translations$settingsTab$network$zh_CN extends Translations$settingsTab$network$en {
  Translations$settingsTab$network$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '网络';
  @override
  String get needRestart => '重启服务器后生效！';
  @override
  String get server => '服务器';
  @override
  String get alias => '设备名称';
  @override
  String get deviceType => '设备类型';
  @override
  String get deviceModel => '设备型号';
  @override
  String get port => '端口';
  @override
  String get network => '网络';
  @override
  late final Translations$settingsTab$network$networkOptions$zh_CN networkOptions = Translations$settingsTab$network$networkOptions$zh_CN.internal(
    _root,
  );
  @override
  String get discoveryTimeout => '搜索设备超时';
  @override
  String get useSystemName => '使用系统名称';
  @override
  String get generateRandomAlias => '生成随机昵称';
  @override
  String portWarning({required Object defaultPort}) => '由于正在使用自定义端口，你可能不会被其他设备检测到。（默认端口：${defaultPort}）';
  @override
  String get encryption => '加密';
  @override
  String get multicastGroup => '多播';
  @override
  String multicastGroupWarning({required Object defaultMulticast}) => '由于正在使用自定义多播地址，你可能不会被其他设备检测到。（默认地址：${defaultMulticast}）';
}

// Path: settingsTab.other
class Translations$settingsTab$other$zh_CN extends Translations$settingsTab$other$en {
  Translations$settingsTab$other$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '其他';
  @override
  String get support => '支持 LocalSend';
  @override
  String get donate => '捐赠';
  @override
  String get privacyPolicy => '隐私政策';
  @override
  String get termsOfUse => '使用条款';
}

// Path: troubleshootPage.firewall
class Translations$troubleshootPage$firewall$zh_CN extends Translations$troubleshootPage$firewall$en {
  Translations$troubleshootPage$firewall$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '此设备可以发送文件至其他设备，但其它设备无法发送文件到此设备。';
  @override
  String solution({required Object port}) => '这最可能是由防火墙规则设定引起的。你可以通过在端口 ${port} 上允许（UDP 和 TCP 的）传入请求来解决这个问题。';
  @override
  String get openFirewall => '打开防火墙';
}

// Path: troubleshootPage.noDiscovery
class Translations$troubleshootPage$noDiscovery$zh_CN extends Translations$troubleshootPage$noDiscovery$en {
  Translations$troubleshootPage$noDiscovery$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '此设备未能发现其他设备。';
  @override
  String get solution => '确保所有设备都处于同一个 Wi‑Fi 网络上，且共享相同的网络配置（端口、多播地址、加密选项）。您可以尝试手动输入目标设备的 IP 地址。如果起到了效果，请考虑将此设备添加到收藏夹中，以便将来可以自动发现。';
}

// Path: troubleshootPage.noConnection
class Translations$troubleshootPage$noConnection$zh_CN extends Translations$troubleshootPage$noConnection$en {
  Translations$troubleshootPage$noConnection$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get symptom => '双方设备均无法发现对方或者分享文件。';
  @override
  String get solution => '当问题发生在双方设备上时，请先确认双方设备处于同一个 Wi‑Fi 网络上，且共享相同的网络配置（端口、多播地址、加密选项）。若因 Wi‑Fi 不允许参与者间通信，那么请在路由器中关闭“接入点(AP)隔离”选项。';
}

// Path: receiveHistoryPage.entryActions
class Translations$receiveHistoryPage$entryActions$zh_CN extends Translations$receiveHistoryPage$entryActions$en {
  Translations$receiveHistoryPage$entryActions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get open => '打开文件';
  @override
  String get showInFolder => '在文件管理器中显示';
  @override
  String get info => '信息';
  @override
  String get deleteFromHistory => '从历史记录中删除';
}

// Path: deviceDetailsPage.info
class Translations$deviceDetailsPage$info$zh_CN extends Translations$deviceDetailsPage$info$en {
  Translations$deviceDetailsPage$info$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get name => '名称';
  @override
  String get address => '地址';
  @override
  String get version => '版本';
  @override
  String protocol({required Object version}) => '协议 v${version}';
}

// Path: deviceDetailsPage.logs
class Translations$deviceDetailsPage$logs$zh_CN extends Translations$deviceDetailsPage$logs$en {
  Translations$deviceDetailsPage$logs$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '日志';
  @override
  String get empty => '没有可用的日志。';
  @override
  String discovered({required Object protocol, required Object host}) => '通过 ${protocol} 发现 (${host})';
  @override
  String updated({required Object protocol, required Object host}) => '通过 ${protocol} 更新 (${host})';
}

// Path: progressPage.total
class Translations$progressPage$total$zh_CN extends Translations$progressPage$total$en {
  Translations$progressPage$total$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$progressPage$total$title$zh_CN title = Translations$progressPage$total$title$zh_CN.internal(_root);
  @override
  String count({required Object curr, required Object n}) => '文件：${curr} / ${n}';
  @override
  String size({required Object curr, required Object n}) => '大小：${curr} / ${n}';
  @override
  String speed({required Object speed}) => '速度：${speed}/s';
}

// Path: progressPage.remainingTime
class Translations$progressPage$remainingTime$zh_CN extends Translations$progressPage$remainingTime$en {
  Translations$progressPage$remainingTime$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String minutesUnit({required num m}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    m,
    other: '${m}分钟',
  );
  @override
  String hoursUnit({required num h}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('zh'))(
    h,
    other: '${h}小时',
  );
  @override
  String minutes({required Object m, required Object ss}) => '${m}:${ss}';
  @override
  String hours({required num h, required num m}) =>
      '${_root.progressPage.remainingTime.hoursUnit(h: h)} ${_root.progressPage.remainingTime.minutesUnit(m: m)}';
}

// Path: whatsNewPage.changes
class Translations$whatsNewPage$changes$zh_CN extends Translations$whatsNewPage$changes$en {
  Translations$whatsNewPage$changes$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  late final Translations$whatsNewPage$changes$v1_0_0$zh_CN v1_0_0 = Translations$whatsNewPage$changes$v1_0_0$zh_CN.internal(_root);
}

// Path: dialogs.addFile
class Translations$dialogs$addFile$zh_CN extends Translations$dialogs$addFile$en {
  Translations$dialogs$addFile$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '添加文件';
  @override
  String get content => '你想添加什么文件？';
}

// Path: dialogs.openFile
class Translations$dialogs$openFile$zh_CN extends Translations$dialogs$openFile$en {
  Translations$dialogs$openFile$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '打开文件';
  @override
  String get content => '您是否要打开接收的文件？';
}

// Path: dialogs.addressInput
class Translations$dialogs$addressInput$zh_CN extends Translations$dialogs$addressInput$en {
  Translations$dialogs$addressInput$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '输入地址';
  @override
  String get hashtag => '标签';
  @override
  String get ip => 'IP 地址';
  @override
  String get recentlyUsed => '最近使用： ';
}

// Path: dialogs.cancelSession
class Translations$dialogs$cancelSession$zh_CN extends Translations$dialogs$cancelSession$en {
  Translations$dialogs$cancelSession$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '取消文件传输';
  @override
  String get content => '要取消文件传输吗？';
}

// Path: dialogs.cannotOpenFile
class Translations$dialogs$cannotOpenFile$zh_CN extends Translations$dialogs$cannotOpenFile$en {
  Translations$dialogs$cannotOpenFile$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '无法打开文件';
  @override
  String content({required Object file}) => '无法打开 “${file}”。这个文件是否已被移动、重命名或删除？';
}

// Path: dialogs.encryptionDisabledNotice
class Translations$dialogs$encryptionDisabledNotice$zh_CN extends Translations$dialogs$encryptionDisabledNotice$en {
  Translations$dialogs$encryptionDisabledNotice$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '加密已关闭';
  @override
  String get content => '正在通过未加密的 HTTP 协议连接。要使用 HTTPS 协议，请开启加密选项。';
}

// Path: dialogs.errorDialog
class Translations$dialogs$errorDialog$zh_CN extends Translations$dialogs$errorDialog$en {
  Translations$dialogs$errorDialog$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.error;
}

// Path: dialogs.favoriteDialog
class Translations$dialogs$favoriteDialog$zh_CN extends Translations$dialogs$favoriteDialog$en {
  Translations$dialogs$favoriteDialog$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '收藏夹';
  @override
  String get noFavorites => '还没有收藏的设备。';
  @override
  String get addFavorite => '新建';
}

// Path: dialogs.favoriteDeleteDialog
class Translations$dialogs$favoriteDeleteDialog$zh_CN extends Translations$dialogs$favoriteDeleteDialog$en {
  Translations$dialogs$favoriteDeleteDialog$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '删除收藏';
  @override
  String content({required Object name}) => '确定要取消收藏 “${name}” 吗?';
}

// Path: dialogs.favoriteEditDialog
class Translations$dialogs$favoriteEditDialog$zh_CN extends Translations$dialogs$favoriteEditDialog$en {
  Translations$dialogs$favoriteEditDialog$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get titleAdd => '添加到收藏夹';
  @override
  String get titleEdit => '设置';
  @override
  String get name => '名称';
  @override
  String get auto => '(自动)';
  @override
  String get ip => 'IP 地址';
  @override
  String get port => '端口';
}

// Path: dialogs.fileInfo
class Translations$dialogs$fileInfo$zh_CN extends Translations$dialogs$fileInfo$en {
  Translations$dialogs$fileInfo$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '文件信息';
  @override
  String get fileName => '文件名：';
  @override
  String get path => '路径：';
  @override
  String get size => '大小：';
  @override
  String get sender => '发送者：';
  @override
  String get time => '时间：';
}

// Path: dialogs.fileNameInput
class Translations$dialogs$fileNameInput$zh_CN extends Translations$dialogs$fileNameInput$en {
  Translations$dialogs$fileNameInput$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '输入文件名';
  @override
  String original({required Object original}) => '原名：${original}';
}

// Path: dialogs.historyClearDialog
class Translations$dialogs$historyClearDialog$zh_CN extends Translations$dialogs$historyClearDialog$en {
  Translations$dialogs$historyClearDialog$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '清空历史记录';
  @override
  String get content => '确定要清空全部历史记录吗？';
}

// Path: dialogs.localNetworkUnauthorized
class Translations$dialogs$localNetworkUnauthorized$zh_CN extends Translations$dialogs$localNetworkUnauthorized$en {
  Translations$dialogs$localNetworkUnauthorized$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.dialogs.noPermission.title;
  @override
  String get description => 'LocalSend 在没有扫描本地网络的权限的情况下无法找到其他设备。请在设置中授予此权限。';
  @override
  String get gotoSettings => '设置';
}

// Path: dialogs.messageInput
class Translations$dialogs$messageInput$zh_CN extends Translations$dialogs$messageInput$en {
  Translations$dialogs$messageInput$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '输入消息';
  @override
  String get multiline => '多行';
}

// Path: dialogs.noFiles
class Translations$dialogs$noFiles$zh_CN extends Translations$dialogs$noFiles$en {
  Translations$dialogs$noFiles$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '未选择文件';
  @override
  String get content => '请至少选择一个文件。';
}

// Path: dialogs.noPermission
class Translations$dialogs$noPermission$zh_CN extends Translations$dialogs$noPermission$en {
  Translations$dialogs$noPermission$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '没有权限';
  @override
  String get content => '您尚未授予必要的权限。请在设置中授予权限。';
}

// Path: dialogs.notAvailableOnPlatform
class Translations$dialogs$notAvailableOnPlatform$zh_CN extends Translations$dialogs$notAvailableOnPlatform$en {
  Translations$dialogs$notAvailableOnPlatform$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '不可用';
  @override
  String get content => '此功能只在以下平台可用：';
}

// Path: dialogs.qr
class Translations$dialogs$qr$zh_CN extends Translations$dialogs$qr$en {
  Translations$dialogs$qr$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '二维码';
}

// Path: dialogs.quickActions
class Translations$dialogs$quickActions$zh_CN extends Translations$dialogs$quickActions$en {
  Translations$dialogs$quickActions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '快速操作';
  @override
  String get counter => '计数器';
  @override
  String get prefix => '前缀';
  @override
  String get padZero => '以零填充';
  @override
  String get sortBeforeCount => '事先以字母顺序排序';
  @override
  String get random => '随机';
}

// Path: dialogs.quickSaveNotice
class Translations$dialogs$quickSaveNotice$zh_CN extends Translations$dialogs$quickSaveNotice$en {
  Translations$dialogs$quickSaveNotice$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.quickSave;
  @override
  String get content => '自动接受所有文件传输请求。请注意，这会让此网络中的所有人都可以向你发送文件。';
}

// Path: dialogs.quickSaveFromFavoritesNotice
class Translations$dialogs$quickSaveFromFavoritesNotice$zh_CN extends Translations$dialogs$quickSaveFromFavoritesNotice$en {
  Translations$dialogs$quickSaveFromFavoritesNotice$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => _root.general.quickSaveFromFavorites;
  @override
  List<String> get content => [
    '当前会自动接受收藏夹中设备的文件请求。',
  ];
}

// Path: dialogs.pin
class Translations$dialogs$pin$zh_CN extends Translations$dialogs$pin$en {
  Translations$dialogs$pin$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '输入 PIN';
}

// Path: dialogs.sendModeHelp
class Translations$dialogs$sendModeHelp$zh_CN extends Translations$dialogs$sendModeHelp$en {
  Translations$dialogs$sendModeHelp$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => '发送模式';
  @override
  String get single => '加入设备发送队列，完成后保留文件选择，方便再次发送。';
  @override
  String get multiple => '发送文件给多个接收者。已选择的文件在发送后不会取消选择。';
  @override
  String get link => '未安装 LocalSend 的接收者可以在浏览器中打开链接以下载选中的文件。';
}

// Path: dialogs.zoom
class Translations$dialogs$zoom$zh_CN extends Translations$dialogs$zoom$en {
  Translations$dialogs$zoom$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get title => 'URL';
}

// Path: settingsTab.general.brightnessOptions
class Translations$settingsTab$general$brightnessOptions$zh_CN extends Translations$settingsTab$general$brightnessOptions$en {
  Translations$settingsTab$general$brightnessOptions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟随系统';
  @override
  String get dark => '深色';
  @override
  String get light => '浅色';
}

// Path: settingsTab.general.colorOptions
class Translations$settingsTab$general$colorOptions$zh_CN extends Translations$settingsTab$general$colorOptions$en {
  Translations$settingsTab$general$colorOptions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟随系统';
  @override
  String get oled => 'OLED';
  @override
  String get custom => '自定义';
}

// Path: settingsTab.general.languageOptions
class Translations$settingsTab$general$languageOptions$zh_CN extends Translations$settingsTab$general$languageOptions$en {
  Translations$settingsTab$general$languageOptions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get system => '跟随系统';
}

// Path: settingsTab.network.networkOptions
class Translations$settingsTab$network$networkOptions$zh_CN extends Translations$settingsTab$network$networkOptions$en {
  Translations$settingsTab$network$networkOptions$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String get all => '所有';
  @override
  String get filtered => '已过滤';
}

// Path: progressPage.total.title
class Translations$progressPage$total$title$zh_CN extends Translations$progressPage$total$title$en {
  Translations$progressPage$total$title$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  String sending({required Object time}) => '总进度 (${time})';
  @override
  String get finishedError => '已完成，但发生错误';
  @override
  String get canceledSender => '发送者已取消';
  @override
  String get canceledReceiver => '接收者已取消';
}

// Path: whatsNewPage.changes.v1_0_0
class Translations$whatsNewPage$changes$v1_0_0$zh_CN extends Translations$whatsNewPage$changes$v1_0_0$en with WhatsNewStrings {
  Translations$whatsNewPage$changes$v1_0_0$zh_CN.internal(TranslationsZhCn root) : this._root = root, super.internal(root);

  final TranslationsZhCn _root; // ignore: unused_field

  // Translations
  @override
  List<String> get changes => [
    '工作区自动填写名称，支持自定义路径和一键复制链接。',
    'macOS 记住工作区目录授权，可在工作区页重新启动共享服务。',
    '开启工作区上传后，已授权访客直接上传、重试，不再反复确认。',
    '手机相册支持批量选择，桌面可多选图片和视频。',
    '文件与文件夹排队发送，统一管理发送和接收。',
    '浏览器内预览、搜索和下载共享内容。',
    '优化工作区表单，减少解释性文案。',
  ];
}
