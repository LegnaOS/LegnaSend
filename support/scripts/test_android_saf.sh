#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ANDROID_JAR="$SDK/platforms/android-36/android.jar"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/legnasend-saf-test.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
SRC="$ROOT/app/android/app/src/main/kotlin/org/localsend/localsend_app"
TEST="$ROOT/app/android/app/src/test/java/org/localsend/localsend_app"
javac --release 17 -d "$OUT" "$SRC/SafDirectoryResolver.java" "$SRC/SafReceiveTransaction.java" "$SRC/SafCacheHeader.java" "$SRC/SafVerifiedCopy.java" \
  "$TEST/SafDirectoryResolverTest.java" "$TEST/SafReceiveTransactionTest.java" "$TEST/SafPublicationReconcileTest.java" "$TEST/SafPublishedStagingTest.java" \
  "$TEST/SafReceiveRecoveryClaimTest.java" "$TEST/SafReceiveCacheIdentityTest.java" "$TEST/SafReceiveProbeCleanupTest.java" "$TEST/SafReceiveTransactionAdversarialTest.java" "$TEST/SafReceivePublicationAdversarialTest.java" "$TEST/SafCacheHeaderTest.java" "$TEST/SafVerifiedCopyTest.java" "$TEST/SafVerifiedCopyAdversarialTest.java"
java -cp "$OUT" org.localsend.localsend_app.SafDirectoryResolverTest
java -cp "$OUT" org.localsend.localsend_app.SafReceiveTransactionTest
java -cp "$OUT" org.localsend.localsend_app.SafPublicationReconcileTest
java -cp "$OUT" org.localsend.localsend_app.SafPublishedStagingTest
java -cp "$OUT" org.localsend.localsend_app.SafReceiveProbeCleanupTest
java -cp "$OUT" org.localsend.localsend_app.SafReceiveCacheIdentityTest
java -cp "$OUT" org.localsend.localsend_app.SafReceiveRecoveryClaimTest
java -cp "$OUT" org.localsend.localsend_app.SafReceiveTransactionAdversarialTest
java -cp "$OUT" org.localsend.localsend_app.SafReceivePublicationAdversarialTest
java -cp "$OUT" org.localsend.localsend_app.SafVerifiedCopyTest
java -cp "$OUT" org.localsend.localsend_app.SafVerifiedCopyAdversarialTest
# Source-order guards complement portable logic tests; these are not provider/device tests.
python3 - "$SRC/AndroidSafReceiveTransaction.java" <<'PY_CHECK'
import sys
source = open(sys.argv[1], encoding="utf-8").read()
copy = source.split("void copyPublication(", 1)[1].split("void releaseReceive(", 1)[0]
assert "SafVerifiedCopy.copy(" in copy and "verifyBytes(output," not in copy
assert copy.index("output.close();") < copy.index("verifyBytes(visible,")
failed = source.split("boolean deleteFailedPublication(", 1)[1].split("void closeReceive(", 1)[0]
closed = failed.index("held.close();")
reopened = failed.index("visible = openRead(", closed)
validated = failed.index("revalidate(record.output, record.parent, visible)", reopened)
assert closed < reopened < validated < failed.index("DocumentsContract.deleteDocument(")
assert failed.index("sameFile(held, witness)") < closed
assert "State.PUBLICATION_FAILED" in failed
delete_owned = source.split("boolean deleteOwned(", 1)[1].split("public static final class Journal", 1)[0]
assert delete_owned.index("owned == null || !owned.released") < delete_owned.index("verifyCacheHeader(held, owned.id, -1, true)")
assert delete_owned.index("revalidate(new SafReceiveTransaction.Document") < delete_owned.index("verifyCacheHeader(held, owned.id, -1, true)")
header = source.split("void verifyCacheHeader(", 1)[1].split("void verifyBytes(", 1)[0]
assert "if (allowEmpty && length == 0) return;" in header
recovery_open = source.split("RecoveryWitness openRecoverySource(", 1)[1].split("public static final class OpenedPair", 1)[0]
assert "openRead(source.cache.uri)" in recovery_open and "open(source.cache.uri)" not in recovery_open
assert "sameFile(witness, transport)" in recovery_open and "expected.json.equals(actual.json)" in recovery_open
cleanup = source.split("AbortResult cleanupPublishedSource(", 1)[1].split("Map<String, Object> reconcile(", 1)[0]
assert "DocumentsContract.deleteDocument" not in cleanup and "RECOVERY_CACHE_EXCLUSIVE_PROOF_REQUIRED" in cleanup
release = source.split("AbortResult release(String id, String lease)", 1)[1].split("AbortResult cleanupPublishedSource(", 1)[0]
assert "finally" in release and "recoveryWitnesses.remove(id)" in release
cleanup_prepare = source.split("CleanupPreparation prepareRecoveryCleanup(", 1)[1].split("boolean deleteRecoveryCleanup(", 1)[0]
assert 'backend.open(source.cache.uri)' in cleanup_prepare and 'ftruncate' not in cleanup_prepare
assert cleanup_prepare.index("sameFile(witness, transport)") < cleanup_prepare.index("new CleanupPreparation(")
cleanup_delete = source.split("boolean deleteRecoveryCleanup(", 1)[1].split("void finishRecoveryCleanup(", 1)[0]
assert cleanup_delete.index("transactions.recoveryCleanupSource(") < cleanup_delete.index("backend.validateRecoverySource(")
assert cleanup_delete.index("backend.requireRecoveryLength(") < cleanup_delete.index("DocumentsContract.deleteDocument(")
assert cleanup_delete.index("DocumentsContract.deleteDocument(") < cleanup_delete.index("source.cache = null; journal.save(source)")
assert 'source.staging =' not in cleanup_delete and 'source.output =' not in cleanup_delete
reconcile = source.split("Map<String, Object> reconcile(", 1)[1].split("private static Manager manager", 1)[0]
assert 'recoveryCleanupCandidates.size() < limit' in reconcile and '!cleanupWitnesses.containsKey(id)' in reconcile
assert 'transactions.recoveryCleanupSource(id, record.lease, record.recoverySourceId)' in reconcile
assert 'result.put("recoveryCleanupCandidates", recoveryCleanupCandidates)' in reconcile
publication_prepare = source.split("PublicationPreparation preparePublicationReconcile(", 1)[1].split("void confirmPublicationReconcile(", 1)[0]
assert "publicationWitnesses.containsKey(id)" in publication_prepare and "publicationWitnesses.size() >= 32" in publication_prepare
assert "backend.live.containsKey(id)" in publication_prepare and "journal.recoveryLock()" in publication_prepare
assert publication_prepare.index("backend.authorize(") < publication_prepare.index("backend.openRead(record.output.uri)")
assert publication_prepare.count("backend.openRead(record.output.uri)") == 2 and "backend.open(" not in publication_prepare
assert publication_prepare.index("sameFile(witness, transport)") < publication_prepare.index("new PublicationPreparation(")
assert "UUID.randomUUID().toString()" in publication_prepare and "finally" in publication_prepare
publication_confirm = source.split("void confirmPublicationReconcile(", 1)[1].split("void finishPublicationReconcile(", 1)[0]
assert "witness.token.equals(token)" in publication_confirm and "backend.live.containsKey(id)" in publication_confirm
assert "witness.confirmed" in publication_confirm and "journal.recoveryLock()" in publication_confirm
assert publication_confirm.index("samePublicationRecord(") < publication_confirm.index("backend.validatePublicationReconcile(")
assert publication_confirm.index("backend.validatePublicationReconcile(") < publication_confirm.index("transactions.confirmPublicationReconcile(")
assert "deleteDocument" not in publication_prepare + publication_confirm and "copyPublication" not in publication_prepare + publication_confirm
publication_finish = source.split("void finishPublicationReconcile(", 1)[1].split("IdentityBinding bind(", 1)[0]
assert publication_finish.index("witness.token.equals(token)") < publication_finish.index("publicationWitnesses.remove(id)")
assert "witness.witness.close()" in publication_finish
assert 'publicationReconcileCandidates.size() < limit' in reconcile and 'item.put("transactionId", id)' in reconcile
publication_validate = source.split("void validatePublicationReconcile(", 1)[1].split("private static final class CleanupWitness", 1)[0]
assert "authorize(record.tree, record.parent)" in publication_validate and "revalidate(record.output, record.parent, witness)" in publication_validate
assert "requireRecoveryLength(witness, record.size)" in publication_validate
assert "OsConstants.F_GETFL" in publication_validate and "OsConstants.O_RDONLY" in publication_validate
activity = open(sys.argv[1].replace("AndroidSafReceiveTransaction.java", "MainActivity.kt"), encoding="utf-8").read()
publication_delivery = activity.split("if (value is AndroidSafReceiveTransaction.PublicationPreparation)", 1)[1].split("if (value is AndroidSafReceiveTransaction.CleanupPreparation)", 1)[0]
assert publication_delivery.index("safActivityClosed || isDestroyed || isFinishing") < publication_delivery.index("value.descriptor.detachFd()")
assert "discardPublicationReconcile(value)" in publication_delivery and "ParcelFileDescriptor.adoptFd(it).close()" in publication_delivery
assert '"fileDescriptor" to detached' in publication_delivery and '"reconciliationId" to value.reconciliationId' in publication_delivery
assert "safManager.finishPublicationReconcile(id, token); null" in activity
staging_prepare = source.split("StagingPreparation preparePublishedStagingCleanup(", 1)[1].split("boolean deletePublishedStagingCleanup(", 1)[0]
assert "stagingWitnesses.containsKey(id)" in staging_prepare and "stagingWitnesses.size() >= 32" in staging_prepare
assert "backend.live.containsKey(id)" in staging_prepare and "journal.recoveryLock()" in staging_prepare
assert staging_prepare.index("backend.authorize(") < staging_prepare.index("backend.openRead(record.staging.uri)")
assert "backend.open(record.staging.uri)" in staging_prepare and "ftruncate" not in staging_prepare
assert "OsConstants.O_RDONLY" in staging_prepare and "OsConstants.O_RDWR" in staging_prepare
assert staging_prepare.index("sameFile(witness, transport)") < staging_prepare.index("new StagingPreparation(")
assert "UUID.randomUUID().toString()" in staging_prepare and "finishPublishedStagingCleanup(id, prepared.cleanupId)" in staging_prepare
staging_delete = source.split("boolean deletePublishedStagingCleanup(", 1)[1].split("void finishPublishedStagingCleanup(", 1)[0]
assert "witness.token.equals(token)" in staging_delete and "backend.live.containsKey(id)" in staging_delete
assert "if (witness.deleteAttempted) return false" in staging_delete and "journal.recoveryLock()" in staging_delete
assert staging_delete.index("samePublicationRecord(") < staging_delete.index("backend.validatePublishedStaging(")
assert staging_delete.index("witness.requireUnchanged()") < staging_delete.index("transactions.deletePublishedStaging(")
assert staging_delete.count("witness.requireUnchanged()") == 2
assert "Uri stagingUri = Uri.parse(current.staging.uri)" in staging_delete
assert "pending -> DocumentsContract.deleteDocument(backend.resolver, stagingUri)" in staging_delete
assert "pending.output.uri" not in staging_delete and "pending.cache.uri" not in staging_delete
assert "if (!deleted) throw error" in staging_delete
staging_validate = source.split("void validatePublishedStaging(", 1)[1].split("private static final class PublicationWitness", 1)[0]
assert "record.state != SafReceiveTransaction.State.PUBLISHED" in staging_validate and "!record.receiveReleased" in staging_validate
assert "revalidate(record.staging, record.parent, witness)" in staging_validate and "requireRecoveryLength(witness, record.size)" in staging_validate
assert "requireDifferentDocument(record.output" in staging_validate and "requireDifferentDocument(record.cache" in staging_validate
assert "a.st_dev == b.st_dev && a.st_ino == b.st_ino" in staging_validate and "revalidate(document, parent, other)" in staging_validate
stamp = source.split("long[] stageStamp(", 1)[1].split("public static final class StagingPreparation", 1)[0]
assert "SDK_INT < 27" in stamp and "stat.st_mtim.tv_nsec" in stamp and "stat.st_ctim.tv_nsec" in stamp
staging_finish = source.split("void finishPublishedStagingCleanup(", 1)[1].split("PublicationPreparation preparePublicationReconcile(", 1)[0]
assert staging_finish.index("witness.token.equals(token)") < staging_finish.index("stagingWitnesses.remove(id)")
assert "witness.witness.close()" in staging_finish
assert "publishedStagingCleanupCandidates.size() < limit" in reconcile
assert 'result.put("publishedStagingCleanupCandidates", publishedStagingCleanupCandidates)' in reconcile
assert '.put("stagingCleanupPending", record.stagingCleanupPending)' in source and "pending instanceof Boolean" in source
staging_delivery = activity.split("if (value is AndroidSafReceiveTransaction.StagingPreparation)", 1)[1].split("if (value is AndroidSafReceiveTransaction.PublicationPreparation)", 1)[0]
assert staging_delivery.index("safActivityClosed || isDestroyed || isFinishing") < staging_delivery.index("value.descriptor.detachFd()")
assert '"descriptor" to detached' in staging_delivery and '"length" to value.length' in staging_delivery
assert "discardPublishedStaging(value)" in staging_delivery and "ParcelFileDescriptor.adoptFd(it).close()" in staging_delivery
state = open(sys.argv[1].replace("AndroidSafReceiveTransaction.java", "SafReceiveTransaction.java"), encoding="utf-8").read()
staging_state = state.split("StagingCleanupResult deletePublishedStaging(", 1)[1].split("Private receipt evidence only", 1)[0]
assert staging_state.index("current.stagingCleanupPending = true") < staging_state.index("journal.save(current.copy())") < staging_state.index("delete.delete(")
assert staging_state.index("delete.delete(") < staging_state.index("current.staging = null")
assert "new StagingCleanupResult(true, false)" in staging_state
assert staging_state.index("validate.validate(") < staging_state.index("boolean deleted = delete.delete(")
assert "beforeProviderCall.addSuppressed(uncertain)" in staging_state
assert "if (published && slot == 1)" in state and 'reasons.add("PUBLISHED_STAGING_CLEANUP_RETAINED")' in state
print("SAF published staging guards: 32 tickets, read-only witness/independent rw, EX handoff, v2 proof/alias/stamp recheck, durable intent, staging-only delete, deferred legacy cleanup (not provider/device)")
print("SAF publication reconciliation source guards: 32 pending, independent read-only pair, no-live/index/token/snapshot/proof checks, no output mutation (not device acceptance)")
print("SAF recovery cleanup guards: no-truncate independent rw handoff, published lineage, source identity/length before deletion, durable cache-only removal")
print("SAF restart recovery guards: read-only independent source, full registered header, no unproven source deletion, release closes witness")
print("SAF empty-probe cleanup guards: owned/released witness, identity revalidation, exact zero-length exception (not a provider/device test)")
print("SAF publication source-order guards: 5 assertions passed (not a provider/device test)")
PY_CHECK
if [[ -n "${SAF_NATIVE_FIXTURE:-}" ]]; then
  java -cp "$OUT" org.localsend.localsend_app.SafCacheHeaderTest \
    "$SAF_NATIVE_FIXTURE/native-created.ls" "$SAF_NATIVE_FIXTURE/native-identity.json"
else
  java -cp "$OUT" org.localsend.localsend_app.SafCacheHeaderTest
fi
if [[ -f "$ANDROID_JAR" ]]; then
  javac --release 17 -cp "$OUT:$ANDROID_JAR" -d "$OUT" "$SRC/AndroidSafDirectory.java" "$SRC/AndroidSafReceiveTransaction.java"
  echo 'Android SAF adapter: SDK 36 compilation passed (not a provider/device test)'
  if [[ -n "${JSON_RUNTIME_JAR:-}" ]]; then
    javac --release 17 -cp "$OUT:$JSON_RUNTIME_JAR:$ANDROID_JAR" -d "$OUT" "$TEST/AndroidSafCacheIdentityJsonTest.java" "$TEST/AndroidSafPublicationProofTest.java" "$TEST/AndroidSafStagingProofTest.java"
    java -cp "$OUT:$JSON_RUNTIME_JAR:$ANDROID_JAR" org.localsend.localsend_app.AndroidSafCacheIdentityJsonTest
    java -cp "$OUT:$JSON_RUNTIME_JAR:$ANDROID_JAR" org.localsend.localsend_app.AndroidSafPublicationProofTest
    java -cp "$OUT:$JSON_RUNTIME_JAR:$ANDROID_JAR" org.localsend.localsend_app.AndroidSafStagingProofTest
  fi
else
  echo "Missing SDK 36: $ANDROID_JAR" >&2
  exit 1
fi
# Optional full activity type-check against the pinned Flutter embedding and its
# lifecycle dependency. Supply real jars; do not substitute Android/Flutter stubs.
if [[ -n "${KOTLIN_HOME:-}" && -n "${FLUTTER_EMBEDDING_JAR:-}" && -n "${LIFECYCLE_COMMON_JAR:-}" ]]; then
  "$KOTLIN_HOME/bin/kotlinc" "$SRC/MainActivity.kt" "$SRC/FastDocumentFile.kt" \
    "$SRC/FileOpener.kt" "$SRC/NetworkSignalReader.kt" "$SRC/NetworkRouteReader.kt" -jvm-target 17 \
    -classpath "$ANDROID_JAR:$FLUTTER_EMBEDDING_JAR:$LIFECYCLE_COMMON_JAR:$OUT" -d "$OUT/kotlin.jar"
  echo 'Android activity: Kotlin type-check passed (not an APK/device test)'
fi
