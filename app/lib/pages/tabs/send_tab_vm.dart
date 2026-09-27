import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/favorite_device.dart';
import 'package:localsend_app/model/send_mode.dart';
import 'package:localsend_app/pages/tabs/send_tab.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_queue_provider.dart';
import 'package:localsend_app/provider/network/send_route_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/dialogs/add_file_dialog.dart';
import 'package:localsend_app/widget/dialogs/address_input_dialog.dart';
import 'package:localsend_app/widget/dialogs/favorite_dialog.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';

class SendTabVm {
  final SendMode sendMode;
  final List<CrossFile> selectedFiles;
  final List<String> localIps;
  final Iterable<Device> nearbyDevices;
  final List<FavoriteDevice> favoriteDevices;
  final Future<void> Function(BuildContext context) onTapAddress;
  final Future<void> Function(BuildContext context) onTapFavorite;
  final Future<void> Function(BuildContext context, SendMode mode) onTapSendMode;
  final Future<void> Function(BuildContext context, Device device) onTapDevice;
  final Future<void> Function(BuildContext context, Device device) onTapDeviceMultiSend;

  const SendTabVm({
    required this.sendMode,
    required this.selectedFiles,
    required this.localIps,
    required this.nearbyDevices,
    required this.favoriteDevices,
    required this.onTapAddress,
    required this.onTapFavorite,
    required this.onTapSendMode,
    required this.onTapDevice,
    required this.onTapDeviceMultiSend,
  });
}

final sendTabVmProvider = ViewProvider((ref) {
  final sendMode = ref.watch(settingsProvider.select((s) => s.sendMode));
  final selectedFiles = ref.watch(selectedSendingFilesProvider);
  final localIps = ref.watch(localIpProvider).localIps;
  final networkFilter = ref.watch(sendNetworkFilterProvider);
  final addresses = ref.watch(localIpProvider).addresses;
  final nearbyDevices = ref.watch(nearbyDevicesProvider).allDevices.values.where((device) => deviceMatchesNetwork(device, networkFilter, addresses));
  final favoriteDevices = ref.watch(favoritesProvider);

  Future<void> enqueueSelection(BuildContext context, Device device) async {
    if (ref.read(selectedSendingFilesProvider).isEmpty) {
      await AddFileDialog.open(context: context, options: pickerOptions);
    }
    final files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty || !context.mounted) return;
    try {
      ref.notifier(sendQueueProvider).enqueue(device, files);
    } catch (e) {
      if (context.mounted) context.showSnackBar('${t.general.error}: $e');
    }
  }

  return SendTabVm(
    sendMode: sendMode,
    selectedFiles: selectedFiles,
    localIps: localIps,
    nearbyDevices: nearbyDevices,
    favoriteDevices: favoriteDevices,
    onTapAddress: (context) async {
      var files = ref.read(selectedSendingFilesProvider);
      if (files.isEmpty) {
        await AddFileDialog.open(
          context: context,
          options: pickerOptions,
        );
      }

      files = ref.read(selectedSendingFilesProvider);

      if (files.isEmpty || !context.mounted) {
        return;
      }
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const AddressInputDialog(),
      );
      if (device != null && context.mounted) {
        await enqueueSelection(context, device);
      }
    },
    onTapFavorite: (context) async {
      final device = await showDialog<Device?>(
        context: context,
        builder: (_) => const FavoritesDialog(),
      );
      if (device != null && context.mounted) {
        var files = ref.read(selectedSendingFilesProvider);
        if (files.isEmpty) {
          await AddFileDialog.open(
            context: context,
            options: pickerOptions,
          );
        }

        files = ref.read(selectedSendingFilesProvider);

        if (files.isEmpty || !context.mounted) {
          return;
        }

        await enqueueSelection(context, device);
      }
    },
    onTapSendMode: (context, mode) async {
      if (mode == SendMode.link) {
        var files = ref.read(selectedSendingFilesProvider);
        if (files.isEmpty) {
          await AddFileDialog.open(
            context: context,
            options: pickerOptions,
          );
        }

        files = ref.read(selectedSendingFilesProvider);

        if (files.isEmpty || !context.mounted) {
          return;
        }
        await context.push(() => WebSharePage(files: files));
        return;
      }

      await ref.notifier(settingsProvider).setSendMode(mode);
    },
    onTapDevice: (context, device) async => await enqueueSelection(context, device),
    onTapDeviceMultiSend: (context, device) async => await enqueueSelection(context, device),
  );
});

class SendTabInitAction extends AsyncGlobalAction {
  final BuildContext context;

  SendTabInitAction(this.context);

  @override
  Future<void> reduce() async {
    final devices = ref.read(nearbyDevicesProvider).devices;
    if (devices.isEmpty) {
      await dispatchAsync(StartSmartScan());
    }
  }
}
