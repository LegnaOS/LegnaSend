///
/// Generated file. Do not edit.
///
// coverage:ignore-file
// ignore_for_file: type=lint, unused_import

part of 'strings.g.dart';

// Path: <root>
typedef TranslationsEn = Translations; // ignore: unused_element

class Translations with BaseTranslations<AppLocale, Translations> {
  /// Returns the current translations of the given [context].
  ///
  /// Usage:
  /// final t = Translations.of(context);
  static Translations of(BuildContext context) => InheritedLocaleData.of<AppLocale, Translations>(context).translations;

  /// You can call this constructor and build your own translation instance of this locale.
  /// Constructing via the enum [AppLocale.build] is preferred.
  Translations({
    Map<String, Node>? overrides,
    PluralResolver? cardinalResolver,
    PluralResolver? ordinalResolver,
    TranslationMetadata<AppLocale, Translations>? meta,
  }) : assert(overrides == null, 'Set "translation_overrides: true" in order to enable this feature.'),
       $meta =
           meta ??
           TranslationMetadata(
             locale: AppLocale.en,
             overrides: overrides ?? {},
             cardinalResolver: cardinalResolver,
             ordinalResolver: ordinalResolver,
           );

  /// Metadata for the translations of <en>.
  @override
  final TranslationMetadata<AppLocale, Translations> $meta;

  late final Translations _root = this; // ignore: unused_field

  Translations $copyWith({TranslationMetadata<AppLocale, Translations>? meta}) => Translations(meta: meta ?? this.$meta);

  // Translations

  /// en: 'LegnaSend'
  String get appName => 'LegnaSend';

  late final Translations$general$en general = Translations$general$en.internal(_root);
  late final Translations$receiveTab$en receiveTab = Translations$receiveTab$en.internal(_root);
  late final Translations$sendTab$en sendTab = Translations$sendTab$en.internal(_root);
  late final Translations$settingsTab$en settingsTab = Translations$settingsTab$en.internal(_root);
  late final Translations$troubleshootPage$en troubleshootPage = Translations$troubleshootPage$en.internal(_root);
  late final Translations$networkInterfacesPage$en networkInterfacesPage = Translations$networkInterfacesPage$en.internal(_root);
  late final Translations$receiveHistoryPage$en receiveHistoryPage = Translations$receiveHistoryPage$en.internal(_root);
  late final Translations$apkPickerPage$en apkPickerPage = Translations$apkPickerPage$en.internal(_root);
  late final Translations$selectedFilesPage$en selectedFilesPage = Translations$selectedFilesPage$en.internal(_root);
  late final Translations$deviceDetailsPage$en deviceDetailsPage = Translations$deviceDetailsPage$en.internal(_root);
  late final Translations$verifyPage$en verifyPage = Translations$verifyPage$en.internal(_root);
  late final Translations$receivePage$en receivePage = Translations$receivePage$en.internal(_root);
  late final Translations$receiveOptionsPage$en receiveOptionsPage = Translations$receiveOptionsPage$en.internal(_root);
  late final Translations$sendPage$en sendPage = Translations$sendPage$en.internal(_root);
  late final Translations$progressPage$en progressPage = Translations$progressPage$en.internal(_root);
  late final Translations$webSharePage$en webSharePage = Translations$webSharePage$en.internal(_root);
  late final Translations$webReceivePage$en webReceivePage = Translations$webReceivePage$en.internal(_root);
  late final Translations$aboutPage$en aboutPage = Translations$aboutPage$en.internal(_root);
  late final Translations$donationPage$en donationPage = Translations$donationPage$en.internal(_root);
  late final Translations$directoryWorkspaces$en directoryWorkspaces = Translations$directoryWorkspaces$en.internal(_root);
  late final Translations$changelogPage$en changelogPage = Translations$changelogPage$en.internal(_root);
  late final Translations$whatsNewPage$en whatsNewPage = Translations$whatsNewPage$en.internal(_root);
  late final Translations$aliasGenerator$en aliasGenerator = Translations$aliasGenerator$en.internal(_root);
  late final Translations$dialogs$en dialogs = Translations$dialogs$en.internal(_root);
  late final Translations$sanitization$en sanitization = Translations$sanitization$en.internal(_root);
  late final Translations$tray$en tray = Translations$tray$en.internal(_root);
  late final Translations$web$en web = Translations$web$en.internal(_root);
  late final Translations$assetPicker$en assetPicker = Translations$assetPicker$en.internal(_root);
  late final Translations$networkLabels$en networkLabels = Translations$networkLabels$en.internal(_root);
  late final Translations$sendQueue$en sendQueue = Translations$sendQueue$en.internal(_root);
  late final Translations$transferActivity$en transferActivity = Translations$transferActivity$en.internal(_root);
  late final Translations$webPreview$en webPreview = Translations$webPreview$en.internal(_root);
  late final Translations$webTextPreview$en webTextPreview = Translations$webTextPreview$en.internal(_root);
  late final Translations$transportSecurity$en transportSecurity = Translations$transportSecurity$en.internal(_root);
  late final Translations$transferSpeed$en transferSpeed = Translations$transferSpeed$en.internal(_root);
  late final Translations$transferNavigation$en transferNavigation = Translations$transferNavigation$en.internal(_root);
  late final Translations$networkEnvironment$en networkEnvironment = Translations$networkEnvironment$en.internal(_root);
  late final Translations$linkWorkspace$en linkWorkspace = Translations$linkWorkspace$en.internal(_root);
  late final Translations$integrationApi$en integrationApi = Translations$integrationApi$en.internal(_root);
  late final Translations$apiExplorer$en apiExplorer = Translations$apiExplorer$en.internal(_root);
  late final Translations$sharedFileManagement$en sharedFileManagement = Translations$sharedFileManagement$en.internal(_root);
}

// Path: general
class Translations$general$en {
  Translations$general$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Accept'
  String get accept => 'Accept';

  /// en: 'Accepted'
  String get accepted => 'Accepted';

  /// en: 'Add'
  String get add => 'Add';

  /// en: 'Advanced'
  String get advanced => 'Advanced';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Close'
  String get close => 'Close';

  /// en: 'Confirm'
  String get confirm => 'Confirm';

  /// en: 'Continue'
  String get continueStr => 'Continue';

  /// en: 'Copy'
  String get copy => 'Copy';

  /// en: 'Copied to Clipboard'
  String get copiedToClipboard => 'Copied to Clipboard';

  /// en: 'Decline'
  String get decline => 'Decline';

  /// en: 'Done'
  String get done => 'Done';

  /// en: 'Delete'
  String get delete => 'Delete';

  /// en: 'Edit'
  String get edit => 'Edit';

  /// en: 'Error'
  String get error => 'Error';

  /// en: 'Example'
  String get example => 'Example';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'Finished'
  String get finished => 'Finished';

  /// en: 'Hide'
  String get hide => 'Hide';

  /// en: 'Off'
  String get off => 'Off';

  /// en: 'Offline'
  String get offline => 'Offline';

  /// en: 'On'
  String get on => 'On';

  /// en: 'Online'
  String get online => 'Online';

  /// en: 'Open'
  String get open => 'Open';

  /// en: 'Queue'
  String get queue => 'Queue';

  /// en: 'Quick Save'
  String get quickSave => 'Quick Save';

  /// en: 'Quick Save for "Favorites"'
  String get quickSaveFromFavorites => 'Quick Save for "Favorites"';

  /// en: 'Renamed'
  String get renamed => 'Renamed';

  /// en: 'Undo changes'
  String get reset => 'Undo changes';

  /// en: 'Restart'
  String get restart => 'Restart';

  /// en: 'Settings'
  String get settings => 'Settings';

  /// en: 'Skipped'
  String get skipped => 'Skipped';

  /// en: 'Start'
  String get start => 'Start';

  /// en: 'Stop'
  String get stop => 'Stop';

  /// en: 'Save'
  String get save => 'Save';

  /// en: 'Unchanged'
  String get unchanged => 'Unchanged';

  /// en: 'Unknown'
  String get unknown => 'Unknown';

  /// en: 'No items in Clipboard.'
  String get noItemInClipboard => 'No items in Clipboard.';
}

// Path: receiveTab
class Translations$receiveTab$en {
  Translations$receiveTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive'
  String get title => 'Receive';

  late final Translations$receiveTab$infoBox$en infoBox = Translations$receiveTab$infoBox$en.internal(_root);
  late final Translations$receiveTab$quickSave$en quickSave = Translations$receiveTab$quickSave$en.internal(_root);

  /// en: 'Link workspace'
  String get link => 'Link workspace';
}

// Path: sendTab
class Translations$sendTab$en {
  Translations$sendTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send'
  String get title => 'Send';

  late final Translations$sendTab$selection$en selection = Translations$sendTab$selection$en.internal(_root);
  late final Translations$sendTab$picker$en picker = Translations$sendTab$picker$en.internal(_root);

  /// en: 'You can also use the "Share" feature of your mobile device to select files more easily.'
  String get shareIntentInfo => 'You can also use the "Share" feature of your mobile device to select files more easily.';

  /// en: 'Nearby devices'
  String get nearbyDevices => 'Nearby devices';

  /// en: 'This Device'
  String get thisDevice => 'This Device';

  /// en: 'Search devices'
  String get scan => 'Search devices';

  /// en: 'Manual sending'
  String get manualSending => 'Manual sending';

  /// en: 'Send mode'
  String get sendMode => 'Send mode';

  late final Translations$sendTab$sendModes$en sendModes = Translations$sendTab$sendModes$en.internal(_root);

  /// en: 'Explanation'
  String get sendModeHelp => 'Explanation';

  /// en: 'Please ensure that the desired target is also on the same Wi-Fi network.'
  String get help => 'Please ensure that the desired target is also on the same Wi-Fi network.';

  /// en: 'Place items to share.'
  String get placeItems => 'Place items to share.';
}

// Path: settingsTab
class Translations$settingsTab$en {
  Translations$settingsTab$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Settings'
  String get title => 'Settings';

  late final Translations$settingsTab$general$en general = Translations$settingsTab$general$en.internal(_root);
  late final Translations$settingsTab$receive$en receive = Translations$settingsTab$receive$en.internal(_root);
  late final Translations$settingsTab$send$en send = Translations$settingsTab$send$en.internal(_root);
  late final Translations$settingsTab$network$en network = Translations$settingsTab$network$en.internal(_root);
  late final Translations$settingsTab$other$en other = Translations$settingsTab$other$en.internal(_root);

  /// en: 'Advanced settings'
  String get advancedSettings => 'Advanced settings';
}

// Path: troubleshootPage
class Translations$troubleshootPage$en {
  Translations$troubleshootPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Troubleshoot'
  String get title => 'Troubleshoot';

  /// en: 'Does the app not work as expected? Here you can find some common solutions to problems.'
  String get subTitle => 'Does the app not work as expected? Here you can find some common solutions to problems.';

  /// en: 'Solution:'
  String get solution => 'Solution:';

  /// en: 'Fix automatically'
  String get fixButton => 'Fix automatically';

  late final Translations$troubleshootPage$firewall$en firewall = Translations$troubleshootPage$firewall$en.internal(_root);
  late final Translations$troubleshootPage$noDiscovery$en noDiscovery = Translations$troubleshootPage$noDiscovery$en.internal(_root);
  late final Translations$troubleshootPage$noConnection$en noConnection = Translations$troubleshootPage$noConnection$en.internal(_root);
}

// Path: networkInterfacesPage
class Translations$networkInterfacesPage$en {
  Translations$networkInterfacesPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Network Interfaces'
  String get title => 'Network Interfaces';

  /// en: 'By default, LocalSend uses all available network interfaces. You can exclude unwanted networks here. You need to restart the server to apply the changes.'
  String get info =>
      'By default, LocalSend uses all available network interfaces. You can exclude unwanted networks here. You need to restart the server to apply the changes.';

  /// en: 'Preview'
  String get preview => 'Preview';

  /// en: 'Whitelist'
  String get whitelist => 'Whitelist';

  /// en: 'Blacklist'
  String get blacklist => 'Blacklist';
}

// Path: receiveHistoryPage
class Translations$receiveHistoryPage$en {
  Translations$receiveHistoryPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'History'
  String get title => 'History';

  /// en: 'Open folder'
  String get openFolder => 'Open folder';

  /// en: 'Delete history'
  String get deleteHistory => 'Delete history';

  /// en: 'The history is empty.'
  String get empty => 'The history is empty.';

  late final Translations$receiveHistoryPage$entryActions$en entryActions = Translations$receiveHistoryPage$entryActions$en.internal(_root);
}

// Path: apkPickerPage
class Translations$apkPickerPage$en {
  Translations$apkPickerPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Apps (APK)'
  String get title => 'Apps (APK)';

  /// en: 'Exclude system apps'
  String get excludeSystemApps => 'Exclude system apps';

  /// en: 'Exclude non-launchable apps'
  String get excludeAppsWithoutLaunchIntent => 'Exclude non-launchable apps';

  /// en: '{n} Apps'
  String apps({required Object n}) => '${n} Apps';
}

// Path: selectedFilesPage
class Translations$selectedFilesPage$en {
  Translations$selectedFilesPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Delete all'
  String get deleteAll => 'Delete all';
}

// Path: deviceDetailsPage
class Translations$deviceDetailsPage$en {
  Translations$deviceDetailsPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Device Details'
  String get title => 'Device Details';

  /// en: 'Favorite'
  String get favorite => 'Favorite';

  /// en: 'Verify'
  String get verify => 'Verify';

  late final Translations$deviceDetailsPage$info$en info = Translations$deviceDetailsPage$info$en.internal(_root);
  late final Translations$deviceDetailsPage$logs$en logs = Translations$deviceDetailsPage$logs$en.internal(_root);
}

// Path: verifyPage
class Translations$verifyPage$en {
  Translations$verifyPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Verify'
  String get title => 'Verify';

  /// en: 'Icons'
  String get icons => 'Icons';

  /// en: 'Text'
  String get text => 'Text';

  /// en: 'Does it look the same on the other device?'
  String get question => 'Does it look the same on the other device?';
}

// Path: receivePage
class Translations$receivePage$en {
  Translations$receivePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Verifying received data'
  String get verifyingReceivedData => 'Verifying received data';

  /// en: 'This receive session expired after 10 idle minutes with no file upload in progress. Ask the sender to start a new transfer. Completed files are preserved.'
  String get idleExpired =>
      'This receive session expired after 10 idle minutes with no file upload in progress. Ask the sender to start a new transfer. Completed files are preserved.';

  /// en: '(one) {wants to send you a file} (other) {wants to send you {n} files}'
  String subTitle({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'wants to send you a file',
    other: 'wants to send you ${n} files',
  );

  /// en: 'sent you a message:'
  String get subTitleMessage => 'sent you a message:';

  /// en: 'sent you a link:'
  String get subTitleLink => 'sent you a link:';

  /// en: 'The sender has canceled the request.'
  String get canceled => 'The sender has canceled the request.';

  /// en: 'The download directory is unavailable. Check storage permissions, free space and the save location, then retry.'
  String get destinationUnavailable =>
      'The download directory is unavailable. Check storage permissions, free space and the save location, then retry.';
}

// Path: receiveOptionsPage
class Translations$receiveOptionsPage$en {
  Translations$receiveOptionsPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Options'
  String get title => 'Options';

  /// en: 'Save to folder'
  String get destination => _root.settingsTab.receive.destination;

  /// en: '(LocalSend folder)'
  String get appDirectory => '(LocalSend folder)';

  /// en: 'Save media to gallery'
  String get saveToGallery => _root.settingsTab.receive.saveToGallery;

  /// en: 'Turned off automatically because there are folders.'
  String get saveToGalleryOff => 'Turned off automatically because there are folders.';
}

// Path: sendPage
class Translations$sendPage$en {
  Translations$sendPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Verifying source data'
  String get verifyingSourceData => 'Verifying source data';

  /// en: 'Calculating checksum ({curr} / {n})'
  String calculatingChecksum({required Object curr, required Object n}) => 'Calculating checksum (${curr} / ${n})';

  /// en: 'Waiting for response…'
  String get waiting => 'Waiting for response…';

  /// en: 'The recipient has rejected the request.'
  String get rejected => 'The recipient has rejected the request.';

  /// en: 'Too many attempts'
  String get tooManyAttempts => _root.web.tooManyAttempts;

  /// en: 'The recipient is busy with another request.'
  String get busy => 'The recipient is busy with another request.';
}

// Path: progressPage
class Translations$progressPage$en {
  Translations$progressPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Sending files'
  String get titleSending => 'Sending files';

  /// en: 'Receiving files'
  String get titleReceiving => 'Receiving files';

  /// en: 'Saved in Photos'
  String get savedToGallery => 'Saved in Photos';

  late final Translations$progressPage$total$en total = Translations$progressPage$total$en.internal(_root);
  late final Translations$progressPage$remainingTime$en remainingTime = Translations$progressPage$remainingTime$en.internal(_root);
}

// Path: webSharePage
class Translations$webSharePage$en {
  Translations$webSharePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Share via link'
  String get title => 'Share via link';

  /// en: 'Starting server…'
  String get loading => 'Starting server…';

  /// en: 'Stopping server…'
  String get stopping => 'Stopping server…';

  /// en: 'An error occurred while starting the server.'
  String get error => 'An error occurred while starting the server.';

  /// en: '(one) {Open this link in your browser:} (other) {Open one of these links in your browser:}'
  String openLink({required num n}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    n,
    one: 'Open this link in your browser:',
    other: 'Open one of these links in your browser:',
  );

  /// en: 'Requests'
  String get requests => 'Requests';

  /// en: 'No requests yet.'
  String get noRequests => 'No requests yet.';

  /// en: 'Encryption'
  String get encryption => _root.settingsTab.network.encryption;

  /// en: 'Automatically accept requests'
  String get autoAccept => 'Automatically accept requests';

  /// en: 'Require PIN'
  String get requirePin => 'Require PIN';

  /// en: 'The PIN is "{pin}"'
  String pinHint({required Object pin}) => 'The PIN is "${pin}"';

  /// en: 'LocalSend uses a self-signed certificate. You need to accept it in your browser.'
  String get encryptionHint => 'LocalSend uses a self-signed certificate. You need to accept it in your browser.';

  /// en: 'Pending requests: {n}'
  String pendingRequests({required Object n}) => 'Pending requests: ${n}';
}

// Path: webReceivePage
class Translations$webReceivePage$en {
  Translations$webReceivePage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive via link'
  String get title => 'Receive via link';
}

// Path: aboutPage
class Translations$aboutPage$en {
  Translations$aboutPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'About LegnaSend'
  String get title => 'About LegnaSend';

  List<String> get description => [
    'LegnaSend is an open-source file-sharing app with interface-aware links, device network tags and repeat-send queues.',
  ];

  /// en: 'Author'
  String get author => 'Author';

  /// en: 'Contributors'
  String get contributors => 'Contributors';

  /// en: 'Packagers'
  String get packagers => 'Packagers';

  /// en: 'Translators'
  String get translators => 'Translators';

  /// en: 'Open-source acknowledgements'
  String get upstreamCredits => 'Open-source acknowledgements';

  /// en: 'Version {version}'
  String version({required Object version}) => 'Version ${version}';

  /// en: 'License notices'
  String get licenseNotices => 'License notices';

  /// en: 'Diagnostics'
  String get debugging => 'Diagnostics';
}

// Path: donationPage
class Translations$donationPage$en {
  Translations$donationPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Donate'
  String get title => 'Donate';

  /// en: 'LocalSend is free, open-source and without any ads. If you like the app, you can support the development with a donation.'
  String get info => 'LocalSend is free, open-source and without any ads. If you like the app, you can support the development with a donation.';

  /// en: 'Donate {amount}'
  String donate({required Object amount}) => 'Donate ${amount}';

  /// en: 'Thank you very much!'
  String get thanks => 'Thank you very much!';

  /// en: 'Restore purchase'
  String get restore => 'Restore purchase';
}

// Path: directoryWorkspaces
class Translations$directoryWorkspaces$en {
  Translations$directoryWorkspaces$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Workspaces'
  String get title => 'Workspaces';

  /// en: 'Create workspace'
  String get create => 'Create workspace';

  /// en: 'Name'
  String get name => 'Name';

  /// en: 'URL path'
  String get slug => 'URL path';

  /// en: 'Local directory'
  String get root => 'Local directory';

  /// en: 'Choose directory'
  String get choose => 'Choose directory';

  /// en: 'Visible in index'
  String get visible => 'Visible in index';

  /// en: 'Hidden from index'
  String get hidden => 'Hidden from index';

  /// en: 'Hide'
  String get hide => 'Hide';

  /// en: 'Show'
  String get show => 'Show';

  /// en: 'Closed'
  String get closed => 'Closed';

  /// en: 'Serving'
  String get serving => 'Serving';

  /// en: 'Previous configuration still serving'
  String get previousServing => 'Previous configuration still serving';

  /// en: 'Invalid source'
  String get invalid => 'Invalid source';

  /// en: 'Applying changes'
  String get syncing => 'Applying changes';

  /// en: 'Server stopped'
  String get serverOff => 'Server stopped';

  /// en: 'Read-only directory'
  String get readOnly => 'Read-only directory';

  /// en: 'Workspaces start read-only. Enable browser uploads separately for each directory; existing files are not overwritten.'
  String get readOnlyHint => 'Workspaces start read-only. Enable browser uploads separately for each directory; existing files are not overwritten.';

  /// en: 'Create a workspace from a local directory. Its files stay in their original location.'
  String get empty => 'Create a workspace from a local directory. Its files stay in their original location.';

  /// en: 'The operation failed. Check the name, unique URL path, directory access and service status.'
  String get failed => 'The operation failed. Check the name, unique URL path, directory access and service status.';

  /// en: 'Changes were not confirmed by the server. Previously published routes may still be active. Retry synchronization.'
  String get syncFailed => 'Changes were not confirmed by the server. Previously published routes may still be active. Retry synchronization.';

  /// en: 'Retry synchronization'
  String get retry => 'Retry synchronization';

  /// en: 'Open'
  String get enable => 'Open';

  /// en: 'Close'
  String get close => 'Close';

  /// en: 'Destroy workspace'
  String get destroy => 'Destroy workspace';

  /// en: 'Check directory'
  String get validate => 'Check directory';

  /// en: 'Stop requests for this workspace. Other workspaces and native transfers continue. Source files will not be deleted.'
  String get stopHint => 'Stop requests for this workspace. Other workspaces and native transfers continue. Source files will not be deleted.';

  /// en: 'Hidden workspaces are omitted from the index, but remain accessible by direct link. Hiding is not password protection.'
  String get hiddenHint => 'Hidden workspaces are omitted from the index, but remain accessible by direct link. Hiding is not password protection.';

  /// en: 'Close the workspace before changing its URL path or source directory.'
  String get closeToEdit => 'Close the workspace before changing its URL path or source directory.';

  /// en: 'Enter a name, a lowercase URL path such as workspace1, and a local directory.'
  String get invalidInput => 'Enter a name, a lowercase URL path such as workspace1, and a local directory.';

  Map<String, String> get reasons => {
    'missing': 'Directory missing',
    'notDirectory': 'Not a local directory',
    'permissionDenied': 'Directory permission denied',
    'grantUnavailable': 'Directory permission is unavailable; select the folder again',
    'ioError': 'Directory read failed',
    'timeout': 'Directory check timed out',
  };

  /// en: 'Access protection'
  String get access => 'Access protection';

  /// en: 'Password protected'
  String get protected => 'Password protected';

  /// en: 'Open access'
  String get openAccess => 'Open access';

  /// en: 'New password or PIN'
  String get password => 'New password or PIN';

  /// en: 'Confirm password'
  String get confirmPassword => 'Confirm password';

  /// en: 'Leave blank to keep the current password.'
  String get keepPassword => 'Leave blank to keep the current password.';

  /// en: 'Use 4–128 characters and enter the same password twice.'
  String get passwordInvalid => 'Use 4–128 characters and enter the same password twice.';

  /// en: 'Saving a changed password or access mode revokes previous grants and stops this workspace’s active downloads. HTTPS protects transport; the password controls access.'
  String get passwordHint =>
      'Saving a changed password or access mode revokes previous grants and stops this workspace’s active downloads. HTTPS protects transport; the password controls access.';

  /// en: 'Access policy awaiting server confirmation'
  String get accessPending => 'Access policy awaiting server confirmation';

  /// en: 'Upload permission'
  String get uploadPermission => 'Upload permission';

  /// en: 'Allow browser uploads'
  String get allowUpload => 'Allow browser uploads';

  /// en: 'Anyone who can access this workspace may upload files and folders directly into its directory. Existing files are never overwritten. Turning this off stops unfinished uploads; saved files remain. Password-protected workspaces still require unlocking.'
  String get uploadHint =>
      'Anyone who can access this workspace may upload files and folders directly into its directory. Existing files are never overwritten. Turning this off stops unfinished uploads; saved files remain. Password-protected workspaces still require unlocking.';

  /// en: 'Upload permission pending'
  String get uploadPending => 'Upload permission pending';

  /// en: 'Uploads are controlled per workspace'
  String get permissionHint => 'Uploads are controlled per workspace';
}

// Path: changelogPage
class Translations$changelogPage$en {
  Translations$changelogPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Changelog'
  String get title => 'Changelog';

  /// en: 'Release-note language'
  String get language => 'Release-note language';

  /// en: 'Follow app language'
  String get followApp => 'Follow app language';

  /// en: 'This translation is not available yet. Showing {language}.'
  String fallback({required Object language}) => 'This translation is not available yet. Showing ${language}.';

  /// en: 'The release notes could not be loaded.'
  String get loadError => 'The release notes could not be loaded.';

  /// en: 'Retry'
  String get retry => 'Retry';
}

// Path: whatsNewPage
class Translations$whatsNewPage$en {
  Translations$whatsNewPage$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'What's new in {version}'
  String title({required Object version}) => 'What\'s new in ${version}';

  late final Translations$whatsNewPage$changes$en changes = Translations$whatsNewPage$changes$en.internal(_root);
}

// Path: aliasGenerator
class Translations$aliasGenerator$en {
  Translations$aliasGenerator$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  List<String> get adjectives => [
    'Adorable',
    'Beautiful',
    'Big',
    'Bright',
    'Clean',
    'Clever',
    'Cool',
    'Cute',
    'Cunning',
    'Determined',
    'Energetic',
    'Efficient',
    'Fantastic',
    'Fast',
    'Fine',
    'Fresh',
    'Good',
    'Gorgeous',
    'Great',
    'Handsome',
    'Hot',
    'Kind',
    'Lovely',
    'Mystic',
    'Neat',
    'Nice',
    'Patient',
    'Pretty',
    'Powerful',
    'Rich',
    'Secret',
    'Smart',
    'Solid',
    'Special',
    'Strategic',
    'Strong',
    'Tidy',
    'Wise',
  ];
  List<String> get fruits => [
    'Apple',
    'Avocado',
    'Banana',
    'Blackberry',
    'Blueberry',
    'Broccoli',
    'Carrot',
    'Cherry',
    'Coconut',
    'Grape',
    'Lemon',
    'Lettuce',
    'Mango',
    'Melon',
    'Mushroom',
    'Onion',
    'Orange',
    'Papaya',
    'Peach',
    'Pear',
    'Pineapple',
    'Potato',
    'Pumpkin',
    'Raspberry',
    'Strawberry',
    'Tomato',
  ];

  /// In some languages, the adjective must be last.
  ///
  /// en: '{adjective} {fruit}'
  String combination({required Object adjective, required Object fruit}) => '${adjective} ${fruit}';
}

// Path: dialogs
class Translations$dialogs$en {
  Translations$dialogs$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$dialogs$addFile$en addFile = Translations$dialogs$addFile$en.internal(_root);
  late final Translations$dialogs$openFile$en openFile = Translations$dialogs$openFile$en.internal(_root);
  late final Translations$dialogs$addressInput$en addressInput = Translations$dialogs$addressInput$en.internal(_root);
  late final Translations$dialogs$cancelSession$en cancelSession = Translations$dialogs$cancelSession$en.internal(_root);
  late final Translations$dialogs$cannotOpenFile$en cannotOpenFile = Translations$dialogs$cannotOpenFile$en.internal(_root);
  late final Translations$dialogs$encryptionDisabledNotice$en encryptionDisabledNotice = Translations$dialogs$encryptionDisabledNotice$en.internal(
    _root,
  );
  late final Translations$dialogs$errorDialog$en errorDialog = Translations$dialogs$errorDialog$en.internal(_root);
  late final Translations$dialogs$favoriteDialog$en favoriteDialog = Translations$dialogs$favoriteDialog$en.internal(_root);
  late final Translations$dialogs$favoriteDeleteDialog$en favoriteDeleteDialog = Translations$dialogs$favoriteDeleteDialog$en.internal(_root);
  late final Translations$dialogs$favoriteEditDialog$en favoriteEditDialog = Translations$dialogs$favoriteEditDialog$en.internal(_root);
  late final Translations$dialogs$fileInfo$en fileInfo = Translations$dialogs$fileInfo$en.internal(_root);
  late final Translations$dialogs$fileNameInput$en fileNameInput = Translations$dialogs$fileNameInput$en.internal(_root);
  late final Translations$dialogs$historyClearDialog$en historyClearDialog = Translations$dialogs$historyClearDialog$en.internal(_root);
  late final Translations$dialogs$localNetworkUnauthorized$en localNetworkUnauthorized = Translations$dialogs$localNetworkUnauthorized$en.internal(
    _root,
  );
  late final Translations$dialogs$messageInput$en messageInput = Translations$dialogs$messageInput$en.internal(_root);
  late final Translations$dialogs$noFiles$en noFiles = Translations$dialogs$noFiles$en.internal(_root);
  late final Translations$dialogs$noPermission$en noPermission = Translations$dialogs$noPermission$en.internal(_root);
  late final Translations$dialogs$notAvailableOnPlatform$en notAvailableOnPlatform = Translations$dialogs$notAvailableOnPlatform$en.internal(_root);
  late final Translations$dialogs$qr$en qr = Translations$dialogs$qr$en.internal(_root);
  late final Translations$dialogs$quickActions$en quickActions = Translations$dialogs$quickActions$en.internal(_root);
  late final Translations$dialogs$quickSaveNotice$en quickSaveNotice = Translations$dialogs$quickSaveNotice$en.internal(_root);
  late final Translations$dialogs$quickSaveFromFavoritesNotice$en quickSaveFromFavoritesNotice =
      Translations$dialogs$quickSaveFromFavoritesNotice$en.internal(_root);
  late final Translations$dialogs$pin$en pin = Translations$dialogs$pin$en.internal(_root);
  late final Translations$dialogs$sendModeHelp$en sendModeHelp = Translations$dialogs$sendModeHelp$en.internal(_root);
  late final Translations$dialogs$zoom$en zoom = Translations$dialogs$zoom$en.internal(_root);
}

// Path: sanitization
class Translations$sanitization$en {
  Translations$sanitization$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Filename cannot be empty'
  String get empty => 'Filename cannot be empty';

  /// en: 'Filename contains invalid characters'
  String get invalid => 'Filename contains invalid characters';
}

// Path: tray
class Translations$tray$en {
  Translations$tray$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open'
  String get open => _root.general.open;

  /// en: 'Quit LocalSend'
  String get close => 'Quit LocalSend';

  /// en: 'Exit'
  String get closeWindows => 'Exit';
}

// Path: web
class Translations$web$en {
  Translations$web$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Waiting for response…'
  String get waiting => _root.sendPage.waiting;

  /// en: 'Enter PIN'
  String get enterPin => 'Enter PIN';

  /// en: 'Invalid PIN'
  String get invalidPin => 'Invalid PIN';

  /// en: 'Too many attempts'
  String get tooManyAttempts => 'Too many attempts';

  /// en: 'Rejected'
  String get rejected => 'Rejected';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'File name'
  String get fileName => 'File name';

  /// en: 'Size'
  String get size => 'Size';
}

// Path: assetPicker
class Translations$assetPicker$en {
  Translations$assetPicker$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Confirm'
  String get confirm => 'Confirm';

  /// en: 'Cancel'
  String get cancel => 'Cancel';

  /// en: 'Edit'
  String get edit => 'Edit';

  /// en: 'GIF'
  String get gifIndicator => 'GIF';

  /// en: 'Load failed'
  String get loadFailed => 'Load failed';

  /// en: 'Origin'
  String get original => 'Origin';

  /// en: 'Preview'
  String get preview => 'Preview';

  /// en: 'Select'
  String get select => 'Select';

  /// en: 'Empty list'
  String get emptyList => 'Empty list';

  /// en: 'Unsupported file type.'
  String get unSupportedAssetType => 'Unsupported file type.';

  /// en: 'Unable to access all files on the device'
  String get unableToAccessAll => 'Unable to access all files on the device';

  /// en: 'Only view files and albums accessible to the app.'
  String get viewingLimitedAssetsTip => 'Only view files and albums accessible to the app.';

  /// en: 'Click to update accessible files'
  String get changeAccessibleLimitedAssets => 'Click to update accessible files';

  /// en: 'App can only access some files on the device. Go to system settings and allow the app to access all media on the device.'
  String get accessAllTip =>
      'App can only access some files on the device. Go to system settings and allow the app to access all media on the device.';

  /// en: 'Go to system settings'
  String get goToSystemSettings => 'Go to system settings';

  /// en: 'Continue with limited access'
  String get accessLimitedAssets => 'Continue with limited access';

  /// en: 'Accessible files'
  String get accessiblePathName => 'Accessible files';

  /// en: 'Audio'
  String get sTypeAudioLabel => 'Audio';

  /// en: 'Image'
  String get sTypeImageLabel => 'Image';

  /// en: 'Video'
  String get sTypeVideoLabel => 'Video';

  /// en: 'Other media'
  String get sTypeOtherLabel => 'Other media';

  /// en: 'play'
  String get sActionPlayHint => 'play';

  /// en: 'preview'
  String get sActionPreviewHint => 'preview';

  /// en: 'select'
  String get sActionSelectHint => 'select';

  /// en: 'change path'
  String get sActionSwitchPathLabel => 'change path';

  /// en: 'use camera'
  String get sActionUseCameraHint => 'use camera';

  /// en: 'duration'
  String get sNameDurationLabel => 'duration';

  /// en: 'count'
  String get sUnitAssetCountLabel => 'count';
}

// Path: networkLabels
class Translations$networkLabels$en {
  Translations$networkLabels$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Refresh networks'
  String get refresh => 'Refresh networks';

  /// en: 'No usable IPv4 address. Connect to a network and refresh.'
  String get noAddress => 'No usable IPv4 address. Connect to a network and refresh.';

  /// en: 'Subnet unknown'
  String get unknownSubnet => 'Subnet unknown';

  /// en: 'Matching local networks (the operating system selects the actual route)'
  String get networkMatch => 'Matching local networks (the operating system selects the actual route)';

  /// en: 'Routed / network unknown'
  String get routedOrUnknown => 'Routed / network unknown';

  /// en: 'Multiple matching interfaces · route unconfirmed'
  String get overlappingNetworks => 'Multiple matching interfaces · route unconfirmed';
}

// Path: sendQueue
class Translations$sendQueue$en {
  Translations$sendQueue$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Retry this file as a new transfer task'
  String get singleFileRetryNewTask => 'Retry this file as a new transfer task';

  /// en: 'A new transfer task was created. Completed files are unchanged.'
  String get singleFileRetryStarted => 'A new transfer task was created. Completed files are unchanged.';

  /// en: 'Send queue'
  String get title => 'Send queue';

  /// en: 'Queued'
  String get queued => 'Queued';

  /// en: 'Sending'
  String get running => 'Sending';

  /// en: 'Completed'
  String get succeeded => 'Completed';

  /// en: 'Failed'
  String get failed => 'Failed';

  /// en: 'Canceled'
  String get canceled => 'Canceled';

  /// en: 'Retry unfinished'
  String get retry => 'Retry unfinished';

  /// en: '{n} file(s)'
  String files({required Object n}) => '${n} file(s)';

  /// en: 'Drop to send to {device}'
  String drop({required Object device}) => 'Drop to send to ${device}';

  /// en: 'Queued {n} file(s) for {device}'
  String added({required Object n, required Object device}) => 'Queued ${n} file(s) for ${device}';
}

// Path: transferActivity
class Translations$transferActivity$en {
  Translations$transferActivity$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Transfers'
  String get title => 'Transfers';

  /// en: 'Sending'
  String get send => 'Sending';

  /// en: 'Receiving'
  String get receive => 'Receiving';

  /// en: 'No tasks in this direction'
  String get empty => 'No tasks in this direction';

  /// en: 'Preparing / verifying'
  String get preparing => 'Preparing / verifying';

  /// en: 'Waiting for confirmation'
  String get waiting => 'Waiting for confirmation';

  /// en: 'Transferring'
  String get transferring => 'Transferring';

  /// en: 'Dismiss completed notices'
  String get acknowledge => 'Dismiss completed notices';

  /// en: 'Task details'
  String get details => 'Task details';

  /// en: 'Back to tasks'
  String get back => 'Back to tasks';

  /// en: 'This task has ended or was removed.'
  String get ended => 'This task has ended or was removed.';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'Accept selected files'
  String get accept => 'Accept selected files';

  /// en: 'Decline request'
  String get decline => 'Decline request';

  /// en: 'Failed'
  String get failed => 'Failed';

  /// en: 'Completed'
  String get succeeded => 'Completed';

  /// en: 'Waiting to retry'
  String get recoveryWaiting => 'Waiting to retry';

  /// en: 'Retry available'
  String get recoveryRetryable => 'Retry available';

  /// en: 'Authorization required'
  String get recoveryAuthorization => 'Authorization required';

  /// en: 'Source changed · create a new send'
  String get recoverySourceChanged => 'Source changed · create a new send';

  /// en: 'Recovery response not verified'
  String get recoveryInvalidResponse => 'Recovery response not verified';

  /// en: 'Partial data retained'
  String get recoveryRetained => 'Partial data retained';

  /// en: 'Retention unconfirmed'
  String get recoveryRetentionUnknown => 'Retention unconfirmed';

  /// en: 'No reusable checkpoint'
  String get recoveryNotRetained => 'No reusable checkpoint';

  /// en: 'Waiting to reconnect'
  String get retrying => 'Waiting to reconnect';

  /// en: 'Source no longer available'
  String get sourceEnded => 'Source no longer available';
}

// Path: webPreview
class Translations$webPreview$en {
  Translations$webPreview$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Preview'
  String get preview => 'Preview';

  /// en: 'Close preview'
  String get closePreview => 'Close preview';

  /// en: 'Download original'
  String get downloadOriginal => 'Download original';

  /// en: 'Loading preview…'
  String get previewLoading => 'Loading preview…';

  /// en: 'Preview failed. Download the original file to open it.'
  String get previewError => 'Preview failed. Download the original file to open it.';

  /// en: 'This browser or file format does not support preview.'
  String get previewUnsupported => 'This browser or file format does not support preview.';

  /// en: 'Zoom in'
  String get imageZoomIn => 'Zoom in';

  /// en: 'Zoom out'
  String get imageZoomOut => 'Zoom out';

  /// en: 'Fit'
  String get imageFit => 'Fit';

  /// en: 'Actual size'
  String get imageActual => 'Actual size';

  /// en: 'Image preview'
  String get imageView => 'Image preview';

  /// en: 'Zoom'
  String get imageScale => 'Zoom';

  /// en: 'Drag to pan. Pinch or Ctrl/⌘ + wheel to zoom. Keyboard: +/−, arrows, 0 to fit, 1 for actual size.'
  String get imageHint => 'Drag to pan. Pinch or Ctrl/⌘ + wheel to zoom. Keyboard: +/−, arrows, 0 to fit, 1 for actual size.';
}

// Path: webTextPreview
class Translations$webTextPreview$en {
  Translations$webTextPreview$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Encoding'
  String get encoding => 'Encoding';

  /// en: 'Auto (BOM / UTF-8)'
  String get auto => 'Auto (BOM / UTF-8)';

  /// en: 'Previous section'
  String get previous => 'Previous section';

  /// en: 'Next section'
  String get next => 'Next section';

  /// en: 'Load more'
  String get more => 'Load more';

  /// en: 'Reload preview'
  String get retry => 'Reload preview';

  /// en: 'Indexed'
  String get indexed => 'Indexed';

  /// en: 'Lines'
  String get lines => 'Lines';

  /// en: 'Section'
  String get section => 'Section';

  /// en: 'End of file'
  String get complete => 'End of file';

  /// en: 'Loading text…'
  String get loading => 'Loading text…';

  /// en: 'Text preview'
  String get view => 'Text preview';

  /// en: 'This source does not support bounded text reads. Download the original file.'
  String get range => 'This source does not support bounded text reads. Download the original file.';

  /// en: 'The shared file changed. Reopen the share before previewing it.'
  String get changed => 'The shared file changed. Reopen the share before previewing it.';

  /// en: 'Invalid text encoding. Choose another encoding or download the original file.'
  String get decode => 'Invalid text encoding. Choose another encoding or download the original file.';

  /// en: 'Text could not be loaded. Check the connection and reload the preview.'
  String get failed => 'Text could not be loaded. Check the connection and reload the preview.';

  /// en: 'This browser does not support streaming text preview.'
  String get unsupported => 'This browser does not support streaming text preview.';

  /// en: 'Only visible rows and a small buffer are rendered. Wrapping keeps long text within the page.'
  String get hint => 'Only visible rows and a small buffer are rendered. Wrapping keeps long text within the page.';

  /// en: 'Wrap text'
  String get wrap => 'Wrap text';

  /// en: 'Line numbers'
  String get numbers => 'Line numbers';

  /// en: 'Search content'
  String get search => 'Search content';

  /// en: 'Search scope'
  String get searchScope => 'Search scope';

  /// en: 'Indexed content'
  String get loaded => 'Indexed content';

  /// en: 'Entire file'
  String get full => 'Entire file';

  /// en: 'Find'
  String get find => 'Find';

  /// en: 'Stop search'
  String get stop => 'Stop search';

  /// en: 'Match case'
  String get caseSensitive => 'Match case';

  /// en: 'Previous match'
  String get previousMatch => 'Previous match';

  /// en: 'Next match'
  String get nextMatch => 'Next match';

  /// en: 'Matches'
  String get matches => 'Matches';

  /// en: 'Scanned'
  String get scanned => 'Scanned';

  /// en: 'Searching…'
  String get searching => 'Searching…';

  /// en: 'Search complete'
  String get searchDone => 'Search complete';

  /// en: 'Search stopped'
  String get searchStopped => 'Search stopped';

  /// en: 'No matches in scanned content'
  String get noMatches => 'No matches in scanned content';

  /// en: 'First 1,000 matches shown. Refine the query to search further.'
  String get searchLimit => 'First 1,000 matches shown. Refine the query to search further.';

  /// en: 'Clear search'
  String get clearSearch => 'Clear search';

  /// en: 'Reading view'
  String get rendered => 'Reading view';

  /// en: 'Source'
  String get source => 'Source';

  /// en: 'Markdown search covers source text; results open at the exact source position.'
  String get markdownHint => 'Markdown search covers source text; results open at the exact source position.';

  /// en: 'Complete blocks load by section. Reference links update as their definitions are indexed.'
  String get markdownLimit => 'Complete blocks load by section. Reference links update as their definitions are indexed.';

  /// en: 'Formatting is unavailable for this document. The source reader remains available.'
  String get markdownFailed => 'Formatting is unavailable for this document. The source reader remains available.';

  /// en: 'Diagram · loads near the viewport'
  String get diagramQueued => 'Diagram · loads near the viewport';

  /// en: 'Rendering diagram…'
  String get diagramLoading => 'Rendering diagram…';

  /// en: 'Diagram'
  String get diagramReady => 'Diagram';

  /// en: 'This diagram could not be rendered. Read its source or try again.'
  String get diagramFailed => 'This diagram could not be rendered. Read its source or try again.';

  /// en: 'This diagram exceeds the preview limit. Its source is still available.'
  String get diagramLimit => 'This diagram exceeds the preview limit. Its source is still available.';

  /// en: 'Source'
  String get diagramSource => 'Source';

  /// en: 'Diagram'
  String get diagramRender => 'Diagram';

  /// en: 'Try again'
  String get diagramRetry => 'Try again';

  /// en: 'Fit'
  String get diagramFit => 'Fit';

  /// en: 'Zoom in'
  String get diagramZoomIn => 'Zoom in';

  /// en: 'Zoom out'
  String get diagramZoomOut => 'Zoom out';

  /// en: 'Expand all'
  String get diagramExpand => 'Expand all';

  /// en: 'Collapse branches'
  String get diagramCollapse => 'Collapse branches';

  /// en: 'Drag to pan. Use buttons or Ctrl/⌘ + wheel to zoom.'
  String get diagramHint => 'Drag to pan. Use buttons or Ctrl/⌘ + wheel to zoom.';

  /// en: 'Diagram rendering is unavailable in this browser. The source is shown.'
  String get diagramUnavailable => 'Diagram rendering is unavailable in this browser. The source is shown.';

  /// en: 'Complete blocks load by section. Reference links update as their definitions are indexed.'
  String get markdownStreaming => 'Complete blocks load by section. Reference links update as their definitions are indexed.';

  /// en: 'Very large paragraph · complete source in reading windows; cross-window inline formatting stays literal.'
  String get markdownParagraphSource => 'Very large paragraph · complete source in reading windows; cross-window inline formatting stays literal.';

  /// en: 'This syntax block exceeds the reading budget. Use Source to continue without truncation.'
  String get markdownBlockLimit => 'This syntax block exceeds the reading budget. Use Source to continue without truncation.';

  /// en: 'Index references'
  String get markdownScan => 'Index references';

  /// en: 'Stop indexing'
  String get markdownStop => 'Stop indexing';

  /// en: 'Large syntax block · complete source in reading windows; formatting that crosses windows stays literal.'
  String get markdownSourceWindow => 'Large syntax block · complete source in reading windows; formatting that crosses windows stays literal.';
}

// Path: transportSecurity
class Translations$transportSecurity$en {
  Translations$transportSecurity$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'HTTPS transport (TLS)'
  String get title => 'HTTPS transport (TLS)';

  /// en: 'Protects data while it travels between devices. This does not encrypt saved files or add a file password.'
  String get description => 'Protects data while it travels between devices. This does not encrypt saved files or add a file password.';

  /// en: 'LegnaSend uses a locally generated, self-signed TLS certificate. Your browser may show a certificate trust prompt for this device.'
  String get certificate =>
      'LegnaSend uses a locally generated, self-signed TLS certificate. Your browser may show a certificate trust prompt for this device.';

  /// en: 'Using HTTP transport'
  String get httpTitle => 'Using HTTP transport';

  /// en: 'HTTPS transport is off. Data is transferred using HTTP without TLS protection. Enable HTTPS transport (TLS) to protect the connection; saved files are unchanged.'
  String get httpDescription =>
      'HTTPS transport is off. Data is transferred using HTTP without TLS protection. Enable HTTPS transport (TLS) to protect the connection; saved files are unchanged.';

  /// en: 'Check network reachability, discovery port and multicast settings, and the HTTP/HTTPS configuration. If discovery fails, try the target IP and its actual server port.'
  String get discoveryHint =>
      'Check network reachability, discovery port and multicast settings, and the HTTP/HTTPS configuration. If discovery fails, try the target IP and its actual server port.';

  /// en: 'Check that the target IP and actual server port are reachable and that HTTP/HTTPS settings are compatible. Wi-Fi access point isolation or a firewall can prevent devices from communicating.'
  String get connectionHint =>
      'Check that the target IP and actual server port are reachable and that HTTP/HTTPS settings are compatible. Wi-Fi access point isolation or a firewall can prevent devices from communicating.';

  /// en: 'Transport could not be changed. Check the current service state and retry.'
  String get updateFailed => 'Transport could not be changed. Check the current service state and retry.';

  /// en: 'Peer · {protocol}'
  String peerProtocol({required Object protocol}) => 'Peer · ${protocol}';
}

// Path: transferSpeed
class Translations$transferSpeed$en {
  Translations$transferSpeed$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Current speed: {speed}'
  String current({required Object speed}) => 'Current speed: ${speed}';

  /// en: 'Average speed: {speed}'
  String average({required Object speed}) => 'Average speed: ${speed}';

  /// en: 'Measuring speed…'
  String get measuring => 'Measuring speed…';
}

// Path: transferNavigation
class Translations$transferNavigation$en {
  Translations$transferNavigation$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Hide panel'
  String get hide => 'Hide panel';

  /// en: 'Back and hide keep transfers running.'
  String get keepRunning => 'Back and hide keep transfers running.';

  /// en: 'Link sharing active'
  String get sharing => 'Link sharing active';

  /// en: 'Back hides this page. Link sharing stays active; reopen it from the sharing badge.'
  String get keepSharing => 'Back hides this page. Link sharing stays active; reopen it from the sharing badge.';

  /// en: 'Stop link sharing'
  String get stopSharing => 'Stop link sharing';

  /// en: 'Stop link sharing?'
  String get stopTitle => 'Stop link sharing?';

  /// en: 'End temporary-link download sessions and stop new browser uploads. Directory workspaces, the listener, API and approved native transfers stay active.'
  String get stopBody =>
      'End temporary-link download sessions and stop new browser uploads. Directory workspaces, the listener, API and approved native transfers stay active.';

  /// en: 'Restart the sharing service?'
  String get restartTitle => 'Restart the sharing service?';

  /// en: 'Changing HTTP/HTTPS restarts the shared listener and interrupts its active connections. Workspace definitions and temporary files remain configured.'
  String get restartBody =>
      'Changing HTTP/HTTPS restarts the shared listener and interrupts its active connections. Workspace definitions and temporary files remain configured.';

  /// en: 'No active share'
  String get unknown => 'No active share';

  /// en: 'Replace temporary-share access?'
  String get replaceTitle => 'Replace temporary-share access?';

  /// en: 'Only this temporary share’s download sessions will end. Directory workspaces and native transfers stay active.'
  String get replaceBody => 'Only this temporary share’s download sessions will end. Directory workspaces and native transfers stay active.';
}

// Path: networkEnvironment
class Translations$networkEnvironment$en {
  Translations$networkEnvironment$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System VPN'
  String get vpn => 'System VPN';

  /// en: 'VPN/tunnel interface'
  String get tunnel => 'VPN/tunnel interface';

  /// en: 'Local interface'
  String get local => 'Local interface';

  /// en: 'System proxy'
  String get proxy => 'System proxy';

  /// en: 'Network paths'
  String get title => 'Network paths';

  /// en: 'Unknown'
  String get unknown => 'Unknown';

  /// en: 'Detected'
  String get detected => 'Detected';

  /// en: 'Not detected'
  String get notDetected => 'Not detected';

  /// en: 'Local addresses and VPN/tunnel addresses are listed separately. Actual reachability follows both devices’ system routes and VPN rules. Native peer requests ignore application HTTP proxies, not system VPN routing. A tunnel name is only an interface hint; no route bypass has been verified.'
  String get routeHint =>
      'Local addresses and VPN/tunnel addresses are listed separately. Actual reachability follows both devices’ system routes and VPN rules. Native peer requests ignore application HTTP proxies, not system VPN routing. A tunnel name is only an interface hint; no route bypass has been verified.';
}

// Path: linkWorkspace
class Translations$linkWorkspace$en {
  Translations$linkWorkspace$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Link workspace'
  String get title => 'Link workspace';

  /// en: 'Shared files: {n}'
  String sharedCount({required Object n}) => 'Shared files: ${n}';

  /// en: 'Allow browser uploads'
  String get allowUpload => 'Allow browser uploads';

  /// en: 'Controls new browser requests. Approved transfers continue; each new request still follows your receive-confirmation settings.'
  String get allowUploadHint =>
      'Controls new browser requests. Approved transfers continue; each new request still follows your receive-confirmation settings.';

  /// en: 'Automatically accept browser uploads'
  String get autoReceive => 'Automatically accept browser uploads';

  /// en: 'Automatically approve browser downloads'
  String get autoDownload => 'Automatically approve browser downloads';

  /// en: 'Added files stay in this workspace. Existing file links and approved sessions remain valid.'
  String get appendHint => 'Added files stay in this workspace. Existing file links and approved sessions remain valid.';
}

// Path: integrationApi
class Translations$integrationApi$en {
  Translations$integrationApi$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'API'
  String get title => 'API';

  /// en: 'Local integrations, on your existing sharing port.'
  String get subtitle => 'Local integrations, on your existing sharing port.';

  /// en: 'Enable API'
  String get enable => 'Enable API';

  /// en: 'Require an API key'
  String get requireKey => 'Require an API key';

  /// en: 'API controls do not stop native transfers or browser workspaces.'
  String get isolation => 'API controls do not stop native transfers or browser workspaces.';

  /// en: 'Active'
  String get live => 'Active';

  /// en: 'Disabled'
  String get off => 'Disabled';

  /// en: 'Saved · waiting for service'
  String get waiting => 'Saved · waiting for service';

  /// en: 'Applying policy…'
  String get syncing => 'Applying policy…';

  /// en: 'Previous policy may still be active'
  String get previous => 'Previous policy may still be active';

  /// en: 'The change could not be saved or applied. Retry below.'
  String get failed => 'The change could not be saved or applied. Retry below.';

  /// en: 'Stored API settings need recovery. The original data is preserved; retry loading or explicitly reset.'
  String get corrupt => 'Stored API settings need recovery. The original data is preserved; retry loading or explicitly reset.';

  /// en: 'Reset API settings'
  String get reset => 'Reset API settings';

  /// en: 'Remove all API keys and restore disabled defaults. Native transfers and workspace files are preserved.'
  String get resetHint => 'Remove all API keys and restore disabled defaults. Native transfers and workspace files are preserved.';

  /// en: 'Refresh status'
  String get refresh => 'Refresh status';

  /// en: 'Start receiving service'
  String get startService => 'Start receiving service';

  /// en: 'Service addresses'
  String get addresses => 'Service addresses';

  /// en: 'Use the actual address and trust the device certificate for HTTPS. Network tags describe interfaces, not a verified VPN bypass.'
  String get addressHint =>
      'Use the actual address and trust the device certificate for HTTPS. Network tags describe interfaces, not a verified VPN bypass.';

  /// en: 'Access and limits'
  String get policy => 'Access and limits';

  /// en: 'Edit policy'
  String get editPolicy => 'Edit policy';

  /// en: 'Second and minute fixed windows apply together. Concurrency counts active responses, not connections or bandwidth. 0 disables only that quota; server resource ceilings still apply.'
  String get fixedWindow =>
      'Second and minute fixed windows apply together. Concurrency counts active responses, not connections or bandwidth. 0 disables only that quota; server resource ceilings still apply.';

  /// en: 'Global'
  String get global => 'Global';

  /// en: 'Each key'
  String get perKey => 'Each key';

  /// en: 'Anonymous peer'
  String get anonymous => 'Anonymous peer';

  /// en: 'Requests / second'
  String get second => 'Requests / second';

  /// en: 'Requests / minute'
  String get minute => 'Requests / minute';

  /// en: 'Active responses'
  String get concurrent => 'Active responses';

  /// en: 'Allowed cross-origin sites'
  String get origins => 'Allowed cross-origin sites';

  /// en: 'One canonical http(s) origin per line, without a path. Same-origin calls remain allowed.'
  String get originsHint => 'One canonical http(s) origin per line, without a path. Same-origin calls remain allowed.';

  /// en: 'Without a key, only assigned visible, unprotected workspaces are readable. Hidden/protected workspaces and request history stay closed. An invalid key never falls back to anonymous.'
  String get anonymousHint =>
      'Without a key, only assigned visible, unprotected workspaces are readable. Hidden/protected workspaces and request history stay closed. An invalid key never falls back to anonymous.';

  /// en: 'Allow anonymous access?'
  String get allowAnonymous => 'Allow anonymous access?';

  /// en: 'Stop integration API responses only. Other shares and original LocalSend transfers continue.'
  String get disableHint => 'Stop integration API responses only. Other shares and original LocalSend transfers continue.';

  /// en: 'API keys'
  String get keys => 'API keys';

  /// en: 'Generate key'
  String get createKey => 'Generate key';

  /// en: 'Key name'
  String get keyName => 'Key name';

  /// en: 'No API keys yet.'
  String get empty => 'No API keys yet.';

  /// en: 'Copy this key now'
  String get once => 'Copy this key now';

  /// en: 'The plaintext is shown only here and is not saved. This reusable key works until revoked or expired. Closing this dialog does not copy it automatically.'
  String get onceHint =>
      'The plaintext is shown only here and is not saved. This reusable key works until revoked or expired. Closing this dialog does not copy it automatically.';

  /// en: 'Revoke key'
  String get revoke => 'Revoke key';

  /// en: 'Revoke this key and end its active API responses. Other keys and native transfers continue.'
  String get revokeHint => 'Revoke this key and end its active API responses. Other keys and native transfers continue.';

  /// en: 'Saved · not confirmed active'
  String get pendingKey => 'Saved · not confirmed active';

  /// en: 'A removed key may still be live until the pending policy is applied. Retry the update.'
  String get removedLive => 'A removed key may still be live until the pending policy is applied. Retry the update.';

  /// en: 'Permissions'
  String get permissions => 'Permissions';

  /// en: 'Service status and contract'
  String get scopeService => 'Service status and contract';

  /// en: 'Workspace descriptors'
  String get scopeWorkspaces => 'Workspace descriptors';

  /// en: 'File listing and download'
  String get scopeFiles => 'File listing and download';

  /// en: 'Global redacted request history'
  String get scopeRequests => 'Global redacted request history';

  /// en: 'All current and future workspaces'
  String get allWorkspaces => 'All current and future workspaces';

  /// en: 'Workspace access'
  String get selectWorkspaces => 'Workspace access';

  /// en: 'Grant only required actions and workspaces. Upload and workspace management are separate opt-in permissions; existing/default keys remain read-only.'
  String get grantHint =>
      'Grant only required actions and workspaces. Upload and workspace management are separate opt-in permissions; existing/default keys remain read-only.';

  /// en: 'Expiration'
  String get expiry => 'Expiration';

  /// en: '30 days'
  String get days30 => '30 days';

  /// en: '90 days'
  String get days90 => '90 days';

  /// en: 'No expiry'
  String get never => 'No expiry';

  /// en: 'Expired'
  String get expired => 'Expired';

  /// en: 'Check the name, limits, origins and selected permissions/workspaces.'
  String get invalid => 'Check the name, limits, origins and selected permissions/workspaces.';

  /// en: 'Copy'
  String get copy => 'Copy';

  /// en: 'Copied'
  String get copied => 'Copied';

  /// en: 'Done'
  String get close => 'Done';

  /// en: 'Next keys'
  String get more => 'Next keys';

  /// en: 'Previous keys'
  String get previousPage => 'Previous keys';

  /// en: 'Read + explicitly granted writes'
  String get readOnly => 'Read + explicitly granted writes';

  /// en: 'Explicit keys can upload, manage workspaces from locally approved sources, and discover devices or control their own API-created send tasks. General cache/settings APIs and unrelated native-task control remain planned.'
  String get nextStage =>
      'Explicit keys can upload, manage workspaces from locally approved sources, and discover devices or control their own API-created send tasks. General cache/settings APIs and unrelated native-task control remain planned.';

  /// en: 'Copy failed. Select the text and copy it manually.'
  String get copyFailed => 'Copy failed. Select the text and copy it manually.';

  /// en: 'Updated'
  String get updated => 'Updated';

  /// en: 'Awaiting service acknowledgement'
  String get unconfirmed => 'Awaiting service acknowledgement';

  /// en: 'API text is shown in English.'
  String get fallback => 'API text is shown in English.';

  /// en: 'Developer documentation'
  String get documentation => 'Developer documentation';

  /// en: 'Directory contract'
  String get directoryContract => 'Directory contract';

  /// en: 'Offline guide: setup, permissions, every endpoint, parameters, errors, retries and cURL / JavaScript / Python examples.'
  String get documentationHint =>
      'Offline guide: setup, permissions, every endpoint, parameters, errors, retries and cURL / JavaScript / Python examples.';

  /// en: 'Upload files (explicit write access)'
  String get scopeUpload => 'Upload files (explicit write access)';

  /// en: 'Manage workspace metadata and sharing'
  String get scopeManage => 'Manage workspace metadata and sharing';
}

// Path: apiExplorer
class Translations$apiExplorer$en {
  Translations$apiExplorer$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'API explorer'
  String get title => 'API explorer';

  /// en: 'Search endpoints or descriptions'
  String get search => 'Search endpoints or descriptions';

  /// en: 'Execute request'
  String get execute => 'Execute request';

  /// en: 'Requests use the actual local listener and its authentication/quotas. Reads allow 12 seconds, workspace operations 35 seconds, and uploads a size-based budget. Requests and credentials are not saved.'
  String get hint =>
      'Requests use the actual local listener and its authentication/quotas. Reads allow 12 seconds, workspace operations 35 seconds, and uploads a size-based budget. Requests and credentials are not saved.';

  /// en: 'All'
  String get all => 'All';

  /// en: 'Service'
  String get service => 'Service';

  /// en: 'Workspaces'
  String get workspaces => 'Workspaces';

  /// en: 'Files'
  String get files => 'Files';

  /// en: 'Request history'
  String get history => 'Request history';

  /// en: 'No matching endpoints'
  String get noResults => 'No matching endpoints';

  /// en: 'Read only'
  String get readOnly => 'Read only';

  /// en: 'API key (optional)'
  String get token => 'API key (optional)';

  /// en: 'Paste a generated key, or leave empty to test anonymous access. Kept only while this page is open; never inserted into examples.'
  String get tokenHint =>
      'Paste a generated key, or leave empty to test anonymous access. Kept only while this page is open; never inserted into examples.';

  /// en: 'Clear credential'
  String get clear => 'Clear credential';

  /// en: 'Running…'
  String get running => 'Running…';

  /// en: 'Reset parameters'
  String get reset => 'Reset parameters';

  /// en: 'Check required fields and parameter limits.'
  String get invalid => 'Check required fields and parameter limits.';

  /// en: 'The request failed or the service changed. Retry against the current listener.'
  String get failed => 'The request failed or the service changed. Retry against the current listener.';

  /// en: 'Response headers'
  String get headers => 'Response headers';

  /// en: 'Response body'
  String get response => 'Response body';

  /// en: 'Body capped at 256 KiB (binary sample: 4 KiB). This is not a complete download.'
  String get truncated => 'Body capped at 256 KiB (binary sample: 4 KiB). This is not a complete download.';

  /// en: 'Hexadecimal file sample, not a saved file. Default Range is bytes=0-4095.'
  String get binary => 'Hexadecimal file sample, not a saved file. Default Range is bytes=0-4095.';

  /// en: 'Call examples'
  String get examples => 'Call examples';

  /// en: 'Response contracts'
  String get responses => 'Response contracts';

  /// en: 'Data models'
  String get schemas => 'Data models';
}

// Path: sharedFileManagement
class Translations$sharedFileManagement$en {
  Translations$sharedFileManagement$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Shared files'
  String get title => 'Shared files';

  /// en: 'Withdraw or replace files without closing sharing. Other files and receiving tasks continue.'
  String get hint => 'Withdraw or replace files without closing sharing. Other files and receiving tasks continue.';

  /// en: 'Search shared files'
  String get search => 'Search shared files';

  /// en: 'Withdraw file'
  String get withdraw => 'Withdraw file';

  /// en: 'Replace file'
  String get replace => 'Replace file';

  /// en: 'This stops pending and active downloads of this file only. A replacement receives a new link; old downloads cannot resume into it. Source files are not deleted.'
  String get confirmBody =>
      'This stops pending and active downloads of this file only. A replacement receives a new link; old downloads cannot resume into it. Source files are not deleted.';

  /// en: 'Choose exactly one replacement file.'
  String get selectOne => 'Choose exactly one replacement file.';

  /// en: 'The share or file changed. Reopen file management and try again.'
  String get changed => 'The share or file changed. Reopen file management and try again.';

  /// en: 'Shared files updated.'
  String get applied => 'Shared files updated.';

  /// en: 'The update was not confirmed. The previous list is retained; retry or reopen sharing.'
  String get failed => 'The update was not confirmed. The previous list is retained; retry or reopen sharing.';

  /// en: 'No matching shared files.'
  String get empty => 'No matching shared files.';

  /// en: 'Previous page'
  String get previous => 'Previous page';

  /// en: 'Next page'
  String get next => 'Next page';
}

// Path: receiveTab.infoBox
class Translations$receiveTab$infoBox$en {
  Translations$receiveTab$infoBox$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'IP:'
  String get ip => 'IP:';

  /// en: 'Port:'
  String get port => 'Port:';

  /// en: 'Device name:'
  String get alias => 'Device name:';
}

// Path: receiveTab.quickSave
class Translations$receiveTab$quickSave$en {
  Translations$receiveTab$quickSave$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Off'
  String get off => _root.general.off;

  /// en: 'Favorites'
  String get favorites => 'Favorites';

  /// en: 'On'
  String get on => _root.general.on;
}

// Path: sendTab.selection
class Translations$sendTab$selection$en {
  Translations$sendTab$selection$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Selection'
  String get title => 'Selection';

  /// en: 'Files: {files}'
  String files({required Object files}) => 'Files: ${files}';

  /// en: 'Size: {size}'
  String size({required Object size}) => 'Size: ${size}';
}

// Path: sendTab.picker
class Translations$sendTab$picker$en {
  Translations$sendTab$picker$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'File'
  String get file => 'File';

  /// en: 'Folder'
  String get folder => 'Folder';

  /// en: 'Media'
  String get media => 'Media';

  /// en: 'Text'
  String get text => 'Text';

  /// en: 'App'
  String get app => 'App';

  /// en: 'Paste'
  String get clipboard => 'Paste';
}

// Path: sendTab.sendModes
class Translations$sendTab$sendModes$en {
  Translations$sendTab$sendModes$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Single recipient'
  String get single => 'Single recipient';

  /// en: 'Multiple recipients'
  String get multiple => 'Multiple recipients';

  /// en: 'Share via link'
  String get link => 'Share via link';
}

// Path: settingsTab.general
class Translations$settingsTab$general$en {
  Translations$settingsTab$general$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'General'
  String get title => 'General';

  /// en: 'Theme'
  String get brightness => 'Theme';

  late final Translations$settingsTab$general$brightnessOptions$en brightnessOptions = Translations$settingsTab$general$brightnessOptions$en.internal(
    _root,
  );

  /// en: 'Color'
  String get color => 'Color';

  late final Translations$settingsTab$general$colorOptions$en colorOptions = Translations$settingsTab$general$colorOptions$en.internal(_root);

  /// en: 'Language'
  String get language => 'Language';

  late final Translations$settingsTab$general$languageOptions$en languageOptions = Translations$settingsTab$general$languageOptions$en.internal(
    _root,
  );

  /// en: 'Save window position after quit'
  String get saveWindowPlacement => 'Save window position after quit';

  /// en: 'Save window position after exit'
  String get saveWindowPlacementWindows => 'Save window position after exit';

  /// en: 'Minimize to the System Tray/Menu Bar when closing'
  String get minimizeToTray => 'Minimize to the System Tray/Menu Bar when closing';

  /// en: 'Autostart after login'
  String get launchAtStartup => 'Autostart after login';

  /// en: 'Autostart: Start hidden'
  String get launchMinimized => 'Autostart: Start hidden';

  /// en: 'Show LocalSend in context menu'
  String get showInContextMenu => 'Show LocalSend in context menu';

  /// en: 'Animations'
  String get animations => 'Animations';
}

// Path: settingsTab.receive
class Translations$settingsTab$receive$en {
  Translations$settingsTab$receive$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Receive'
  String get title => 'Receive';

  /// en: 'Quick Save'
  String get quickSave => _root.general.quickSave;

  /// en: 'Quick Save for "Favorites"'
  String get quickSaveFromFavorites => _root.general.quickSaveFromFavorites;

  /// en: 'Require PIN'
  String get requirePin => _root.webSharePage.requirePin;

  /// en: 'Auto Finish'
  String get autoFinish => 'Auto Finish';

  /// en: 'Save to folder'
  String get destination => 'Save to folder';

  /// en: '(Downloads)'
  String get downloads => '(Downloads)';

  /// en: 'Save media to gallery'
  String get saveToGallery => 'Save media to gallery';

  /// en: 'Save to history'
  String get saveToHistory => 'Save to history';

  /// en: 'Verify checksums when receiving files'
  String get verifyChecksums => 'Verify checksums when receiving files';
}

// Path: settingsTab.send
class Translations$settingsTab$send$en {
  Translations$settingsTab$send$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send'
  String get title => 'Send';

  /// en: 'Automatically accept requests in "Share via link" mode'
  String get shareViaLinkAutoAccept => 'Automatically accept requests in "Share via link" mode';

  /// en: 'Create checksums when sending files'
  String get createChecksums => 'Create checksums when sending files';
}

// Path: settingsTab.network
class Translations$settingsTab$network$en {
  Translations$settingsTab$network$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Network'
  String get title => 'Network';

  /// en: 'Restart the server to apply the settings!'
  String get needRestart => 'Restart the server to apply the settings!';

  /// en: 'Server'
  String get server => 'Server';

  /// en: 'Device name'
  String get alias => 'Device name';

  /// en: 'Device type'
  String get deviceType => 'Device type';

  /// en: 'Device model'
  String get deviceModel => 'Device model';

  /// en: 'Port'
  String get port => 'Port';

  /// en: 'Network'
  String get network => 'Network';

  late final Translations$settingsTab$network$networkOptions$en networkOptions = Translations$settingsTab$network$networkOptions$en.internal(_root);

  /// en: 'Discovery Timeout'
  String get discoveryTimeout => 'Discovery Timeout';

  /// en: 'Use system name'
  String get useSystemName => 'Use system name';

  /// en: 'Generate random alias'
  String get generateRandomAlias => 'Generate random alias';

  /// en: 'You might not be detected by other devices because you are using a custom port. (default: {defaultPort})'
  String portWarning({required Object defaultPort}) =>
      'You might not be detected by other devices because you are using a custom port. (default: ${defaultPort})';

  /// en: 'Encryption'
  String get encryption => 'Encryption';

  /// en: 'Multicast address'
  String get multicastGroup => 'Multicast address';

  /// en: 'You might not be detected by other devices because you are using a custom multicast address. (default: {defaultMulticast})'
  String multicastGroupWarning({required Object defaultMulticast}) =>
      'You might not be detected by other devices because you are using a custom multicast address. (default: ${defaultMulticast})';
}

// Path: settingsTab.other
class Translations$settingsTab$other$en {
  Translations$settingsTab$other$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Other'
  String get title => 'Other';

  /// en: 'Support LocalSend'
  String get support => 'Support LocalSend';

  /// en: 'Donate'
  String get donate => 'Donate';

  /// en: 'Privacy Policy'
  String get privacyPolicy => 'Privacy Policy';

  /// en: 'Terms of Use'
  String get termsOfUse => 'Terms of Use';
}

// Path: troubleshootPage.firewall
class Translations$troubleshootPage$firewall$en {
  Translations$troubleshootPage$firewall$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'This device can send files to other devices but other devices cannot send files to this device.'
  String get symptom => 'This device can send files to other devices but other devices cannot send files to this device.';

  /// en: 'This is most likely a firewall issue. You can solve this by allowing incoming connections (UDP and TCP) on port {port}.'
  String solution({required Object port}) =>
      'This is most likely a firewall issue. You can solve this by allowing incoming connections (UDP and TCP) on port ${port}.';

  /// en: 'Open Firewall'
  String get openFirewall => 'Open Firewall';
}

// Path: troubleshootPage.noDiscovery
class Translations$troubleshootPage$noDiscovery$en {
  Translations$troubleshootPage$noDiscovery$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'This device cannot discover other devices.'
  String get symptom => 'This device cannot discover other devices.';

  /// en: 'Please make sure that all devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). You can try to type the IP address of the target device manually. If this works, consider adding this device to the favorites so it can be automatically discovered in the future.'
  String get solution =>
      'Please make sure that all devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). You can try to type the IP address of the target device manually. If this works, consider adding this device to the favorites so it can be automatically discovered in the future.';
}

// Path: troubleshootPage.noConnection
class Translations$troubleshootPage$noConnection$en {
  Translations$troubleshootPage$noConnection$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Both devices cannot discover each other nor can they share files.'
  String get symptom => 'Both devices cannot discover each other nor can they share files.';

  /// en: 'Does the problem exist on both sides? If so, you need to make sure that both devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). The Wi-Fi network may not allow communication between participants due to Access Point (AP) Isolation. In this case, this option must be disabled on the router.'
  String get solution =>
      'Does the problem exist on both sides? If so, you need to make sure that both devices are on the same Wi-Fi network and share the same configuration (port, multicast address, encryption). The Wi-Fi network may not allow communication between participants due to Access Point (AP) Isolation. In this case, this option must be disabled on the router.';
}

// Path: receiveHistoryPage.entryActions
class Translations$receiveHistoryPage$entryActions$en {
  Translations$receiveHistoryPage$entryActions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open file'
  String get open => 'Open file';

  /// en: 'Show in folder'
  String get showInFolder => 'Show in folder';

  /// en: 'Information'
  String get info => 'Information';

  /// en: 'Delete from history'
  String get deleteFromHistory => 'Delete from history';
}

// Path: deviceDetailsPage.info
class Translations$deviceDetailsPage$info$en {
  Translations$deviceDetailsPage$info$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Name'
  String get name => 'Name';

  /// en: 'Address'
  String get address => 'Address';

  /// en: 'Version'
  String get version => 'Version';

  /// en: 'Protocol v{version}'
  String protocol({required Object version}) => 'Protocol v${version}';
}

// Path: deviceDetailsPage.logs
class Translations$deviceDetailsPage$logs$en {
  Translations$deviceDetailsPage$logs$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Logs'
  String get title => 'Logs';

  /// en: 'No logs available.'
  String get empty => 'No logs available.';

  /// en: 'Discovered via {protocol} ({host})'
  String discovered({required Object protocol, required Object host}) => 'Discovered via ${protocol} (${host})';

  /// en: 'Updated via {protocol} ({host})'
  String updated({required Object protocol, required Object host}) => 'Updated via ${protocol} (${host})';
}

// Path: progressPage.total
class Translations$progressPage$total$en {
  Translations$progressPage$total$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$progressPage$total$title$en title = Translations$progressPage$total$title$en.internal(_root);

  /// en: 'Files: {curr} / {n}'
  String count({required Object curr, required Object n}) => 'Files: ${curr} / ${n}';

  /// en: 'Size: {curr} / {n}'
  String size({required Object curr, required Object n}) => 'Size: ${curr} / ${n}';

  /// en: 'Speed: {speed}/s'
  String speed({required Object speed}) => 'Speed: ${speed}/s';
}

// Path: progressPage.remainingTime
class Translations$progressPage$remainingTime$en {
  Translations$progressPage$remainingTime$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: '(other) {{m}m}'
  String minutesUnit({required num m}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    m,
    other: '${m}m',
  );

  /// en: '(other) {{h}h}'
  String hoursUnit({required num h}) => (_root.$meta.cardinalResolver ?? PluralResolvers.cardinal('en'))(
    h,
    other: '${h}h',
  );

  /// en: '{m}:{ss}'
  String minutes({required Object m, required Object ss}) => '${m}:${ss}';

  /// en: '(other) {{h}h} (other) {{m}m}'
  String hours({required num h, required num m}) =>
      '${_root.progressPage.remainingTime.hoursUnit(h: h)} ${_root.progressPage.remainingTime.minutesUnit(m: m)}';
}

// Path: whatsNewPage.changes
class Translations$whatsNewPage$changes$en {
  Translations$whatsNewPage$changes$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  late final Translations$whatsNewPage$changes$v1_0_0$en v1_0_0 = Translations$whatsNewPage$changes$v1_0_0$en.internal(_root);
}

// Path: dialogs.addFile
class Translations$dialogs$addFile$en {
  Translations$dialogs$addFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Add to selection'
  String get title => 'Add to selection';

  /// en: 'What do you want to add?'
  String get content => 'What do you want to add?';
}

// Path: dialogs.openFile
class Translations$dialogs$openFile$en {
  Translations$dialogs$openFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Open file'
  String get title => 'Open file';

  /// en: 'Do you want to open the received file?'
  String get content => 'Do you want to open the received file?';
}

// Path: dialogs.addressInput
class Translations$dialogs$addressInput$en {
  Translations$dialogs$addressInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter address'
  String get title => 'Enter address';

  /// en: 'Hashtag'
  String get hashtag => 'Hashtag';

  /// en: 'IP Address'
  String get ip => 'IP Address';

  /// en: 'Recently used: '
  String get recentlyUsed => 'Recently used: ';
}

// Path: dialogs.cancelSession
class Translations$dialogs$cancelSession$en {
  Translations$dialogs$cancelSession$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Cancel files transfer'
  String get title => 'Cancel files transfer';

  /// en: 'Do you really want to cancel the files transfer?'
  String get content => 'Do you really want to cancel the files transfer?';
}

// Path: dialogs.cannotOpenFile
class Translations$dialogs$cannotOpenFile$en {
  Translations$dialogs$cannotOpenFile$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Cannot open file'
  String get title => 'Cannot open file';

  /// en: 'Could not open "{file}". Has this file been moved, renamed or deleted?'
  String content({required Object file}) => 'Could not open "${file}". Has this file been moved, renamed or deleted?';
}

// Path: dialogs.encryptionDisabledNotice
class Translations$dialogs$encryptionDisabledNotice$en {
  Translations$dialogs$encryptionDisabledNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Encryption disabled'
  String get title => 'Encryption disabled';

  /// en: 'Communication now takes place via the unencrypted HTTP protocol. To use HTTPS protocol, enable encryption again.'
  String get content => 'Communication now takes place via the unencrypted HTTP protocol. To use HTTPS protocol, enable encryption again.';
}

// Path: dialogs.errorDialog
class Translations$dialogs$errorDialog$en {
  Translations$dialogs$errorDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Error'
  String get title => _root.general.error;
}

// Path: dialogs.favoriteDialog
class Translations$dialogs$favoriteDialog$en {
  Translations$dialogs$favoriteDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Favorites'
  String get title => 'Favorites';

  /// en: 'No favorite devices yet.'
  String get noFavorites => 'No favorite devices yet.';

  /// en: 'Add'
  String get addFavorite => 'Add';
}

// Path: dialogs.favoriteDeleteDialog
class Translations$dialogs$favoriteDeleteDialog$en {
  Translations$dialogs$favoriteDeleteDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Delete from favorites'
  String get title => 'Delete from favorites';

  /// en: 'Do you really want to delete from favorites "{name}"?'
  String content({required Object name}) => 'Do you really want to delete from favorites "${name}"?';
}

// Path: dialogs.favoriteEditDialog
class Translations$dialogs$favoriteEditDialog$en {
  Translations$dialogs$favoriteEditDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Add to favorites'
  String get titleAdd => 'Add to favorites';

  /// en: 'Settings'
  String get titleEdit => 'Settings';

  /// en: 'Device name'
  String get name => 'Device name';

  /// en: '(auto)'
  String get auto => '(auto)';

  /// en: 'IP Address'
  String get ip => 'IP Address';

  /// en: 'Port'
  String get port => 'Port';
}

// Path: dialogs.fileInfo
class Translations$dialogs$fileInfo$en {
  Translations$dialogs$fileInfo$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'File information'
  String get title => 'File information';

  /// en: 'File name:'
  String get fileName => 'File name:';

  /// en: 'Path:'
  String get path => 'Path:';

  /// en: 'Size:'
  String get size => 'Size:';

  /// en: 'Sender:'
  String get sender => 'Sender:';

  /// en: 'Time:'
  String get time => 'Time:';
}

// Path: dialogs.fileNameInput
class Translations$dialogs$fileNameInput$en {
  Translations$dialogs$fileNameInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter file name'
  String get title => 'Enter file name';

  /// en: 'Original: {original}'
  String original({required Object original}) => 'Original: ${original}';
}

// Path: dialogs.historyClearDialog
class Translations$dialogs$historyClearDialog$en {
  Translations$dialogs$historyClearDialog$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Clear history'
  String get title => 'Clear history';

  /// en: 'Do you really want to delete the entire history?'
  String get content => 'Do you really want to delete the entire history?';
}

// Path: dialogs.localNetworkUnauthorized
class Translations$dialogs$localNetworkUnauthorized$en {
  Translations$dialogs$localNetworkUnauthorized$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No permission'
  String get title => _root.dialogs.noPermission.title;

  /// en: 'LocalSend can't find other devices without having the permission to scan the local network. Please grant this permission in the settings.'
  String get description =>
      'LocalSend can\'t find other devices without having the permission to scan the local network. Please grant this permission in the settings.';

  /// en: 'Settings'
  String get gotoSettings => 'Settings';
}

// Path: dialogs.messageInput
class Translations$dialogs$messageInput$en {
  Translations$dialogs$messageInput$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Type message'
  String get title => 'Type message';

  /// en: 'Multiline'
  String get multiline => 'Multiline';
}

// Path: dialogs.noFiles
class Translations$dialogs$noFiles$en {
  Translations$dialogs$noFiles$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No files selected'
  String get title => 'No files selected';

  /// en: 'Please select at least one file.'
  String get content => 'Please select at least one file.';
}

// Path: dialogs.noPermission
class Translations$dialogs$noPermission$en {
  Translations$dialogs$noPermission$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'No permission'
  String get title => 'No permission';

  /// en: 'You have not granted the necessary permissions. Please grant them in the settings.'
  String get content => 'You have not granted the necessary permissions. Please grant them in the settings.';
}

// Path: dialogs.notAvailableOnPlatform
class Translations$dialogs$notAvailableOnPlatform$en {
  Translations$dialogs$notAvailableOnPlatform$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Not available'
  String get title => 'Not available';

  /// en: 'This feature is only available on:'
  String get content => 'This feature is only available on:';
}

// Path: dialogs.qr
class Translations$dialogs$qr$en {
  Translations$dialogs$qr$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'QR Code'
  String get title => 'QR Code';
}

// Path: dialogs.quickActions
class Translations$dialogs$quickActions$en {
  Translations$dialogs$quickActions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Actions'
  String get title => 'Quick Actions';

  /// en: 'Counter'
  String get counter => 'Counter';

  /// en: 'Prefix'
  String get prefix => 'Prefix';

  /// en: 'Pad with zeros'
  String get padZero => 'Pad with zeros';

  /// en: 'Sort alphabetically beforehand (A-Z)'
  String get sortBeforeCount => 'Sort alphabetically beforehand (A-Z)';

  /// en: 'Random'
  String get random => 'Random';
}

// Path: dialogs.quickSaveNotice
class Translations$dialogs$quickSaveNotice$en {
  Translations$dialogs$quickSaveNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Save'
  String get title => _root.general.quickSave;

  /// en: 'File requests are now accepted automatically. Be aware that everyone on the local network can send you files.'
  String get content => 'File requests are now accepted automatically. Be aware that everyone on the local network can send you files.';
}

// Path: dialogs.quickSaveFromFavoritesNotice
class Translations$dialogs$quickSaveFromFavoritesNotice$en {
  Translations$dialogs$quickSaveFromFavoritesNotice$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Quick Save for "Favorites"'
  String get title => _root.general.quickSaveFromFavorites;

  List<String> get content => [
    'File requests are now accepted automatically from devices in your favorites list.',
  ];
}

// Path: dialogs.pin
class Translations$dialogs$pin$en {
  Translations$dialogs$pin$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Enter PIN'
  String get title => 'Enter PIN';
}

// Path: dialogs.sendModeHelp
class Translations$dialogs$sendModeHelp$en {
  Translations$dialogs$sendModeHelp$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Send modes'
  String get title => 'Send modes';

  /// en: 'Adds a transfer to the device queue. Selection is kept for another send.'
  String get single => 'Adds a transfer to the device queue. Selection is kept for another send.';

  /// en: 'Sends files to multiple recipients. Selection will not be cleared after finished files transfer.'
  String get multiple => 'Sends files to multiple recipients. Selection will not be cleared after finished files transfer.';

  /// en: 'Recipients who do not have LocalSend installed can download the selected files by opening the link in their browser.'
  String get link => 'Recipients who do not have LocalSend installed can download the selected files by opening the link in their browser.';
}

// Path: dialogs.zoom
class Translations$dialogs$zoom$en {
  Translations$dialogs$zoom$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'URL'
  String get title => 'URL';
}

// Path: settingsTab.general.brightnessOptions
class Translations$settingsTab$general$brightnessOptions$en {
  Translations$settingsTab$general$brightnessOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';

  /// en: 'Dark'
  String get dark => 'Dark';

  /// en: 'Light'
  String get light => 'Light';
}

// Path: settingsTab.general.colorOptions
class Translations$settingsTab$general$colorOptions$en {
  Translations$settingsTab$general$colorOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';

  /// en: 'OLED'
  String get oled => 'OLED';

  /// en: 'Custom'
  String get custom => 'Custom';
}

// Path: settingsTab.general.languageOptions
class Translations$settingsTab$general$languageOptions$en {
  Translations$settingsTab$general$languageOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'System'
  String get system => 'System';
}

// Path: settingsTab.network.networkOptions
class Translations$settingsTab$network$networkOptions$en {
  Translations$settingsTab$network$networkOptions$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'All'
  String get all => 'All';

  /// en: 'Filtered'
  String get filtered => 'Filtered';
}

// Path: progressPage.total.title
class Translations$progressPage$total$title$en {
  Translations$progressPage$total$title$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations

  /// en: 'Total progress ({time})'
  String sending({required Object time}) => 'Total progress (${time})';

  /// en: 'Finished with error'
  String get finishedError => 'Finished with error';

  /// en: 'Canceled by sender'
  String get canceledSender => 'Canceled by sender';

  /// en: 'Canceled by receiver'
  String get canceledReceiver => 'Canceled by receiver';
}

// Path: whatsNewPage.changes.v1_0_0
class Translations$whatsNewPage$changes$v1_0_0$en with WhatsNewStrings {
  Translations$whatsNewPage$changes$v1_0_0$en.internal(this._root);

  final Translations _root; // ignore: unused_field

  // Translations
  @override
  List<String> get changes => [
    '1.0.0 is a development version and has not been officially released.',
    'Send files and folders from a queue, retry failed files individually, and manage sending and receiving without leaving your current page.',
    'Compatible devices and storage can resume large transfers. Reusing progress after restart needs fresh approval; other destinations retain whole-file retry.',
    'Choose receive folders in iOS Files and Android document storage. Lost access is reported without silently changing the destination.',
    'Check interrupted saves and automatically clean verified temporary copies. Completed files, active transfers and uncertain leftovers remain protected.',
    'Share files and folder workspaces in a browser, with passwords, approved uploads, bulk ZIP downloads and optional authorized-folder download controls.',
    'Preview images, audio, video, text and Markdown. Search document contents and keep your reading position when files refresh.',
    'Choose a network connection per send task, view connection details, and access the optional integration API and its in-app reference.',
    'iOS restores pending shares without sending automatically. Smaller screens and large text are easier to use, and the privacy policy is available offline.',
    'Fixed an incorrect recovery-record save error when starting the sandboxed macOS app.',
  ];
}
