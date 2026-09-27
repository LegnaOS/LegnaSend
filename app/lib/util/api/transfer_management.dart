import 'dart:async';
import 'dart:convert';

import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/local_network_address.dart';
import 'package:localsend_app/model/send_job.dart';
import 'package:localsend_app/util/api/workspace_send_capture.dart';
import 'package:localsend_app/util/async_serial_queue.dart';
import 'package:localsend_app/util/send_route.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/local_send_route.dart';
import 'package:uuid/uuid.dart';

final _id = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _principalId = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
const _uuid = Uuid();

class _Failure implements Exception {
  final int status;
  final String code;
  const _Failure(this.status, this.code);
}

class _OwnedTask {
  final String principal;
  final String deviceId;
  final String? localRouteId;
  final String? retryOf;
  Map<String, Object?> snapshot;
  bool removed = false;
  _OwnedTask(this.principal, this.deviceId, this.retryOf, this.snapshot, {this.localRouteId});
}

/// An app-lifetime adapter over the real UI send queue, not a second transport.
/// Remote callers can only select confirmed device/channel IDs and the current
/// locally selected files. Receipts are bounded and never silently evicted.
class TransferManagement {
  final Iterable<Device> Function() readDevices;
  final List<LocalNetworkAddress> Function()? readLocalAddresses;
  final bool interfaceBinding;
  final String Function(Device, List<CrossFile>, HttpChannel, LocalSendRoute)? enqueueRouted;
  final Future<String> Function(Device, List<CrossFile>, HttpChannel, LocalSendRoute)? enqueueOwnedRouted;
  final _localRouteIds = <String, String>{};

  final List<CrossFile> Function() readSelection;
  final List<SendJob> Function() readJobs;
  final String Function(Device, List<CrossFile>, HttpChannel) enqueue;
  final Future<WorkspaceSendCapture> Function(String workspaceId, int generation, List<Map<String, String>> files)? captureWorkspace;
  final Future<WorkspaceSendCapture> Function(String workspaceId, int generation, List<Map<String, String>> files)? captureDocumentWorkspace;
  final Future<String> Function(Device, WorkspaceSendCapture, HttpChannel, LocalSendRoute?)? enqueueCaptured;
  final Future<String> Function(Device, List<CrossFile>, HttpChannel)? enqueueOwned;
  final FutureOr<void> Function(String) cancel;
  final FutureOr<void> Function(String) remove;
  final Future<void> Function() scan;
  final ({int transferredBytes, int bytesPerSecond}) Function(String)? readProgress;
  final int receiptLimit;
  final DateTime Function() clock;
  final _serial = AsyncSerialQueue();
  // Source I/O has its own bounded serialized lane. Queries and cancellation
  // must not wait behind copying a large workspace file.
  final _sourceSerial = AsyncSerialQueue();
  final _inflightSources = <String, String>{};
  final _deviceIds = <String, String>{};
  final _channelIds = <String, String>{};
  final _tasks = <String, _OwnedTask>{};
  final _receipts = <String, ({String payload, String taskId})>{};
  List<CrossFile>? _selection;
  String _selectionVersion = _uuid.v4();
  bool _scanning = false;
  bool _scanFailed = false;
  DateTime? _lastScan;

  TransferManagement({
    required this.readDevices,
    this.readLocalAddresses,
    this.interfaceBinding = false,
    this.enqueueRouted,
    this.enqueueOwnedRouted,
    required this.readSelection,
    required this.readJobs,
    required this.enqueue,
    required this.cancel,
    required this.remove,
    required this.scan,
    this.readProgress,
    this.captureWorkspace,
    this.captureDocumentWorkspace,
    this.enqueueCaptured,
    this.enqueueOwned,
    this.receiptLimit = 512,
    this.clock = DateTime.now,
  });

  Map<String, LocalSendRoute> refreshLocalRoutes() {
    final keys = <String>{};
    final routes = <String, LocalSendRoute>{};
    for (final address
        in (readLocalAddresses?.call() ?? const <LocalNetworkAddress>[])
            .where((a) => a.hasNonLinkLocalAddress && !a.address.contains('%') && a.interfaceName.isNotEmpty && a.interfaceName.length <= 256)
            .take(64)) {
      final key = jsonEncode([
        address.interfaceName,
        address.interfaceIndex,
        address.address,
        address.androidNetworkHandle,
        address.androidNetworkEpoch,
      ]);
      keys.add(key);
      final id = _localRouteIds.putIfAbsent(key, _uuid.v4);
      routes[id] = LocalSendRoute(
        interfaceName: address.interfaceName,
        localAddress: address.address,
        androidNetworkHandle: address.androidNetworkHandle,
        androidNetworkEpoch: address.androidNetworkEpoch,
      );
    }
    _localRouteIds.removeWhere((key, _) => !keys.contains(key));
    return routes;
  }

  LocalSendRoute _resolveLocalRoute(String id) {
    final route = refreshLocalRoutes()[id];
    if (route == null) throw const _Failure(409, 'local_route_unavailable');
    return route;
  }

  List<CrossFile> _selected() {
    final current = readSelection();
    if (!identical(current, _selection)) {
      _selection = current;
      _selectionVersion = _uuid.v4();
    }
    return current;
  }

  Map<String, Device> _devices() {
    // Only the confirmed HTTP store is supplied by the production adapter.
    final result = <String, Device>{};
    final activeKeys = <String>{};
    final channelKeys = <String>{};
    for (final device in readDevices().take(512)) {
      final channels = device.channels.whereType<HttpChannel>().take(32).toList();
      if (device.fingerprint.isEmpty || channels.isEmpty) continue;
      activeKeys.add(device.fingerprint);
      final id = _deviceIds.putIfAbsent(device.fingerprint, _uuid.v4);
      result[id] = device;
      for (final channel in channels) {
        final key = _channelKey(id, channel);
        channelKeys.add(key);
        _channelIds.putIfAbsent(key, _uuid.v4);
      }
    }
    _deviceIds.removeWhere((key, _) => !activeKeys.contains(key));
    _channelIds.removeWhere((key, _) => !channelKeys.contains(key));
    return result;
  }

  String _label(String value, int byteLimit) {
    final result = StringBuffer();
    var bytes = 0;
    for (final scalar in value.runes) {
      // Replace controls and malformed UTF-16 instead of serializing a split
      // surrogate. Limits are wire UTF-8 bytes, not Dart UTF-16 code units.
      final rune = scalar < 0x20 || scalar >= 0x7f && scalar <= 0x9f
          ? 0x20
          : scalar >= 0xd800 && scalar <= 0xdfff
          ? 0xfffd
          : scalar;
      final encoded = String.fromCharCode(rune);
      final width = utf8.encode(encoded).length;
      if (bytes + width > byteLimit) break;
      result.write(encoded);
      bytes += width;
    }
    return result.toString();
  }

  String _channelKey(String device, HttpChannel channel) => jsonEncode([device, channel.host, channel.port, channel.https]);
  Map<String, Object?> _device(String id, Device device) => {
    'id': id,
    'alias': _label(device.alias, 120),
    'deviceType': device.deviceType.name,
    'channels': [
      for (final channel in device.channels.whereType<HttpChannel>().take(32))
        {'id': _channelIds[_channelKey(id, channel)], 'host': channel.host, 'port': channel.port, 'https': channel.https},
    ],
  };

  Map<String, Object?> _task(String id, _OwnedTask owned) {
    final job = readJobs().where((job) => job.id == id).firstOrNull;
    if (job != null && !owned.removed) {
      final total = job.files.fold<int>(0, (sum, file) => sum + file.size);
      final progress = readProgress?.call(id);
      owned.snapshot = {
        'id': id,
        'deviceId': owned.deviceId,
        'status': job.status.name,
        'fileCount': job.files.length,
        'totalBytes': total,
        'transferredBytes': (progress?.transferredBytes ?? 0).clamp(0, total),
        'bytesPerSecond': job.terminal ? 0 : (progress?.bytesPerSecond ?? 0).clamp(0, 0x1fffffffffffff),
        if (job.result != null) 'result': job.result!.name,
        if (owned.retryOf != null) 'retryOf': owned.retryOf,
        if (owned.localRouteId != null) 'localRouteId': owned.localRouteId,
      };
    } else {
      // Local history removal also releases remote control; retain only a
      // redacted receipt so repeating a lost accepted response never resends.
      owned.removed = true;
    }
    return {...owned.snapshot, if (owned.removed) 'removed': true};
  }

  AsyncSerialQueue _requestQueue(String request) {
    if (request.length > 72 * 1024) return _serial;
    try {
      final value = jsonDecode(request);
      return value is Map && value['operation'] == 'transfer.workspaceSend' ? _sourceSerial : _serial;
    } catch (_) {
      return _serial;
    }
  }

  Future<String> execute({required String request, required Future<bool> Function() claim}) => _requestQueue(request).run(() async {
    String response(int status, Map<String, Object?> body) {
      final encoded = jsonEncode({'status': status, 'body': body});
      if (utf8.encode(encoded).length > 250 * 1024) {
        return '{"status":503,"body":{"error":{"code":"transfer_response_too_large"}}}';
      }
      return encoded;
    }

    String? reservedSource;
    try {
      if (utf8.encode(request).length > 72 * 1024) throw const FormatException();
      final decoded = jsonDecode(request);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final data = decoded;
      final operation = data['operation'];
      final principal = data['principal'];
      if (operation is! String ||
          principal is! String ||
          _principalId.stringMatch(principal) != principal ||
          data['workspaces'] is! List ||
          jsonEncode(data['workspaces']) != '["*"]') {
        throw const FormatException();
      }
      final extra = switch (operation) {
        'transfer.devices' || 'transfer.scan' || 'transfer.selection' || 'transfer.list' => <String>{},
        'transfer.device' => {'deviceId'},
        'transfer.workspaceSend' => {
          'workspaceId',
          'generation',
          'instanceId',
          'deviceId',
          'requestId',
          'channelId',
          'localRouteId',
          'files',
          'sourceMode',
        },
        'transfer.send' => {'deviceId', 'selectionVersion', 'requestId', 'channelId', 'localRouteId'},
        'transfer.get' || 'transfer.cancel' || 'transfer.remove' => {'transferId'},
        'transfer.retry' => {'transferId', 'requestId'},
        _ => throw const FormatException(),
      };
      if (data.keys.any((key) => !{'operation', 'principal', 'workspaces', ...extra}.contains(key))) throw const FormatException();
      for (final key in extra) {
        if (operation == 'transfer.workspaceSend' && (key == 'files' || key == 'generation' || key == 'sourceMode')) continue;
        if ((key == 'channelId' || key == 'localRouteId') && !data.containsKey(key)) continue;
        if (data[key] is! String || _id.stringMatch(data[key] as String) != data[key]) throw const FormatException();
      }
      List<Map<String, String>>? workspaceFiles;
      var documentSnapshot = false;
      if (operation == 'transfer.workspaceSend') {
        if (data['generation'] is! int || (data['generation'] as int) < 1 || data['files'] is! List) throw const FormatException();
        if (data.containsKey('sourceMode') && data['sourceMode'] != 'documentSnapshot') throw const FormatException();
        documentSnapshot = data['sourceMode'] == 'documentSnapshot';
        final items = data['files'] as List;
        final documentIds = <String>{};
        if (items.isEmpty || items.length > 128) throw const FormatException();
        workspaceFiles = items.map((item) {
          if (documentSnapshot) {
            if (item is! Map || item.length != 1 || item['id'] is! String) throw const FormatException();
            final id = item['id'] as String;
            if (_principalId.stringMatch(id) != id || !documentIds.add(id.toLowerCase())) throw const FormatException();
            return {'id': id};
          }
          if (item is! Map || item.length != 2 || item['id'] is! String || item['version'] is! String) throw const FormatException();
          return {'id': item['id'] as String, 'version': item['version'] as String};
        }).toList();
      }
      if (!await claim()) throw const _Failure(503, 'management_claim_rejected');
      // Re-read ownership and selection at claim. Workspace source I/O runs in
      // a separate lane; its receipt slot is reserved before the first await.
      if (operation == 'transfer.devices' || operation == 'transfer.device') {
        final devices = _devices();
        if (operation == 'transfer.device') {
          final device = devices[data['deviceId']];
          if (device == null) throw const _Failure(404, 'device_not_found');
          return response(200, {'device': _device(data['deviceId'] as String, device)});
        }
        final localRoutes = [
          for (final route in refreshLocalRoutes().entries)
            {
              'id': route.key,
              'interfaceName': route.value.interfaceName,
              'address': route.value.localAddress,
              'binding': route.value.androidNetworkHandle != null
                  ? 'androidNetwork'
                  : interfaceBinding
                  ? 'interfaceAndSource'
                  : 'sourceOnly',
            },
        ];
        final summaries = <Map<String, Object?>>[];
        var size = utf8.encode(jsonEncode(localRoutes)).length;
        for (final entry in devices.entries) {
          final summary = _device(entry.key, entry.value);
          final next = utf8.encode(jsonEncode(summary)).length;
          if (size + next > 200 * 1024) break;
          summaries.add(summary);
          size += next;
        }
        return response(200, {
          'devices': summaries,
          'localRoutes': localRoutes,
          'truncated': summaries.length < devices.length || readDevices().length > 512,
          'scanState': _scanning
              ? 'running'
              : _scanFailed
              ? 'failed'
              : 'idle',
        });
      }
      if (operation == 'transfer.scan') {
        final now = clock();
        final coalesced = _scanning || _lastScan != null && now.difference(_lastScan!) < const Duration(seconds: 5);
        if (!coalesced) {
          _scanning = true;
          _scanFailed = false;
          _lastScan = now;
          unawaited(
            Future<void>.sync(scan)
                .catchError((Object _) {
                  _scanFailed = true;
                })
                .whenComplete(() => _scanning = false),
          );
        }
        return response(202, {'accepted': true, 'coalesced': coalesced});
      }
      if (operation == 'transfer.selection') {
        final files = _selected();
        final manifest = <Map<String, Object?>>[];
        var size = 0;
        for (final file in files.take(100)) {
          final entry = {'name': _label(file.name.replaceAll('\\', '/').split('/').last, 1024), 'size': file.size};
          final next = utf8.encode(jsonEncode(entry)).length;
          if (size + next > 200 * 1024) break;
          manifest.add(entry);
          size += next;
        }
        return response(200, {
          'selectionVersion': _selectionVersion,
          'totalCount': files.length,
          'totalBytes': files.fold<int>(0, (sum, file) => sum + file.size),
          'truncated': files.length > manifest.length,
          'files': manifest,
        });
      }
      if (operation == 'transfer.list') {
        final tasks = [
          for (final entry in _tasks.entries)
            if (entry.value.principal == principal && !entry.value.removed) _task(entry.key, entry.value),
        ];
        return response(200, {'tasks': tasks.where((task) => task['removed'] != true).toList()});
      }
      if (operation == 'transfer.send' || operation == 'transfer.retry' || operation == 'transfer.workspaceSend') {
        final receiptKey = '$principal:${data['requestId']}';
        final payload = operation == 'transfer.workspaceSend'
            ? jsonEncode([
                operation,
                data['instanceId'],
                data['workspaceId'],
                data['generation'],
                data['deviceId'],
                data['channelId'],
                data['localRouteId'],
                workspaceFiles,
                if (documentSnapshot) 'documentSnapshot',
              ])
            : operation == 'transfer.send'
            ? jsonEncode([operation, data['deviceId'], data['selectionVersion'], data['channelId'], data['localRouteId']])
            : jsonEncode([operation, data['transferId']]);
        final inflight = _inflightSources[receiptKey];
        if (inflight != null && inflight != payload) throw const _Failure(409, 'idempotency_conflict');
        final receipt = _receipts[receiptKey];
        if (receipt != null) {
          if (receipt.payload != payload) throw const _Failure(409, 'idempotency_conflict');
          return response(202, {'task': _task(receipt.taskId, _tasks[receipt.taskId]!), 'replayed': true});
        }
        if (_receipts.length + _inflightSources.length >= receiptLimit || readJobs().where((job) => !job.terminal).length >= 128) {
          throw const _Failure(429, 'transfer_queue_full');
        }
        late Device target;
        late List<CrossFile> files;
        late HttpChannel channel;
        late String deviceId;
        String? retryOf;
        String? localRouteId = data['localRouteId'] as String?;
        LocalSendRoute? localRoute;
        if (operation == 'transfer.send' || operation == 'transfer.workspaceSend') {
          files = operation == 'transfer.send' ? _selected() : [];
          if (operation == 'transfer.send') {
            if (data['selectionVersion'] != _selectionVersion) throw const _Failure(409, 'selection_changed');
            if (files.isEmpty) throw const _Failure(409, 'empty_selection');
          }
          deviceId = data['deviceId'] as String;
          final device = _devices()[deviceId];
          if (device == null) throw const _Failure(404, 'device_not_found');
          target = device;
          final channels = device.channels.whereType<HttpChannel>().take(32);
          final selected = data['channelId'] == null
              ? channels.firstOrNull
              : channels.where((c) => _channelIds[_channelKey(deviceId, c)] == data['channelId']).firstOrNull;
          if (selected == null) throw const _Failure(404, 'channel_not_found');
          channel = selected;
        } else {
          retryOf = data['transferId'] as String;
          final owned = _tasks[retryOf];
          final job = readJobs().where((job) => job.id == retryOf).firstOrNull;
          if (owned == null || owned.principal != principal || owned.removed || job == null) throw const _Failure(404, 'transfer_not_found');
          if (!job.terminal) throw const _Failure(409, 'transfer_not_terminal');
          localRouteId = owned.localRouteId;
          localRoute = job.localRoute;
          target = job.target;
          files = job.files;
          deviceId = owned.deviceId;
          final selected = job.selectedChannel;
          if (selected == null) throw const _Failure(404, 'channel_not_found');
          channel = selected;
        }
        if (localRouteId != null) {
          final current = _resolveLocalRoute(localRouteId);
          if (localRoute != null && current != localRoute) throw const _Failure(409, 'local_route_unavailable');
          localRoute = current;
        }
        if (localRoute != null && !localSendRouteMatchesHost(localRoute, channel.host)) throw const _Failure(409, 'local_route_unavailable');
        String id;
        if (operation == 'transfer.workspaceSend') {
          final capture = documentSnapshot ? captureDocumentWorkspace : captureWorkspace;
          final ownedQueue = enqueueOwned;
          if (capture == null || (enqueueCaptured == null && (documentSnapshot || ownedQueue == null))) {
            throw const _Failure(503, 'workspace_send_unavailable');
          }
          _inflightSources[receiptKey] = payload;
          reservedSource = receiptKey;
          final captured = await capture(data['workspaceId'] as String, data['generation'] as int, workspaceFiles!);
          try {
            if (!captured.isCurrent()) throw const _Failure(409, 'workspace_changed');
            // A refreshed discovery entry must still identify the pinned peer/channel.
            final live = _devices()[deviceId];
            if (live == null ||
                !live.channels.whereType<HttpChannel>().any((entry) => _channelKey(deviceId, entry) == _channelKey(deviceId, channel))) {
              throw const _Failure(409, 'device_changed');
            }
            if (localRoute != null) {
              if (localRouteId == null || _resolveLocalRoute(localRouteId) != localRoute || (enqueueOwnedRouted == null && enqueueCaptured == null)) {
                throw const _Failure(409, 'local_route_unavailable');
              }
            }
            if (enqueueCaptured != null) {
              id = await enqueueCaptured!(target, captured, channel, localRoute);
            } else if (localRoute != null) {
              id = await enqueueOwnedRouted!(target, captured.files, channel, localRoute);
            } else {
              id = await ownedQueue!(target, captured.files, channel);
            }
          } finally {
            // The queue owns persistent copies before the short-lived export is removed.
            try {
              await captured.release();
            } catch (_) {
              /* An accepted task must retain its receipt even if stage cleanup fails. */
            }
          }
        } else {
          if (localRoute != null) {
            if (enqueueRouted == null) throw const _Failure(409, 'local_route_unavailable');
            id = enqueueRouted!(target, files, channel, localRoute);
          } else {
            id = enqueue(target, files, channel);
          }
        }
        final owned = _OwnedTask(principal, deviceId, retryOf, {'id': id}, localRouteId: localRouteId);
        _tasks[id] = owned;
        _receipts[receiptKey] = (payload: payload, taskId: id);
        return response(202, {'task': _task(id, owned), 'replayed': false});
      }
      final id = data['transferId'] as String;
      final owned = _tasks[id];
      final job = readJobs().where((job) => job.id == id).firstOrNull;
      if (owned == null || owned.principal != principal || owned.removed || job == null) throw const _Failure(404, 'transfer_not_found');
      if (operation == 'transfer.cancel') await cancel(id);
      if (operation == 'transfer.remove') {
        if (!job.terminal) throw const _Failure(409, 'transfer_not_terminal');
        _task(id, owned);
        await remove(id);
        if (readJobs().any((job) => job.id == id)) throw const _Failure(409, 'transfer_busy');
        owned.removed = true;
        return response(200, {'removed': true, 'id': id});
      }
      return response(200, {'task': _task(id, owned)});
    } on _Failure catch (error) {
      return response(error.status, {
        'error': {'code': error.code},
      });
    } on FormatException {
      return response(400, {
        'error': {'code': 'invalid_transfer_request'},
      });
    } catch (_) {
      return response(503, {
        'error': {'code': 'transfer_management_unavailable'},
      });
    } finally {
      if (reservedSource != null) _inflightSources.remove(reservedSource);
    }
  });
}
