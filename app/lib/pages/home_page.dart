import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/brand.dart';
import 'package:localsend_app/config/init.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/tabs/api_tab.dart';
import 'package:localsend_app/pages/tabs/receive_tab.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/tabs/settings_tab.dart';
import 'package:localsend_app/pages/tabs/workspaces_tab.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/android_folder_strings.dart';
import 'package:localsend_app/util/native/drop_files.dart';
import 'package:localsend_app/util/native/ios_drop_channel.dart';
import 'package:localsend_app/util/native/source_cache_guard.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/device_drop_region.dart';
import 'package:localsend_app/widget/responsive_builder.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';

enum HomeTab {
  receive(Icons.wifi),
  send(Icons.send),
  workspaces(Icons.folder_shared_outlined),
  api(Icons.api),
  settings(Icons.settings)
  ;

  const HomeTab(this.icon);

  final IconData icon;

  String get label {
    switch (this) {
      case HomeTab.receive:
        return t.receiveTab.title;
      case HomeTab.send:
        return t.sendTab.title;
      case HomeTab.workspaces:
        return t.directoryWorkspaces.title;
      case HomeTab.api:
        return t.integrationApi.title;
      case HomeTab.settings:
        return t.settingsTab.title;
    }
  }
}

class HomePage extends StatefulWidget {
  final HomeTab initialTab;

  /// It is important for the initializing step
  /// because the first init clears the cache
  final bool appStart;

  const HomePage({
    required this.initialTab,
    required this.appStart,
    super.key,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with Refena {
  bool _dragAndDropIndicator = false;
  IosDropController? _iosDrop;
  bool _iosDropPrepared = false;
  Device? _iosDropTarget;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _iosDrop = IosDropController(
        prepare: (position) {
          if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
          _iosDropTarget = hitTestDropDevice(context, position);
          _iosDropPrepared = true;
          return true;
        },
        failed: () {
          _iosDropPrepared = false;
          _iosDropTarget = null;
          if (mounted) context.showSnackBar(iosDropFailureText(LocaleSettings.currentLocale));
        },
      )..attach();
    }

    ensureRef((ref) async {
      ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(widget.initialTab));
      await postInit(context, ref, widget.appStart);
    });
  }

  @override
  void dispose() {
    _iosDrop?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Translations.of(context); // rebuild on locale change
    final vm = context.watch(homePageControllerProvider);

    return DropTarget(
      onDragEntered: (event) {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        vm.changeTab(HomeTab.send);
        setState(() => _dragAndDropIndicator = true);
        ref.notifier(deviceDropHoverProvider).set(hitTestDropDevice(context, event.globalPosition));
      },
      onDragUpdated: (event) {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        ref.notifier(deviceDropHoverProvider).set(hitTestDropDevice(context, event.globalPosition));
      },
      onDragExited: (_) {
        setState(() => _dragAndDropIndicator = false);
        ref.notifier(deviceDropHoverProvider).set(null);
      },
      onDragDone: (event) async {
        if (ModalRoute.of(context)?.isCurrent != true) return;
        final target = _iosDropPrepared ? _iosDropTarget : hitTestDropDevice(context, event.globalPosition);
        _iosDropPrepared = false;
        _iosDropTarget = null;
        setState(() => _dragAndDropIndicator = false);
        ref.notifier(deviceDropHoverProvider).set(null);
        final cacheLease = await ref.read(sourceCacheLeaseProvider).acquire();
        try {
          if (!context.mounted) return;
          var emptyDirectories = 0;
          final files = await collectDroppedFiles(event.files.map((file) => file.path), onEmptyDirectories: (count) => emptyDirectories = count);
          if (!context.mounted) return;
          final emptyHint = emptyDirectories == 0 ? '' : AndroidFolderStrings(Translations.of(context).$meta.locale).empty(emptyDirectories);
          if (files.isEmpty) {
            if (emptyHint.isNotEmpty) context.showSnackBar(emptyHint);
            return;
          }
          if (target != null) {
            ref.notifier(sendQueueProvider).enqueue(target, files);
            context.showSnackBar('${t.sendQueue.added(device: target.alias, n: files.length)}${emptyHint.isEmpty ? '' : '\n$emptyHint'}');
          } else {
            await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddFilesAction(files: files, converter: (file) async => file));
            if (context.mounted && emptyHint.isNotEmpty) context.showSnackBar(emptyHint);
          }
          vm.changeTab(HomeTab.send);
        } catch (e) {
          if (context.mounted) context.showSnackBar('${t.general.error}: $e');
        } finally {
          cacheLease.release();
        }
      },
      child: ResponsiveBuilder(
        builder: (sizingInformation) {
          return Scaffold(
            body: Row(
              children: [
                if (!sizingInformation.isMobile)
                  NavigationRail(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    extended: sizingInformation.isDesktop,
                    backgroundColor: Theme.of(context).cardColorWithElevation,
                    leading: sizingInformation.isDesktop
                        ? const Column(
                            children: [
                              SizedBox(height: 20),
                              Text(
                                Brand.name,
                                style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                                textAlign: TextAlign.center,
                              ),
                              SizedBox(height: 20),
                            ],
                          )
                        : null,
                    destinations: HomeTab.values.map((tab) {
                      return NavigationRailDestination(
                        icon: Icon(tab.icon),
                        label: Text(tab.label),
                      );
                    }).toList(),
                  ),
                Expanded(
                  child: SafeArea(
                    left: sizingInformation.isMobile,
                    child: Stack(
                      children: [
                        PageView(
                          controller: vm.controller,
                          physics: const NeverScrollableScrollPhysics(),
                          children: const [
                            ReceiveTab(),
                            SendTab(),
                            WorkspacesTab(),
                            ApiTab(),
                            SettingsTab(),
                          ],
                        ),
                        if (_dragAndDropIndicator)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      context.watch(deviceDropHoverProvider) != null
                                          ? t.sendQueue.drop(device: context.watch(deviceDropHoverProvider)!.alias)
                                          : t.sendTab.placeItems,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            bottomNavigationBar: sizingInformation.isMobile
                ? NavigationBar(
                    selectedIndex: vm.currentTab.index,
                    onDestinationSelected: (index) => vm.changeTab(HomeTab.values[index]),
                    destinations: HomeTab.values.map((tab) {
                      return NavigationDestination(icon: Icon(tab.icon), label: tab.label);
                    }).toList(),
                  )
                : null,
          );
        },
      ),
    );
  }
}
