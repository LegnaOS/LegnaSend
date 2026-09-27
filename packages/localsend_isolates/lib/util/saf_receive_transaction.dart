import 'package:flutter/services.dart';
import 'package:localsend_isolates/rust/api/server.dart' as native_server;
import 'package:logging/logging.dart';

final _cleanupLogger = Logger('SafRecoveryCleanup');
const _channel = MethodChannel('org.localsend.localsend_app/localsend');
final _transactionId = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Capability preparation only. No native descriptor or transfer token crosses
/// this facade, and the ordinary receive path is not switched to this protocol.
class SafReceivePreparation {
  final String transactionId;
  final String cacheUri;
  final String stagingUri;

  const SafReceivePreparation({required this.transactionId, required this.cacheUri, required this.stagingUri});
}

/// Incomplete cleanup preserves the platform journal for a later attempt.
/// The lists contain actual provider URIs, never filename-derived guesses.
class SafReceiveAbortResult {
  final String transactionId;
  final List<String> deleted;
  final List<String> retained;
  final List<String> reasons;
  final bool complete;

  const SafReceiveAbortResult({
    required this.transactionId,
    required this.deleted,
    required this.retained,
    required this.complete,
    this.reasons = const [],
  });
}

String _contentUri(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null || uri.scheme != 'content' || uri.authority.isEmpty || uri.hasQuery || uri.hasFragment) {
    throw const FormatException('Expected an actual provider document URI');
  }
  return value! as String;
}

bool _sameTreeDocument(String tree, String document) {
  final root = Uri.parse(tree);
  final actual = Uri.parse(document);
  final rootParts = root.pathSegments;
  final parts = actual.pathSegments;
  return root.authority == actual.authority &&
      rootParts.length == 2 &&
      rootParts.first == 'tree' &&
      parts.length == 4 &&
      parts[0] == 'tree' &&
      parts[1] == rootParts[1] &&
      parts[2] == 'document' &&
      parts[3].isNotEmpty;
}

void _identifier(String value) {
  if (value.isEmpty || value.length > 256 || value.codeUnits.any((c) => c < 32 || c == 127)) {
    throw ArgumentError('Invalid receive attempt identity');
  }
}

Future<SafReceivePreparation> beginSafReceiveTransaction({
  required String treeUri,
  required String parentUri,
  required String fileName,
  required String sessionId,
  required String fileId,
  required String attemptId,
}) async {
  _contentUri(treeUri);
  _contentUri(parentUri);
  if (!_sameTreeDocument(treeUri, parentUri)) throw ArgumentError('Destination document tree differs');
  if (fileName.isEmpty ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.contains('/') ||
      fileName.contains(r'\') ||
      fileName.codeUnits.any((c) => c < 32 || c == 127)) {
    throw ArgumentError('Expected a single destination name');
  }
  for (final value in [sessionId, fileId, attemptId]) {
    _identifier(value);
  }
  final result = await _channel.invokeMapMethod<String, dynamic>('beginSafReceiveTransaction', {
    'treeUri': treeUri,
    'parentUri': parentUri,
    'fileName': fileName,
    'sessionId': sessionId,
    'fileId': fileId,
    'attemptId': attemptId,
  });
  if (result == null || result['transactionId'] is! String || !_transactionId.hasMatch(result['transactionId'] as String)) {
    throw const FormatException('Missing receive transaction identity');
  }
  final capabilities = result['capabilities'];
  if (result['state'] != 'ready' ||
      capabilities is! Map ||
      ['readWrite', 'seek', 'length', 'lock'].any((key) => capabilities[key] != true) ||
      result.containsKey('fd') ||
      result.containsKey('fileDescriptor')) {
    throw const FormatException('Receive cache capabilities were not established');
  }
  final cache = _contentUri(result['cacheUri']);
  final staging = _contentUri(result['stagingUri']);
  if (cache == staging || !_sameTreeDocument(treeUri, cache) || !_sameTreeDocument(treeUri, staging)) {
    throw const FormatException('Unexpected receive cache document identities');
  }
  // A malformed reply is not authority to delete guessed documents. Android
  // keeps its own durable record; no implicit abort or direct-write fallback.
  return SafReceivePreparation(transactionId: result['transactionId'] as String, cacheUri: cache, stagingUri: staging);
}

Future<SafReceiveAbortResult> abortSafReceiveTransaction(String transactionId) async {
  if (!_transactionId.hasMatch(transactionId)) throw ArgumentError('Invalid receive transaction identity');
  final result = await _channel.invokeMapMethod<String, dynamic>('abortSafReceiveTransaction', {'transactionId': transactionId});
  if (result == null || result['transactionId'] != transactionId || result['complete'] is! bool) {
    throw const FormatException('Mismatched receive cleanup result');
  }
  List<String> uris(String key) {
    final values = result[key];
    if (values is! List) throw const FormatException('Missing receive cleanup outcomes');
    final parsed = values.map(_contentUri).toList(growable: false);
    if (parsed.toSet().length != parsed.length) throw const FormatException('Duplicate receive cleanup outcomes');
    return List.unmodifiable(parsed);
  }

  final deleted = uris('deleted');
  final retained = uris('retained');
  final complete = result['complete'] as bool;
  final reasons = result['reasons'] ?? <String>[];
  if (reasons is! List || reasons.any((value) => value is! String)) {
    throw const FormatException('Invalid receive cleanup reasons');
  }
  if (deleted.any(retained.contains) || (complete && retained.isNotEmpty)) {
    throw const FormatException('Conflicting receive cleanup outcomes');
  }
  return SafReceiveAbortResult(
    transactionId: transactionId,
    deleted: deleted,
    retained: retained,
    complete: complete,
    reasons: List.unmodifiable(reasons.cast<String>()),
  );
}

/// Owned descriptors handed to the native receiver exactly once.
class SafReceiveOpen {
  final String transactionId, lease;
  final int cacheFd, stagingFd;
  const SafReceiveOpen({required this.transactionId, required this.lease, required this.cacheFd, required this.stagingFd});
}

class SafPublicationReceipt {
  final String transactionId, uri, sha256;
  final int size;
  const SafPublicationReceipt({required this.transactionId, required this.uri, required this.size, required this.sha256});
}

Future<SafReceiveOpen> openSafReceiveTransaction({
  required String transactionId,
  required String sessionId,
  required String fileId,
  required String attemptId,
}) async {
  if (!_transactionId.hasMatch(transactionId)) throw ArgumentError('Invalid receive transaction identity');
  final result = await _channel.invokeMapMethod<String, dynamic>('openSafReceiveTransaction', {
    'transactionId': transactionId,
    'sessionId': sessionId,
    'fileId': fileId,
    'attemptId': attemptId,
  });
  final cache = result?['cacheFd'];
  final staging = result?['stagingFd'];
  final lease = result?['lease'];
  if (result?['transactionId'] != transactionId ||
      lease is! String ||
      !_transactionId.hasMatch(lease) ||
      cache is! int ||
      staging is! int ||
      cache < 0 ||
      staging < 0 ||
      cache == staging) {
    // The channel is trusted platform code, not a peer. Consume every supplied
    // descriptor once even when the rest of its reply is malformed.
    await discardSafDescriptors([if (cache is int && cache >= 0) cache, if (staging is int && staging >= 0) staging]);
    if (lease is String && _transactionId.hasMatch(lease)) {
      try {
        await releaseSafReceiveTransaction(transactionId: transactionId, lease: lease, published: false);
      } catch (_) {
        /* journal retains it */
      }
    }
    throw const FormatException('Invalid receive descriptor handoff');
  }
  return SafReceiveOpen(transactionId: transactionId, lease: lease, cacheFd: cache, stagingFd: staging);
}

class SafReceiveRecovery {
  final String transactionId, identityJson;
  final int sourceFd;
  const SafReceiveRecovery({required this.transactionId, required this.identityJson, required this.sourceFd});
}

/// Await durable platform acknowledgement before writing the first cache header.
Future<SafReceiveRecovery?> bindSafReceiveCacheIdentity({
  required String transactionId,
  required String lease,
  required String coreAttemptId,
  required String identityJson,
}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(lease)) throw ArgumentError('Invalid receive identity binding');
  _identifier(coreAttemptId);
  if (identityJson.isEmpty || identityJson.length > 16384) throw ArgumentError('Invalid cache identity JSON size');
  final result = await _channel.invokeMapMethod<String, dynamic>('bindSafReceiveCacheIdentity', {
    'transactionId': transactionId,
    'lease': lease,
    'coreAttemptId': coreAttemptId,
    'identityJson': identityJson,
  });
  final recovery = result?['recovery'];
  final fd = recovery is Map ? recovery['sourceFd'] : null;
  try {
    if (result?['transactionId'] != transactionId || result?['coreAttemptId'] != coreAttemptId || result?['bound'] != true) {
      throw const FormatException('Missing durable receive cache identity acknowledgement');
    }
    if (recovery == null) return null;
    if (recovery is! Map ||
        recovery['transactionId'] is! String ||
        !_transactionId.hasMatch(recovery['transactionId'] as String) ||
        recovery['transactionId'] == transactionId ||
        recovery['identityJson'] is! String ||
        (recovery['identityJson'] as String).isEmpty ||
        (recovery['identityJson'] as String).length > 16384 ||
        fd is! int ||
        fd < 0) {
      throw const FormatException('Invalid receive recovery handoff');
    }
    return SafReceiveRecovery(transactionId: recovery['transactionId'] as String, identityJson: recovery['identityJson'] as String, sourceFd: fd);
  } catch (_) {
    if (fd is int && fd >= 0) await discardSafDescriptors([fd]);
    rethrow;
  }
}

Future<void> completeSafReceiveRecovery({
  required String transactionId,
  required String lease,
  required String coreAttemptId,
  required String sourceTransactionId,
  required int sourceLength,
  required String sourceSha256,
}) async {
  if (!_transactionId.hasMatch(transactionId) ||
      !_transactionId.hasMatch(lease) ||
      !_transactionId.hasMatch(sourceTransactionId) ||
      sourceTransactionId == transactionId) {
    throw ArgumentError('Invalid recovery completion identity');
  }
  if (sourceLength <= 0 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sourceSha256)) throw ArgumentError('Invalid recovery source digest');
  _identifier(coreAttemptId);
  final result = await _channel.invokeMapMethod<String, dynamic>('completeSafReceiveRecovery', {
    'transactionId': transactionId,
    'lease': lease,
    'coreAttemptId': coreAttemptId,
    'sourceTransactionId': sourceTransactionId,
    'sourceLength': sourceLength,
    'sourceSha256': sourceSha256.toLowerCase(),
  });
  if (result?['transactionId'] != transactionId ||
      result?['sourceTransactionId'] != sourceTransactionId ||
      result?['coreAttemptId'] != coreAttemptId ||
      result?['complete'] != true) {
    throw const FormatException('Missing receive recovery completion acknowledgement');
  }
}

Future<SafPublicationReceipt> publishSafReceiveTransaction({
  required String transactionId,
  required String lease,
  required String coreAttemptId,
  required String treeUri,
  required int size,
  required String sha256,
}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(lease) || size < 0 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
    throw ArgumentError('Invalid publication receipt identity');
  }
  final result = await _channel.invokeMapMethod<String, dynamic>('publishSafReceiveTransaction', {
    'transactionId': transactionId,
    'lease': lease,
    'coreAttemptId': coreAttemptId,
    'size': size,
    'sha256': sha256,
  });
  if (result == null ||
      result['transactionId'] != transactionId ||
      result['size'] != size ||
      result['sha256'] is! String ||
      (result['sha256'] as String).toLowerCase() != sha256.toLowerCase()) {
    throw const FormatException('Provider did not acknowledge the verified file');
  }
  final uri = _contentUri(result['uri']);
  if (!_sameTreeDocument(treeUri, uri)) throw const FormatException('Published document is outside the selected tree');
  return SafPublicationReceipt(transactionId: transactionId, uri: uri, size: size, sha256: sha256.toLowerCase());
}

/// Invoke only after Rust has closed both files (or before any Rust handoff).
/// `published: false` never overrides the provider's durable published receipt.
Future<void> releaseSafReceiveTransaction({
  required String transactionId,
  required String lease,
  required bool published,
  Future<bool> Function({required String transactionId})? publishedStagingCleanup,
}) async {
  final result = await _channel.invokeMapMethod<String, dynamic>('releaseSafReceiveTransaction', {
    'transactionId': transactionId,
    'lease': lease,
    'published': published,
  });
  if (result == null || result['transactionId'] != transactionId || result['complete'] is! bool) {
    throw const FormatException('Invalid receive release result');
  }
  if (published) {
    try {
      // Native release has drained/closed the live receive witness. Only now may
      // a separate strict cleanup guard claim its proven PUBLISHED staging.
      await (publishedStagingCleanup ?? cleanupSafPublishedStaging)(transactionId: transactionId);
    } catch (error) {
      _cleanupLogger.warning('Published staging retained for maintenance (${error.runtimeType})');
    }
  }
}

Future<void> discardSafDescriptors(Iterable<int> descriptors) async {
  await Future.wait(descriptors.toSet().map((fd) => native_server.discardDownloadSource(fileDescriptor: fd)));
}

/// Bounded inspection of private transaction records; never scans a destination
/// by extension. Ambiguous interrupted or published documents remain protected.
Future<Map<String, dynamic>> reconcileSafReceiveTransactions({
  int limit = 32,
  Future<bool> Function({required String transactionId, required String lease})? cleanup,
  Future<bool> Function({required String transactionId})? publicationReconcile,
  Future<bool> Function({required String transactionId})? publishedStagingCleanup,
}) async {
  if (limit < 1 || limit > 64) throw ArgumentError.value(limit, 'limit');
  final result = await _channel.invokeMapMethod<String, dynamic>('reconcileSafReceiveTransactions', {'limit': limit});
  if (result == null || result['truncated'] is! bool || result['reasons'] is! List || (result['reasons'] as List).any((v) => v is! String)) {
    throw const FormatException('Invalid provider reconciliation report');
  }
  for (final key in ['examined', 'removedRecords', 'deletedDocuments', 'retainedTransactions', 'activeTransactions', 'publishedReceipts']) {
    if (result[key] is! int || (result[key] as int) < 0) throw const FormatException('Invalid provider reconciliation count');
  }
  final report = Map<String, dynamic>.of(result);
  final candidates = report.remove('recoveryCleanupCandidates');
  final publicationCandidates = report.remove('publicationReconcileCandidates');
  final stagingCandidates = report.remove('publishedStagingCleanupCandidates');
  var reconciled = 0;
  final publicationSeen = <String>{};
  if (publicationCandidates is List) {
    for (final candidate in publicationCandidates.take(limit)) {
      if (candidate is! Map) continue;
      final id = candidate['transactionId'];
      if (id is! String || !_transactionId.hasMatch(id) || !publicationSeen.add(id.toLowerCase())) continue;
      try {
        final confirmed = publicationReconcile != null
            ? await publicationReconcile(transactionId: id)
            : await reconcileSafReceivePublication(transactionId: id);
        if (confirmed) reconciled++;
      } catch (_) {
        /* Preserve uncertain publication and continue other bounded records. */
      }
    }
  }
  report['publicationReconciled'] = reconciled;
  final reasons = (report['reasons'] as List).cast<String>().toList();
  for (var i = 0; i < reconciled; i++) {
    reasons.remove('PUBLICATION_AMBIGUOUS');
    reasons.add('PUBLICATION_RECONCILED');
  }
  report['reasons'] = List<String>.unmodifiable(reasons);
  var deleted = 0;
  final seen = <String>{};
  if (candidates is List) {
    for (final candidate in candidates.take(limit)) {
      if (candidate is! Map) continue;
      final id = candidate['transactionId'], lease = candidate['lease'];
      if (id is! String || !_transactionId.hasMatch(id) || lease is! String || !_transactionId.hasMatch(lease) || !seen.add(id)) continue;
      try {
        final removed = cleanup != null
            ? await cleanup(transactionId: id, lease: lease)
            : await cleanupSafReceiveRecovery(transactionId: id, lease: lease);
        if (removed) deleted++;
      } catch (_) {
        /* One unavailable provider never prevents other bounded candidates. */
      }
    }
  }
  report['recoveryDeletedCaches'] = deleted;
  var stagingDeleted = 0;
  final stagingSeen = <String>{};
  if (stagingCandidates is List) {
    for (final candidate in stagingCandidates.take(limit)) {
      if (candidate is! Map) continue;
      final id = candidate['transactionId'];
      if (id is! String || !_transactionId.hasMatch(id) || !stagingSeen.add(id.toLowerCase())) continue;
      try {
        if (await (publishedStagingCleanup ?? cleanupSafPublishedStaging)(transactionId: id)) stagingDeleted++;
      } catch (_) {
        /* Keep changed/ambiguous provider documents registered for retry. */
      }
    }
  }
  report['publishedStagingDeleted'] = stagingDeleted;
  return Map.unmodifiable(report);
}

class SafRecoveryCleanup {
  final String transactionId, sourceTransactionId, sourceSha256;
  final int sourceLength, descriptor;
  const SafRecoveryCleanup({
    required this.transactionId,
    required this.sourceTransactionId,
    required this.sourceSha256,
    required this.sourceLength,
    required this.descriptor,
  });
}

typedef SafCleanupRelease = Future<void> Function();
typedef AcquireSafCleanupGuard =
    Future<SafCleanupRelease> Function({
      required int descriptor,
      required BigInt expectedLength,
      required String expectedSha256,
    });

Future<SafRecoveryCleanup?> prepareSafRecoveryCleanup({required String transactionId, required String lease}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(lease)) throw ArgumentError('Invalid cleanup identity');
  final result = await _channel.invokeMapMethod<String, dynamic>('prepareSafRecoveryCleanup', {'transactionId': transactionId, 'lease': lease});
  if (result == null) return null;
  final descriptor = result['descriptor'], source = result['sourceTransactionId'], length = result['sourceLength'], hash = result['sourceSha256'];
  try {
    if (result['transactionId'] != transactionId ||
        source is! String ||
        !_transactionId.hasMatch(source) ||
        source == transactionId ||
        length is! int ||
        length <= 0 ||
        hash is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash) ||
        descriptor is! int ||
        descriptor < 0) {
      throw const FormatException('Invalid recovery cleanup handoff');
    }
    return SafRecoveryCleanup(
      transactionId: transactionId,
      sourceTransactionId: source,
      sourceSha256: hash.toLowerCase(),
      sourceLength: length,
      descriptor: descriptor,
    );
  } catch (_) {
    if (descriptor is int && descriptor >= 0) await discardSafDescriptors([descriptor]);
    if (source is String && _transactionId.hasMatch(source) && source != transactionId) {
      await finishSafRecoveryCleanup(transactionId: transactionId, sourceTransactionId: source);
    }
    rethrow;
  }
}

Future<bool> deleteSafRecoveryCleanup({required String transactionId, required String lease, required String sourceTransactionId}) async {
  if (!_transactionId.hasMatch(transactionId) ||
      !_transactionId.hasMatch(lease) ||
      !_transactionId.hasMatch(sourceTransactionId) ||
      sourceTransactionId == transactionId) {
    throw ArgumentError('Invalid cleanup deletion identity');
  }
  final result = await _channel.invokeMethod<bool>('deleteSafRecoveryCleanup', {
    'transactionId': transactionId,
    'lease': lease,
    'sourceTransactionId': sourceTransactionId,
  });
  if (result == null) throw const FormatException('Missing recovery cleanup result');
  return result;
}

Future<void> finishSafRecoveryCleanup({required String transactionId, required String sourceTransactionId}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(sourceTransactionId) || sourceTransactionId == transactionId) {
    throw ArgumentError('Invalid cleanup completion identity');
  }
  await _channel.invokeMethod<void>('finishSafRecoveryCleanup', {'transactionId': transactionId, 'sourceTransactionId': sourceTransactionId});
}

/// Both native and Rust witnesses remain alive until deletion has actually
/// returned. No timeout is evidence that a provider operation has drained.
Future<bool> cleanupSafReceiveRecovery({required String transactionId, required String lease, AcquireSafCleanupGuard? acquireGuard}) async {
  final prepared = await prepareSafRecoveryCleanup(transactionId: transactionId, lease: lease);
  if (prepared == null) return false;
  SafCleanupRelease? release;
  try {
    if (acquireGuard != null) {
      release = await acquireGuard(
        descriptor: prepared.descriptor,
        expectedLength: BigInt.from(prepared.sourceLength),
        expectedSha256: prepared.sourceSha256,
      );
    } else {
      final guard = await native_server.acquireReceiveCleanupGuard(
        descriptor: prepared.descriptor,
        expectedLength: BigInt.from(prepared.sourceLength),
        expectedSha256: prepared.sourceSha256,
      );
      release = guard.release;
    }
    return await deleteSafRecoveryCleanup(transactionId: transactionId, lease: lease, sourceTransactionId: prepared.sourceTransactionId);
  } finally {
    try {
      await release?.call();
    } catch (error) {
      _cleanupLogger.warning('Recovery cleanup guard finalization failed (${error.runtimeType})');
    }
    try {
      await finishSafRecoveryCleanup(transactionId: transactionId, sourceTransactionId: prepared.sourceTransactionId);
    } catch (error) {
      _cleanupLogger.warning('Recovery cleanup witness finalization failed (${error.runtimeType})');
    }
  }
}

/// A detached read-only output FD and a native witness. Preparation alone is
/// neither publication proof nor permission to rewrite/delete any document.
class SafPublicationReconcile {
  final String transactionId, reconciliationId, sha256;
  final int fileDescriptor, size;
  const SafPublicationReconcile({
    required this.transactionId,
    required this.reconciliationId,
    required this.sha256,
    required this.fileDescriptor,
    required this.size,
  });
}

typedef AcquireSafPublicationGuard =
    Future<SafCleanupRelease> Function({required int fileDescriptor, required BigInt length, required String sha256});

Future<SafPublicationReconcile?> prepareSafReceivePublicationReconcile({required String transactionId}) async {
  if (!_transactionId.hasMatch(transactionId)) throw ArgumentError('Invalid publication transaction identity');
  final result = await _channel.invokeMapMethod<String, dynamic>('prepareSafReceivePublicationReconcile', {'transactionId': transactionId});
  if (result == null) return null;
  final fd = result['fileDescriptor'], reconciliation = result['reconciliationId'], size = result['size'], hash = result['sha256'];
  if (result['transactionId'] != transactionId ||
      reconciliation is! String ||
      !_transactionId.hasMatch(reconciliation) ||
      fd is! int ||
      fd < 0 ||
      fd > 0x7fffffff ||
      size is! int ||
      size < 0 ||
      hash is! String ||
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
    // Invalid replies still transfer every valid FD. Finalizers are independent:
    // failure to close one handle must not suppress the native witness finish.
    if (fd is int && fd >= 0 && fd <= 0x7fffffff) {
      try {
        await discardSafDescriptors([fd]);
      } catch (error) {
        _cleanupLogger.warning('Publication descriptor finalization failed (${error.runtimeType})');
      }
    }
    if (reconciliation is String && _transactionId.hasMatch(reconciliation)) {
      try {
        await finishSafReceivePublicationReconcile(transactionId: transactionId, reconciliationId: reconciliation);
      } catch (error) {
        _cleanupLogger.warning('Publication witness finalization failed (${error.runtimeType})');
      }
    }
    throw const FormatException('Invalid publication reconciliation handoff');
  }
  return SafPublicationReconcile(
    transactionId: transactionId,
    reconciliationId: reconciliation,
    sha256: hash.toLowerCase(),
    fileDescriptor: fd,
    size: size,
  );
}

Future<void> confirmSafReceivePublicationReconcile({required String transactionId, required String reconciliationId}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(reconciliationId)) {
    throw ArgumentError('Invalid publication reconciliation identity');
  }
  final result = await _channel.invokeMapMethod<String, dynamic>('confirmSafReceivePublicationReconcile', {
    'transactionId': transactionId,
    'reconciliationId': reconciliationId,
  });
  if (result?['transactionId'] != transactionId || result?['reconciled'] != true) {
    throw const FormatException('Missing persistent publication confirmation');
  }
}

Future<void> finishSafReceivePublicationReconcile({required String transactionId, required String reconciliationId}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(reconciliationId)) {
    throw ArgumentError('Invalid publication reconciliation completion identity');
  }
  await _channel.invokeMethod<void>('finishSafReceivePublicationReconcile', {'transactionId': transactionId, 'reconciliationId': reconciliationId});
}

/// Rust adopts the FD even when hashing/strict shared locking rejects it. Hold
/// the guard until native confirmation truly returns, then finish both witnesses.
/// Finalization failure must not erase an already durable publication receipt.
Future<bool> reconcileSafReceivePublication({required String transactionId, AcquireSafPublicationGuard? acquireGuard}) async {
  final prepared = await prepareSafReceivePublicationReconcile(transactionId: transactionId);
  if (prepared == null) return false;
  SafCleanupRelease? release;
  try {
    if (acquireGuard != null) {
      release = await acquireGuard(fileDescriptor: prepared.fileDescriptor, length: BigInt.from(prepared.size), sha256: prepared.sha256);
    } else {
      final guard = await native_server.acquireReceivePublicationGuard(
        fileDescriptor: prepared.fileDescriptor,
        length: BigInt.from(prepared.size),
        sha256: prepared.sha256,
      );
      release = guard.release;
    }
    await confirmSafReceivePublicationReconcile(transactionId: transactionId, reconciliationId: prepared.reconciliationId);
    return true;
  } finally {
    try {
      await release?.call();
    } catch (error) {
      _cleanupLogger.warning('Publication guard finalization failed (${error.runtimeType})');
    }
    try {
      await finishSafReceivePublicationReconcile(transactionId: transactionId, reconciliationId: prepared.reconciliationId);
    } catch (error) {
      _cleanupLogger.warning('Publication witness finalization failed (${error.runtimeType})');
    }
  }
}

class SafPublishedStagingCleanup {
  final String transactionId, cleanupId, sha256;
  final int descriptor, length;
  const SafPublishedStagingCleanup({
    required this.transactionId,
    required this.cleanupId,
    required this.sha256,
    required this.descriptor,
    required this.length,
  });
}

Future<SafPublishedStagingCleanup?> prepareSafPublishedStagingCleanup({required String transactionId}) async {
  if (!_transactionId.hasMatch(transactionId)) throw ArgumentError('Invalid published staging identity');
  final result = await _channel.invokeMapMethod<String, dynamic>('prepareSafPublishedStagingCleanup', {'transactionId': transactionId});
  if (result == null) return null;
  final fd = result['descriptor'], cleanup = result['cleanupId'], length = result['length'], hash = result['sha256'];
  if (result['transactionId'] != transactionId ||
      cleanup is! String ||
      !_transactionId.hasMatch(cleanup) ||
      fd is! int ||
      fd < 0 ||
      fd > 0x7fffffff ||
      length is! int ||
      length < 0 ||
      hash is! String ||
      !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
    if (fd is int && fd >= 0 && fd <= 0x7fffffff) {
      try {
        await discardSafDescriptors([fd]);
      } catch (error) {
        _cleanupLogger.warning('Published staging descriptor finalization failed (${error.runtimeType})');
      }
    }
    if (cleanup is String && _transactionId.hasMatch(cleanup)) {
      try {
        await finishSafPublishedStagingCleanup(transactionId: transactionId, cleanupId: cleanup);
      } catch (error) {
        _cleanupLogger.warning('Published staging witness finalization failed (${error.runtimeType})');
      }
    }
    throw const FormatException('Invalid published staging cleanup handoff');
  }
  return SafPublishedStagingCleanup(transactionId: transactionId, cleanupId: cleanup, descriptor: fd, length: length, sha256: hash.toLowerCase());
}

Future<bool> deleteSafPublishedStagingCleanup({required String transactionId, required String cleanupId}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(cleanupId)) throw ArgumentError('Invalid staging deletion identity');
  final result = await _channel.invokeMethod<bool>('deleteSafPublishedStagingCleanup', {'transactionId': transactionId, 'cleanupId': cleanupId});
  if (result == null) throw const FormatException('Missing published staging deletion result');
  return result;
}

Future<void> finishSafPublishedStagingCleanup({required String transactionId, required String cleanupId}) async {
  if (!_transactionId.hasMatch(transactionId) || !_transactionId.hasMatch(cleanupId)) throw ArgumentError('Invalid staging completion identity');
  await _channel.invokeMethod<void>('finishSafPublishedStagingCleanup', {'transactionId': transactionId, 'cleanupId': cleanupId});
}

/// The independently opened staging FD is consumed once by Rust, even when its
/// strict EX lock or proof is rejected. Keep that guard until delete really ends.
Future<bool> cleanupSafPublishedStaging({required String transactionId, AcquireSafCleanupGuard? acquireGuard}) async {
  final prepared = await prepareSafPublishedStagingCleanup(transactionId: transactionId);
  if (prepared == null) return false;
  SafCleanupRelease? release;
  try {
    if (acquireGuard != null) {
      release = await acquireGuard(descriptor: prepared.descriptor, expectedLength: BigInt.from(prepared.length), expectedSha256: prepared.sha256);
    } else {
      final guard = await native_server.acquireReceiveCleanupGuard(
        descriptor: prepared.descriptor,
        expectedLength: BigInt.from(prepared.length),
        expectedSha256: prepared.sha256,
      );
      release = guard.release;
    }
    return await deleteSafPublishedStagingCleanup(transactionId: transactionId, cleanupId: prepared.cleanupId);
  } finally {
    // Both finalizers are attempted; a known successful unlink stays successful
    // even when releasing a witness fails. Never log IDs or provider exceptions.
    try {
      await release?.call();
    } catch (error) {
      _cleanupLogger.warning('Published staging guard finalization failed (${error.runtimeType})');
    }
    try {
      await finishSafPublishedStagingCleanup(transactionId: transactionId, cleanupId: prepared.cleanupId);
    } catch (error) {
      _cleanupLogger.warning('Published staging witness finalization failed (${error.runtimeType})');
    }
  }
}
