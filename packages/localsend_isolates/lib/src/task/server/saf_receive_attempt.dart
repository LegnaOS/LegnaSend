import 'package:localsend_isolates/util/saf_receive_transaction.dart';
import 'package:uuid/uuid.dart';

/// One whole-file attempt; retries create a new transaction, never reopen a
/// published output. Provider IDs and desired names are kept separate.
class SafReceiveAttempt {
  final String treeUri, parentUri, fileName, sessionId, fileId, attemptId;
  final SafReceivePreparation preparation;
  final SafReceiveOpen opened;
  bool descriptorsHandedOff = false;
  String? publishedUri;
  String? coreAttemptId;
  int? _publicationSize;
  String? _publicationHash;
  Future<void>? publicationWork;
  Future<void>? identityWork;
  Future<void>? recoveryWork;
  int? _recoverySourceLength;
  String? _recoverySourceHash;
  Future<bool>? _identityResponseWork;
  SafReceiveRecovery? recovery;
  bool _recoveryHandedOff = false;
  bool _recoveryClosed = false;
  Future<void>? _recoveryCloseWork;
  String? _identityJson;
  Future<void>? _releaseWork;

  SafReceiveAttempt({
    required this.treeUri,
    required this.parentUri,
    required this.fileName,
    required this.sessionId,
    required this.fileId,
    required this.attemptId,
    required this.preparation,
    required this.opened,
  });
  String get transactionId => preparation.transactionId;

  /// The native probe consumes both descriptors even when capability is absent.
  /// This is a disposable preparation, never a published receive output.
  Future<bool> probeDescriptors({
    required Future<bool> Function({required int cacheDescriptor, required int stagingDescriptor}) probe,
    required bool Function() isActive,
  }) async {
    var cleanupAllowed = !descriptorsHandedOff;
    try {
      if (!isActive()) return false;
      if (descriptorsHandedOff) throw StateError('Receive descriptors already consumed');
      descriptorsHandedOff = true;
      // A synchronous bridge failure does not prove that Rust took ownership.
      // Preserve the journal and avoid either a guessed close or a release.
      cleanupAllowed = false;
      final pending = probe(cacheDescriptor: opened.cacheFd, stagingDescriptor: opened.stagingFd);
      cleanupAllowed = true;
      final supported = await pending;
      return supported && isActive();
    } finally {
      if (cleanupAllowed) await finish();
    }
  }

  /// Persist the exact core identity before Rust writes resumable cache bytes.
  /// Identical duplicate events share one native operation; changed identities
  /// or attempts never overwrite an already bound provider journal.
  Future<void> bindIdentity({required String coreAttemptId, required String identityJson}) {
    if (_releaseWork != null) throw StateError('Receive attempt is already releasing');
    if (this.coreAttemptId != null && this.coreAttemptId != coreAttemptId) throw StateError('Identity belongs to another attempt');
    if (identityWork != null && _identityJson != identityJson) throw StateError('Receive cache identity changed');
    this.coreAttemptId = coreAttemptId;
    _identityJson = identityJson;
    return identityWork ??= () async {
      recovery = await bindSafReceiveCacheIdentity(
        transactionId: transactionId,
        lease: opened.lease,
        coreAttemptId: coreAttemptId,
        identityJson: identityJson,
      );
    }();
  }

  Future<void> closeUnclaimedRecovery() async {
    final candidate = recovery;
    if (candidate == null || _recoveryHandedOff) return;
    _recoveryClosed = true;
    await (_recoveryCloseWork ??= discardSafDescriptors([candidate.sourceFd]));
  }

  Future<bool> replyIdentity(Future<bool> Function(SafReceiveRecovery?) reply) {
    if (_releaseWork != null) throw StateError('Receive attempt is already releasing');
    return _identityResponseWork ??= () async {
      if (recovery != null && _recoveryClosed) throw StateError('Recovery source already closed');
      _recoveryHandedOff = recovery != null;
      return await reply(recovery);
    }();
  }

  Future<void> completeRecovery({
    required String coreAttemptId,
    required String sourceTransactionId,
    required int sourceLength,
    required String sourceSha256,
  }) {
    if (_releaseWork != null || this.coreAttemptId != coreAttemptId || !_recoveryHandedOff || recovery?.transactionId != sourceTransactionId) {
      throw StateError('Recovery has no matching handed-off source');
    }
    if (recoveryWork != null && (_recoverySourceLength != sourceLength || _recoverySourceHash != sourceSha256.toLowerCase())) {
      throw StateError('Recovered source digest changed');
    }
    _recoverySourceLength = sourceLength;
    _recoverySourceHash = sourceSha256.toLowerCase();
    return recoveryWork ??= completeSafReceiveRecovery(
      transactionId: transactionId,
      lease: opened.lease,
      coreAttemptId: coreAttemptId,
      sourceTransactionId: sourceTransactionId,
      sourceLength: sourceLength,
      sourceSha256: sourceSha256,
    );
  }

  Future<void> publish({required String attemptId, required int size, required String sha256}) {
    if (coreAttemptId != null && coreAttemptId != attemptId) throw StateError('Publication belongs to another attempt');
    if (publicationWork != null && (_publicationSize != size || _publicationHash != sha256.toLowerCase())) {
      throw StateError('Publication content differs from the verified receipt');
    }
    coreAttemptId = attemptId;
    _publicationSize = size;
    _publicationHash = sha256.toLowerCase();
    return publicationWork ??= () async {
      await identityWork;
      if (recovery != null && recoveryWork == null) throw StateError('Recovery completion has not been acknowledged');
      if (recoveryWork != null) await recoveryWork;
      final receipt = await publishSafReceiveTransaction(
        transactionId: transactionId,
        lease: opened.lease,
        coreAttemptId: attemptId,
        treeUri: treeUri,
        size: size,
        sha256: sha256,
      );
      publishedUri = receipt.uri;
    }();
  }

  /// Call only after the upload result/progress stream has drained. Wait for a
  /// late identity registration and provider copy before cleanup, even when core timed out.
  Future<void> finish({AcquireSafCleanupGuard? acquireCleanupGuard}) => _releaseWork ??= () async {
    if (!descriptorsHandedOff) {
      descriptorsHandedOff = true;
      await discardSafDescriptors([opened.cacheFd, opened.stagingFd]);
    }
    try {
      await identityWork;
    } catch (_) {
      /* failed binding is retained in the authoritative provider journal */
    }
    // A bridge failure cannot prove consumption of the source descriptor.
    // Keep its claim rather than releasing resources under an uncertain reader.
    await _identityResponseWork;
    try {
      await recoveryWork;
    } catch (_) {
      /* source claim remains authoritative until native release */
    }
    await closeUnclaimedRecovery();
    try {
      await publicationWork;
    } catch (_) {
      /* provider journal owns ambiguity */
    }
    if (publishedUri != null && recovery != null) {
      try {
        await cleanupSafReceiveRecovery(transactionId: transactionId, lease: opened.lease, acquireGuard: acquireCleanupGuard);
      } catch (_) {
        /* Cleanup is optional: retain old cache and keep the published receipt. */
      }
    }
    await releaseSafReceiveTransaction(transactionId: transactionId, lease: opened.lease, published: publishedUri != null);
  }();
}

Future<SafReceiveAttempt> prepareSafReceiveAttempt({
  required String treeUri,
  required String parentUri,
  required String fileName,
  required String sessionId,
  required String fileId,
}) async {
  final attemptId = const Uuid().v4();
  final prepared = await beginSafReceiveTransaction(
    treeUri: treeUri,
    parentUri: parentUri,
    fileName: fileName,
    sessionId: sessionId,
    fileId: fileId,
    attemptId: attemptId,
  );
  try {
    final opened = await openSafReceiveTransaction(transactionId: prepared.transactionId, sessionId: sessionId, fileId: fileId, attemptId: attemptId);
    return SafReceiveAttempt(
      treeUri: treeUri,
      parentUri: parentUri,
      fileName: fileName,
      sessionId: sessionId,
      fileId: fileId,
      attemptId: attemptId,
      preparation: prepared,
      opened: opened,
    );
  } catch (_) {
    try {
      await abortSafReceiveTransaction(prepared.transactionId);
    } catch (_) {
      /* retain durable record */
    }
    rethrow;
  }
}

/// Resolve the native publication before sending the protocol acknowledgement.
/// The callback is the existing server event responder, not a side channel.
Future<void> answerSafPublication({
  required SafReceiveAttempt? attempt,
  required String sessionId,
  required String fileId,
  required String transactionId,
  required String coreAttemptId,
  required int size,
  required String sha256,
  required bool Function() isActive,
  required Future<bool> Function(String? error) reply,
}) async {
  String? error;
  try {
    if (attempt == null || attempt.transactionId != transactionId || attempt.sessionId != sessionId || attempt.fileId != fileId || !isActive()) {
      throw StateError('Publication has no matching active receive attempt');
    }
    await attempt.publish(attemptId: coreAttemptId, size: size, sha256: sha256);
  } catch (failure) {
    error = failure.toString();
  }
  await reply(error);
}

/// The core waits on its identity responder; no upload is authorized by a late
/// success after the listener, session or exact provider attempt was replaced.
Future<void> answerSafCacheIdentity({
  required SafReceiveAttempt? attempt,
  required String sessionId,
  required String fileId,
  required String transactionId,
  required String coreAttemptId,
  required String identityJson,
  required bool Function() isActive,
  required Future<bool> Function(String? error, SafReceiveRecovery? recovery) reply,
}) async {
  String? error;
  try {
    if (attempt == null || attempt.transactionId != transactionId || attempt.sessionId != sessionId || attempt.fileId != fileId || !isActive()) {
      throw StateError('Identity has no matching active receive attempt');
    }
    await attempt.bindIdentity(coreAttemptId: coreAttemptId, identityJson: identityJson);
    if (!isActive()) {
      await attempt.closeUnclaimedRecovery();
      throw StateError('Receive identity attempt is no longer active');
    }
    await attempt.replyIdentity((recovery) => reply(null, recovery));
    return;
  } catch (_) {
    error = 'Receive cache identity registration failed';
  }
  await reply(error, null);
}

Future<void> answerSafCacheRecovered({
  required SafReceiveAttempt? attempt,
  required String sessionId,
  required String fileId,
  required String transactionId,
  required String coreAttemptId,
  required String sourceTransactionId,
  required int sourceLength,
  required String sourceSha256,
  required bool Function() isActive,
  required Future<bool> Function(String? error) reply,
}) async {
  String? error;
  try {
    if (attempt == null || attempt.sessionId != sessionId || attempt.fileId != fileId || attempt.transactionId != transactionId || !isActive()) {
      throw StateError('Recovery completion has no active receive attempt');
    }
    await attempt.completeRecovery(
      coreAttemptId: coreAttemptId,
      sourceTransactionId: sourceTransactionId,
      sourceLength: sourceLength,
      sourceSha256: sourceSha256,
    );
    if (!isActive()) throw StateError('Recovery attempt is no longer active');
  } catch (_) {
    error = 'Receive cache recovery completion failed';
  }
  await reply(error);
}
