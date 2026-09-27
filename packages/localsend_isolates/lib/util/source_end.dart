import 'package:localsend_isolates/model/source_end.dart';
import 'package:localsend_isolates/rust/api/http.dart';

SourceEndGrant decodeSourceEndGrant(RsSourceEndGrant value) => SourceEndGrant(
  version: value.version,
  grantId: value.grantId,
  round: value.round,
  token: value.token,
  expiresAtUnixMs: value.expiresAtUnixMs.toInt(),
);
RsSourceEndGrant encodeSourceEndGrant(SourceEndGrant value) => RsSourceEndGrant(
  version: value.version,
  grantId: value.grantId,
  round: value.round,
  token: value.token,
  expiresAtUnixMs: BigInt.from(value.expiresAtUnixMs),
);
SourceEndResult decodeSourceEndResult(RsSourceEndResult value) => SourceEndResult(
  outcome: SourceEndOutcome.values.byName(value.outcome.name),
  receiptId: value.receiptId,
  removedFiles: value.removedFiles,
  unlinkedBytes: value.unlinkedBytes.toInt(),
);
