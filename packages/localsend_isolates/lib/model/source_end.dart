/// Resource-scoped receiver authorization. Never include this value in logs,
/// ordinary task JSON, preferences exports or application presentation state.
class SourceEndGrant {
  final int version;
  final String grantId;
  final String round;
  final String token;
  final int expiresAtUnixMs;
  const SourceEndGrant({required this.version, required this.grantId, required this.round, required this.token, required this.expiresAtUnixMs});
  @override
  String toString() => 'SourceEndGrant(redacted)';
}

enum SourceEndOutcome {
  cleared,
  publishedPreserved,
  active,
  publicationPending,
  retainedUnknown,
  unknownOrExpired,
  superseded,
  authorizationRequired,
}

class SourceEndResult {
  final SourceEndOutcome outcome;
  final String? receiptId;
  final int removedFiles;
  final int unlinkedBytes;
  const SourceEndResult({required this.outcome, this.receiptId, this.removedFiles = 0, this.unlinkedBytes = 0});
}
