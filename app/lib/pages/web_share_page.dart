import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/server/web_share_state.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart' show pickerOptions;
import 'package:localsend_app/pages/web_shared_files_page.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/accessible_icon_button.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_app/widget/dialogs/qr_dialog.dart';
import 'package:localsend_app/widget/dialogs/zoom_dialog.dart';
import 'package:localsend_app/widget/network_address_tags.dart';
import 'package:localsend_app/widget/network_environment_badge.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/share_address_list.dart';
import 'package:localsend_app/widget/share_link_actions.dart';
import 'package:localsend_app/widget/status_tag.dart';
import 'package:localsend_app/widget/transport_security_toggle.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

enum _ServerState { initializing, running, error, stopping }

/// Opens a persistent bidirectional browser workspace. Files append to an active
/// workspace; entering without files reopens it or starts with uploads enabled.
/// Incoming requests still use the normal receive decision flow.
class WebSharePage extends StatefulWidget {
  /// The files offered for download (share via link).
  /// `null` serves the upload page instead (receive via link).
  final List<CrossFile>? files;

  final bool resume;
  const WebSharePage({this.files, this.resume = false});

  @override
  State<WebSharePage> createState() => _WebSharePageState();
}

class _WebSharePageState extends State<WebSharePage> with Refena {
  _ServerState _stateEnum = _ServerState.initializing;
  bool _encrypted = false;
  String? _initializedError;

  bool get _sendMode => _stateEnum == _ServerState.running ? ref.read(serverProvider)?.webDownloadState != null : widget.files != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final existing = ref.read(serverProvider);
      if (widget.resume && existing?.web != null) {
        setState(() {
          _encrypted = existing!.https;
          _stateEnum = _ServerState.running;
        });
      } else if (widget.resume) {
        context.pop();
      } else {
        _init(encrypted: ref.read(settingsProvider).https);
      }
    });
  }

  void _init({required bool encrypted}) async {
    final settings = ref.read(settingsProvider);
    final generation = ref.notifier(serverProvider).generation;
    setState(() {
      _stateEnum = _ServerState.initializing;
      _encrypted = encrypted;
      _initializedError = null;
    });
    final existing = ref.read(serverProvider);
    if (existing?.web case WebShareDownload(duplex: true)) {
      try {
        if (widget.files?.isNotEmpty == true) {
          await ref.notifier(serverProvider).updateWebWorkspace(expectedGeneration: generation, files: widget.files!);
        }
        if (mounted) {
          setState(() {
            _encrypted = existing!.https;
            _stateEnum = _ServerState.running;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _stateEnum = _ServerState.error;
            _initializedError = e.toString();
          });
        }
      }
      return;
    }
    if (existing?.web != null) {
      if (!await _confirm(t.transferNavigation.replaceTitle, t.transferNavigation.replaceBody)) {
        if (mounted) context.pop();
        return;
      }
    }
    if (!mounted) return;
    if (generation != ref.notifier(serverProvider).generation) {
      context.pop();
      return;
    }
    try {
      final files = widget.files;

      // The pin of a previous web share session is kept;
      // receive mode initially uses the receive pin from settings.
      final previousWeb = ref.read(serverProvider)?.web;
      final webPin = previousWeb != null ? previousWeb.pin : (files == null ? settings.receivePin : null);

      await ref
          .notifier(serverProvider)
          .restartServerWithWebDownload(
            alias: settings.alias,
            port: settings.port,
            https: _encrypted,
            files: files ?? [],
            pin: webPin,
            expectedGeneration: generation,
            duplex: true,
            allowUpload: files == null,
          );
      if (!mounted) return;
      setState(() {
        _stateEnum = _ServerState.running;
      });
    } catch (e) {
      if (context.mounted) {
        setState(() {
          _stateEnum = _ServerState.error;
          _initializedError = e.toString();
        });
      }
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      (await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.general.cancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.general.confirm)),
          ],
        ),
      )) ==
      true;

  Future<void> _stopSharing() async {
    final server = ref.notifier(serverProvider);
    final generation = server.generation;
    if (!await _confirm(t.transferNavigation.stopTitle, t.transferNavigation.stopBody) || !mounted) return;
    setState(() => _stateEnum = _ServerState.stopping);
    try {
      await server.stopWebShare(expectedGeneration: generation);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _stateEnum = _ServerState.error;
          _initializedError = e.toString();
        });
      }
    }
  }

  Future<void> _changeSettings({bool? https, bool updatePin = false, String? pin, int? expectedGeneration}) async {
    final server = ref.notifier(serverProvider);
    final generation = expectedGeneration ?? server.generation;
    if (!await _confirm(
          https != null ? t.transferNavigation.restartTitle : t.transferNavigation.replaceTitle,
          https != null ? t.transferNavigation.restartBody : t.transferNavigation.replaceBody,
        ) ||
        !mounted) {
      return;
    }
    setState(() => _stateEnum = _ServerState.initializing);
    try {
      if (https != null) {
        await server.changeTransport(expectedGeneration: generation, https: https);
      } else {
        await server.updateWebSettings(expectedGeneration: generation, updatePin: updatePin, pin: pin);
      }
      if (mounted) {
        setState(() {
          _encrypted = ref.read(serverProvider)?.https ?? _encrypted;
          _stateEnum = _ServerState.running;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stateEnum = _ServerState.error;
          _initializedError = e.toString();
        });
      }
    }
  }

  Future<void> _updateWorkspace({bool? allowUpload, List<CrossFile> files = const []}) async {
    final server = ref.notifier(serverProvider);
    try {
      await server.updateWebWorkspace(expectedGeneration: server.generation, files: files, allowUpload: allowUpload);
    } catch (e) {
      if (mounted) context.showSnackBar('${t.general.error}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasShare = context.watch(serverProvider.select((server) => server?.web != null));
    return PopScope(
      // The sharing service belongs to ServerService, never to this route.
      // Back, gestures and task switching only hide the page.
      canPop: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(t.linkWorkspace.title),
          leading: Navigator.of(context).canPop()
              ? AccessibleIconButton(
                  icon: Icons.arrow_back,
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
          actions: [
            if (_stateEnum == _ServerState.running && hasShare)
              AccessibleIconButton(
                key: const ValueKey('stop-web-sharing'),
                label: t.transferNavigation.stopSharing,
                icon: Icons.stop_circle_outlined,
                onPressed: _stopSharing,
              ),
            AccessibleIconButton(
              label: t.networkLabels.refresh,
              icon: Icons.refresh,
              onPressed: () async => await ref.redux(localIpProvider).dispatchAsync(FetchLocalIpAction()),
            ),
          ],
        ),
        body: Builder(
          builder: (context) {
            if (_stateEnum != _ServerState.running) {
              return Column(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (_stateEnum == _ServerState.initializing || _stateEnum == _ServerState.stopping) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Center(
                      child: Text(
                        _stateEnum == _ServerState.initializing ? t.webSharePage.loading : t.webSharePage.stopping,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ] else if (_initializedError != null) ...[
                    const Icon(Icons.error_outline, size: 48, color: Colors.red),
                    const SizedBox(height: 10),
                    Center(
                      child: Text(t.webSharePage.error, style: Theme.of(context).textTheme.titleLarge),
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: SelectableText(_initializedError!, style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  ],
                ],
              );
            }

            final serverState = context.watch(serverProvider);
            final webDownloadState = serverState?.webDownloadState;
            if (serverState == null || serverState.web == null) {
              return Center(child: Text(t.transferNavigation.unknown));
            }
            final networkState = context.watch(localIpProvider);
            final settings = context.watch(settingsProvider);
            final pin = serverState.web?.pin;

            return ResponsiveListView(
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
              children: [
                if (networkState.hasNetworkOverlay) ...[
                  Align(
                    alignment: Alignment.centerLeft,
                    child: NetworkEnvironmentBadge(network: networkState),
                  ),
                  const SizedBox(height: 6),
                ],
                Text(t.transferNavigation.keepSharing, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 10),
                Text(t.webSharePage.openLink(n: networkState.localIps.length), style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (networkState.localIps.isEmpty) Text(t.networkLabels.noAddress),
                        ShareAddressList(
                          addresses: networkState.addresses,
                          moreLabel: t.directoryWorkspaces.moreAddresses,
                          itemBuilder: (address) {
                            final ip = address.address;
                            final url = Uri(
                              scheme: serverState.https ? 'https' : 'http',
                              host: ip,
                              port: serverState.port,
                              path: '/share',
                            ).toString();
                            final urlWithPin = switch (pin) {
                              String() => '$url?pin=${Uri.encodeQueryComponent(pin)}',
                              null => url,
                            };
                            return Padding(
                              padding: const EdgeInsets.all(5),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  NetworkAddressTags(address: address),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      StatusTag(child: SelectableText(url, style: Theme.of(context).textTheme.labelMedium)),
                                      const SizedBox(width: 5),
                                      ShareLinkActions(
                                        url: url,
                                        onCopy: () async {
                                          await Clipboard.setData(ClipboardData(text: url));
                                          if (context.mounted && checkPlatformIsDesktop()) context.showSnackBar(t.general.copiedToClipboard);
                                        },
                                        onQr: () async {
                                          await showDialog<void>(
                                            context: context,
                                            builder: (_) => QrDialog(
                                              data: urlWithPin,
                                              label: url,
                                              listenIncomingWebDownloadRequests: _sendMode,
                                              pin: pin,
                                            ),
                                          );
                                        },
                                        onZoom: () async {
                                          await showDialog<void>(
                                            context: context,
                                            builder: (_) => ZoomDialog(
                                              label: url,
                                              listenIncomingWebDownloadRequests: _sendMode,
                                              pin: pin,
                                            ),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (serverState.web case WebShareDownload(duplex: true, :final allowUpload)) ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      StatusTag(label: t.linkWorkspace.sharedCount(n: webDownloadState!.files.length)),
                      StatusTag(
                        key: const ValueKey('manage-shared-files'),
                        icon: Icons.folder_open,
                        label: t.sharedFileManagement.title,
                        onTap: () async {
                          final generation = ref.notifier(serverProvider).generation;
                          await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WebSharedFilesPage(generation: generation)));
                        },
                      ),
                      StatusTag(
                        icon: Icons.add,
                        label: t.general.add,
                        onTap: () async {
                          final generation = ref.notifier(serverProvider).generation;
                          final previous = ref.read(selectedSendingFilesProvider).toSet();
                          await AddFileDialog.open(context: context, options: pickerOptions);
                          if (!mounted || generation != ref.notifier(serverProvider).generation) return;
                          final files = ref.read(selectedSendingFilesProvider).where((file) => !previous.contains(file)).toList();
                          if (files.isNotEmpty) await _updateWorkspace(files: files);
                        },
                      ),
                    ],
                  ),
                  Text(t.linkWorkspace.appendHint, style: Theme.of(context).textTheme.bodySmall),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.linkWorkspace.allowUpload),
                    subtitle: Text(t.linkWorkspace.allowUploadHint),
                    value: allowUpload,
                    onChanged: (value) => _updateWorkspace(allowUpload: value),
                  ),
                  if (allowUpload)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.linkWorkspace.autoReceive),
                      value: settings.receiveViaLinkAutoAccept,
                      onChanged: (value) => ref.notifier(settingsProvider).setReceiveViaLinkAutoAccept(value == true),
                    ),
                ],
                if (webDownloadState != null) ...[
                  Text(t.webSharePage.requests, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  if (webDownloadState.sessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 30),
                      child: Text(t.webSharePage.noRequests),
                    ),
                  ...webDownloadState.sessions.entries.map((entry) {
                    final session = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      session.deviceInfo,
                                      style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                                        color: session.pending ? Theme.of(context).colorScheme.warning : null,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(session.ip, style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Colors.grey)),
                                  ],
                                ),
                              ),
                              if (session.pending) ...[
                                TextButton(
                                  onPressed: () {
                                    ref.notifier(serverProvider).declineWebDownloadRequest(session.sessionId);
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                                    iconSize: 24,
                                  ),
                                  child: const Icon(Icons.close),
                                ),
                                TextButton(
                                  onPressed: () {
                                    ref.notifier(serverProvider).acceptWebDownloadRequest(session.sessionId);
                                  },
                                  style: TextButton.styleFrom(
                                    foregroundColor: Theme.of(context).colorScheme.onSurface,
                                    iconSize: 24,
                                  ),
                                  child: const Icon(Icons.check_circle),
                                ),
                              ] else
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: Text(
                                    t.general.accepted,
                                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
                TransportSecurityToggle(
                  value: serverState.https,
                  showCertificate: true,
                  onChanged: (value) => _changeSettings(https: value),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Text(
                        serverState.web is WebShareDownload ? t.linkWorkspace.autoDownload : t.webSharePage.autoAccept,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Checkbox(
                      value: webDownloadState != null ? webDownloadState.autoAccept : settings.receiveViaLinkAutoAccept,
                      onChanged: (value) async {
                        if (webDownloadState != null) {
                          ref.notifier(serverProvider).setWebDownloadAutoAccept(value == true);
                        } else {
                          await ref.notifier(settingsProvider).setReceiveViaLinkAutoAccept(value == true);
                        }
                      },
                    ),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: Text(t.webSharePage.requirePin, style: Theme.of(context).textTheme.titleMedium)),
                    const SizedBox(width: 10),
                    Checkbox(
                      value: pin != null,
                      onChanged: (value) async {
                        if (pin != null) {
                          await _changeSettings(updatePin: true, pin: null);
                        } else {
                          final generation = ref.notifier(serverProvider).generation;
                          final String? newPin = await showDialog<String>(
                            context: context,
                            builder: (_) => const PinDialog(
                              obscureText: false,
                              generateRandom: true,
                            ),
                          );

                          if (newPin != null && newPin.isNotEmpty) {
                            if (!mounted) return;
                            await _changeSettings(updatePin: true, pin: newPin, expectedGeneration: generation);
                          }
                        }
                      },
                    ),
                  ],
                ),
                if (pin != null)
                  Text(
                    t.webSharePage.pinHint(pin: pin),
                    style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: Theme.of(context).colorScheme.warning),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
