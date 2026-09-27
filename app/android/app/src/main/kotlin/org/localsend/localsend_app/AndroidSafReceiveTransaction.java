package org.localsend.localsend_app;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.AtomicFile;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.channels.FileLock;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.json.JSONException;
import org.json.JSONObject;

/** Provider-owned receive transactions; names and document cleanup never pass into Rust. */
public final class AndroidSafReceiveTransaction implements SafReceiveTransaction.Backend {
    private final ContentResolver resolver;
    private final AndroidSafDirectory directories;
    private final boolean exactPublicationName;
    private final java.util.function.BooleanSupplier allowCreation;
    // Only a freshly returned ID absent from the pre-create listing can acquire an ownership marker.
    private final Map<String, String> createdNames = new HashMap<>();
    private final Map<String, String> createdParents = new HashMap<>();

    public AndroidSafReceiveTransaction(ContentResolver resolver) { this(resolver, false); }
    AndroidSafReceiveTransaction(ContentResolver resolver, boolean exactPublicationName) { this(resolver, exactPublicationName, () -> true); }
    AndroidSafReceiveTransaction(ContentResolver resolver, boolean exactPublicationName, java.util.function.BooleanSupplier allowCreation) {
        this.resolver = resolver;
        this.exactPublicationName = exactPublicationName;
        this.allowCreation = allowCreation;
        directories = new AndroidSafDirectory(resolver);
    }

    /** Process lifetime ownership survives Activity recreation, but never process death. */
    public static final class Manager {
        public final AndroidSafReceiveTransaction backend;
        public final SafReceiveTransaction transactions;
        private final Journal journal;
        private String reconcileCursor;
        private Manager(Context context) {
            backend = new AndroidSafReceiveTransaction(context.getApplicationContext().getContentResolver());
            journal = new Journal(context.getApplicationContext());
            transactions = new SafReceiveTransaction(backend, journal);
        }
        private final Map<String, RecoveryWitness> recoveryWitnesses = new HashMap<>();
        private final Map<String, CleanupWitness> cleanupWitnesses = new HashMap<>();
        private final Map<String, PublicationWitness> publicationWitnesses = new HashMap<>();
        private final Map<String, StagingWitness> stagingWitnesses = new HashMap<>();
        public synchronized StagingPreparation preparePublishedStagingCleanup(String id) throws IOException {
            if (stagingWitnesses.containsKey(id) || stagingWitnesses.size() >= 32 || backend.live.containsKey(id)) return null;
            StagingPreparation prepared = null;
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record record = transactions.publishedStagingCandidate(id);
                if (record == null || !hasPublishedStagingProof(record)) return null;
                backend.authorize(record.tree, record.parent);
                ParcelFileDescriptor witness = backend.openRead(record.staging.uri), transport = null;
                boolean retained = false;
                try {
                    backend.requireAccess(witness, OsConstants.O_RDONLY);
                    backend.validatePublishedStaging(record, witness);
                    transport = backend.open(record.staging.uri); // Independent rw, never rwt/truncate: EX/OFD lock requires writable FD.
                    backend.requireAccess(transport, OsConstants.O_RDWR);
                    sameFile(witness, transport);
                    backend.validatePublishedStaging(record, transport);
                    String token = UUID.randomUUID().toString();
                    prepared = new StagingPreparation(id, token, record.size, record.sha256, transport);
                    stagingWitnesses.put(id, new StagingWitness(record.copy(), token, witness, stageStamp(witness)));
                    retained = true;
                    return prepared;
                } finally {
                    if (!retained) { try { witness.close(); } finally { if (transport != null) transport.close(); } }
                }
            } catch (IOException | RuntimeException error) {
                if (prepared != null) {
                    try { prepared.close(); } catch (IOException | RuntimeException close) { error.addSuppressed(close); }
                    try { finishPublishedStagingCleanup(id, prepared.cleanupId); }
                    catch (IOException | RuntimeException close) { error.addSuppressed(close); }
                }
                throw error;
            }
        }
        /** Trusted core keeps the verified full-payload EX guard until this future really completes. */
        public synchronized boolean deletePublishedStagingCleanup(String id, String token) throws IOException {
            StagingWitness witness = stagingWitnesses.get(id);
            if (witness == null || !witness.token.equals(token) || backend.live.containsKey(id))
                throw failure("STALE_HANDOFF", "Published staging cleanup identity is unavailable");
            if (witness.deleteAttempted) return false;
            boolean deleted = false;
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record current = transactions.publishedStagingCandidate(id);
                if (current == null || !SafReceiveTransaction.samePublicationRecord(current, witness.record))
                    throw failure("STALE_HANDOFF", "Published staging receipt changed");
                backend.validatePublishedStaging(current, witness.witness);
                witness.requireUnchanged();
                Uri stagingUri = Uri.parse(current.staging.uri);
                witness.deleteAttempted = true;
                SafReceiveTransaction.StagingCleanupResult result = transactions.deletePublishedStaging(witness.record, pending -> {
                    backend.validatePublishedStaging(pending, witness.witness);
                    witness.requireUnchanged();
                }, pending -> DocumentsContract.deleteDocument(backend.resolver, stagingUri));
                deleted = result.deleted;
                if (!result.recorded) android.util.Log.w("LegnaSend", "Published staging deletion receipt retained its pending intent");
                return deleted;
            } catch (IOException | RuntimeException error) {
                if (!deleted) throw error;
                android.util.Log.w("LegnaSend", "Published staging deletion index close deferred");
                return true; // An index-close error must not erase an actual provider success.
            }
        }
        public synchronized void finishPublishedStagingCleanup(String id, String token) throws IOException {
            StagingWitness witness = stagingWitnesses.get(id);
            if (witness == null) return;
            if (!witness.token.equals(token)) throw failure("STALE_HANDOFF", "Published staging cleanup identity differs");
            stagingWitnesses.remove(id); witness.witness.close();
        }
        public synchronized PublicationPreparation preparePublicationReconcile(String id) throws IOException {
            if (publicationWitnesses.containsKey(id) || publicationWitnesses.size() >= 32 || backend.live.containsKey(id)) return null;
            PublicationPreparation prepared = null;
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record record = transactions.publicationReconcileCandidate(id);
                if (record == null || !hasPublicationReconcileProof(record)) return null;
                backend.authorize(record.tree, record.parent);
                ParcelFileDescriptor witness = backend.openRead(record.output.uri), transport = null;
                boolean retained = false;
                try {
                    backend.validatePublicationReconcile(record, witness);
                    transport = backend.openRead(record.output.uri);
                    sameFile(witness, transport);
                    backend.validatePublicationReconcile(record, transport);
                    String token = UUID.randomUUID().toString();
                    prepared = new PublicationPreparation(record.id, token, record.size, record.sha256, transport);
                    publicationWitnesses.put(id, new PublicationWitness(record.copy(), token, witness));
                    retained = true;
                    return prepared;
                } finally {
                    if (!retained) { try { witness.close(); } finally { if (transport != null) transport.close(); } }
                }
            } catch (IOException | RuntimeException error) {
                // Even failure while closing the private index lock must not strand
                // an undelivered transport or its witness in the pending map.
                if (prepared != null) {
                    try { prepared.close(); } catch (IOException | RuntimeException close) { error.addSuppressed(close); }
                    try { finishPublicationReconcile(id, prepared.reconciliationId); }
                    catch (IOException | RuntimeException close) { error.addSuppressed(close); }
                }
                throw error;
            }
        }
        /** Core owns the independent read-only FD and keeps its strict SH/hash guard through this call. */
        public synchronized void confirmPublicationReconcile(String id, String token) throws IOException {
            PublicationWitness witness = publicationWitnesses.get(id);
            if (witness == null || !witness.token.equals(token) || witness.confirmed || backend.live.containsKey(id))
                throw failure("STALE_PUBLICATION", "Publication reconciliation is unavailable");
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record current = transactions.publicationReconcileCandidate(id);
                if (current == null || !SafReceiveTransaction.samePublicationRecord(current, witness.record))
                    throw failure("STALE_PUBLICATION", "Publication evidence changed");
                backend.validatePublicationReconcile(current, witness.witness);
                transactions.confirmPublicationReconcile(witness.record);
                witness.confirmed = true;
            }
        }
        public synchronized void finishPublicationReconcile(String id, String token) throws IOException {
            PublicationWitness witness = publicationWitnesses.get(id);
            if (witness == null) return;
            if (!witness.token.equals(token)) throw failure("STALE_PUBLICATION", "Publication reconciliation identity differs");
            publicationWitnesses.remove(id);
            witness.witness.close();
        }
        public synchronized IdentityBinding bind(String id, String lease, String attempt, String json) throws IOException {
            transactions.bindCacheIdentity(id, lease, attempt, json);
            IdentityBinding result = new IdentityBinding(id, attempt);
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record target = journal.load(id);
                if (target == null || target.recoverySourceId != null || recoveryWitnesses.containsKey(id)) return result;
                backend.validateIdentityBinding(target, true);
                java.util.List<String> candidates = journal.ids(128, null);
                for (String sourceId : candidates) {
                    boolean protectedReceipt = false;
                    try { protectedReceipt = transactions.hasProtectedRecovery(id, sourceId, System.currentTimeMillis()); }
                    catch (IOException | RuntimeException malformed) { /* no guessed receipt from a malformed record */ }
                    if (protectedReceipt) throw new SafReceiveTransaction.Failure("RECOVERY_PUBLICATION_PENDING",
                        "A matching publication requires receipt reconciliation before another copy");
                }
                if (recoveryWitnesses.size() >= 64) return result;
                for (String sourceId : candidates) {
                    if (sourceId.equals(id) || backend.live.containsKey(sourceId)) continue;
                    try {
                        if (!transactions.claimRecovery(id, lease, attempt, sourceId, System.currentTimeMillis())) continue;
                        SafReceiveTransaction.Record source = journal.load(sourceId);
                        RecoveryWitness opened = backend.openRecoverySource(source, id);
                        recoveryWitnesses.put(id, opened);
                        result.sourceId = sourceId; result.identityJson = source.recoveryIdentity;
                        result.source = opened.transport; opened.transport = null;
                        return result;
                    } catch (IOException | RuntimeException unavailable) {
                        SafReceiveTransaction.Record current = journal.load(id);
                        if (current != null && current.recoverySourceId != null) {
                            try { transactions.releaseRecoveryClaim(current, true); }
                            catch (IOException | RuntimeException uncertain) { return result; }
                        }
                    }
                }
            } catch (SafReceiveTransaction.Failure protectedReceipt) {
                if ("RECOVERY_PUBLICATION_PENDING".equals(protectedReceipt.code)) throw protectedReceipt;
            } catch (IOException | RuntimeException unavailable) {
                // An unavailable candidate/index never turns an approved fresh download into failure.
            }
            return result;
        }
        public synchronized void completeRecovery(String id, String lease, String attempt, String sourceId, long sourceLength, String sourceSha256) throws IOException {
            SafReceiveTransaction.validateRecoveryProof(sourceLength, sourceSha256);
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record target = journal.load(id), source = journal.load(sourceId);
                RecoveryWitness witness = recoveryWitnesses.get(id);
                if (target == null || source == null || witness == null || !sourceId.equals(witness.sourceId))
                    throw failure("STALE_HANDOFF", "Recovery witness is unavailable");
                backend.authorize(target.tree, target.parent);
                backend.validateIdentityBinding(target, false);
                backend.validateRecoverySource(source, witness.witness);
                backend.requireRecoveryLength(witness.witness, sourceLength);
                transactions.completeRecovery(id, lease, attempt, sourceId, sourceLength, sourceSha256);
                witness.copied = true; // Trusted core callback occurs only after its source FD closed.
            }
        }
        public synchronized CleanupPreparation prepareRecoveryCleanup(String id, String lease) throws IOException {
            if (cleanupWitnesses.containsKey(id) || cleanupWitnesses.size() >= 64) return null;
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record source = transactions.recoveryCleanupSource(id, lease, null);
                if (source.cache == null) return null;
                ParcelFileDescriptor witness = backend.openRead(source.cache.uri), transport = null;
                boolean retained = false;
                try {
                    backend.validateRecoverySource(source, witness);
                    backend.requireRecoveryLength(witness, source.recoveryLength);
                    transport = backend.open(source.cache.uri); // rw, never rwt; core needs a real exclusive/OFD write lock.
                    sameFile(witness, transport);
                    backend.revalidate(source.cache, source.parent, transport);
                    backend.requireRecoveryLength(transport, source.recoveryLength);
                    cleanupWitnesses.put(id, new CleanupWitness(source.id, lease, source.recoveryLength, source.recoverySha256, witness));
                    retained = true;
                    return new CleanupPreparation(id, source.id, source.recoveryLength, source.recoverySha256, transport);
                } finally {
                    if (!retained) { try { witness.close(); } finally { if (transport != null) transport.close(); } }
                }
            }
        }
        /** Trusted caller holds the core strict EX lock and verified full raw-container digest until this returns. */
        public synchronized boolean deleteRecoveryCleanup(String id, String lease, String sourceId) throws IOException {
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record source = transactions.recoveryCleanupSource(id, lease, sourceId);
                if (source.cache == null) return true; // durable deletion acknowledgement replay
                CleanupWitness witness = cleanupWitnesses.get(id);
                if (witness == null || !sourceId.equals(witness.sourceId) || !lease.equals(witness.lease)
                        || witness.length != source.recoveryLength || !witness.sha256.equals(source.recoverySha256))
                    throw failure("STALE_HANDOFF", "Recovery cleanup witness or container proof differs");
                if (witness.deleteAttempted) return false;
                witness.deleteAttempted = true;
                backend.validateRecoverySource(source, witness.witness);
                backend.requireRecoveryLength(witness.witness, source.recoveryLength);
                // No file data is changed here. The core guard owns the lock on an
                // independent open of exactly this pinned inode through URI revalidation.
                if (!DocumentsContract.deleteDocument(backend.resolver, Uri.parse(source.cache.uri))) return false;
                source.cache = null; journal.save(source);
                return true;
            }
        }
        public synchronized void finishRecoveryCleanup(String id, String sourceId) throws IOException {
            CleanupWitness witness = cleanupWitnesses.get(id);
            if (witness == null) return;
            if (!sourceId.equals(witness.sourceId)) throw failure("STALE_HANDOFF", "Recovery cleanup source differs");
            cleanupWitnesses.remove(id); witness.witness.close();
        }
        public synchronized void discardBinding(IdentityBinding binding) throws IOException {
            binding.close();
            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                SafReceiveTransaction.Record target = journal.load(binding.transactionId);
                RecoveryWitness witness = recoveryWitnesses.remove(binding.transactionId);
                try { if (target != null) transactions.releaseRecoveryClaim(target); }
                finally { if (witness != null) witness.close(); }
            }
        }
        public synchronized SafReceiveTransaction.AbortResult release(String id, String lease) throws IOException {
            SafReceiveTransaction.Record target = journal.load(id);
            SafReceiveTransaction.AbortResult result = transactions.abortReceiving(id, lease);
            try {
                if (target == null || target.recoverySourceId == null) return result;
                try (Journal.IndexLock ignored = journal.recoveryLock()) {
                    SafReceiveTransaction.Record current = journal.load(id);
                    if (current != null && current.state == SafReceiveTransaction.State.PUBLISHED) {
                        return cleanupPublishedSource(current, result);
                    }
                    transactions.releaseRecoveryClaim(current == null ? target : current, !target.recoveryCompleted);
                }
                return result;
            } finally {
                // Core already drained before abortReceiving returned. Even a
                // revoked grant or journal/index failure must not leak witnesses.
                RecoveryWitness witness = recoveryWitnesses.remove(id);
                CleanupWitness cleanup = cleanupWitnesses.remove(id);
                try { if (witness != null) witness.close(); }
                finally { if (cleanup != null) cleanup.witness.close(); }
            }
        }
        private SafReceiveTransaction.AbortResult cleanupPublishedSource(SafReceiveTransaction.Record target,
                SafReceiveTransaction.AbortResult base) throws IOException {
            java.util.List<String> deleted = new java.util.ArrayList<>(base.deleted);
            java.util.List<String> retained = new java.util.ArrayList<>(base.retained);
            java.util.List<String> reasons = new java.util.ArrayList<>(base.reasons);
            SafReceiveTransaction.Record source = journal.load(target.recoverySourceId);
            RecoveryWitness witness = recoveryWitnesses.get(target.id);
            if (source == null) return base;
            // The core's read lock ended after recover_copy. A read-only witness
            // pins an inode but neither excludes later writers nor proves that the
            // container payload/tail is unchanged. Header identity alone must not
            // authorize deletion. Only deleteRecoveryCleanup, called while the
            // verified core EX guard is held, may remove a registered old cache.
            if (source.cache != null) {
                retained.add(source.cache.uri); reasons.add(source.recoveryLength >= 49 && source.recoverySha256 != null
                    ? "RECOVERY_CACHE_CLEANUP_DEFERRED" : "RECOVERY_CACHE_EXCLUSIVE_PROOF_REQUIRED");
            }
            recoveryWitnesses.remove(target.id);
            if (witness != null) witness.close();
            if (source.staging != null) {
                retained.add(source.staging.uri); reasons.add("RECOVERY_STAGING_OWNERSHIP_UNPROVEN");
            }
            return new SafReceiveTransaction.AbortResult(target.id, deleted, retained, reasons, retained.isEmpty());
        }
        public synchronized Map<String, Object> reconcile(int requestedLimit) throws IOException {
            int limit = Math.max(1, Math.min(64, requestedLimit));
            java.util.List<String> ids = journal.ids(limit + 1, reconcileCursor);
            int examined = 0, removed = 0, deleted = 0, retained = 0, active = 0, published = 0;
            java.util.List<String> reasons = new java.util.ArrayList<>();
            java.util.List<Map<String, Object>> recoveryCleanupCandidates = new java.util.ArrayList<>();
            java.util.List<Map<String, Object>> publicationReconcileCandidates = new java.util.ArrayList<>();
            java.util.List<Map<String, Object>> publishedStagingCleanupCandidates = new java.util.ArrayList<>();
            for (String id : ids) {
                if (examined >= limit) break;
                examined++;
                reconcileCursor = id; // Round-robin past retained receipts on the next invocation.
                try {
                    SafReceiveTransaction.Record record = journal.load(id);
                    if (record == null) continue;
                    if (backend.live.containsKey(id)) { active++; retained++; reasons.add("ACTIVE_RECEIVE"); continue; }
                    if (record.state == SafReceiveTransaction.State.PUBLISHED) {
                        published++;
                        if (!stagingWitnesses.containsKey(id) && publishedStagingCleanupCandidates.size() < limit) {
                            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                                SafReceiveTransaction.Record candidate = transactions.publishedStagingCandidate(id);
                                if (candidate != null && hasPublishedStagingProof(candidate)) {
                                    Map<String, Object> item = new HashMap<>(); item.put("transactionId", id);
                                    publishedStagingCleanupCandidates.add(item);
                                }
                            } catch (IOException | RuntimeException unavailable) { reasons.add("PUBLISHED_STAGING_PROOF_UNAVAILABLE"); }
                        }
                        if (record.recoveryCompleted && record.recoverySourceId != null && record.lease != null
                                && !cleanupWitnesses.containsKey(id) && recoveryCleanupCandidates.size() < limit) {
                            try (Journal.IndexLock ignored = journal.recoveryLock()) {
                                SafReceiveTransaction.Record source = transactions.recoveryCleanupSource(id, record.lease, record.recoverySourceId);
                                if (source.cache != null) {
                                    Map<String, Object> candidate = new HashMap<>();
                                    candidate.put("transactionId", id); candidate.put("lease", record.lease);
                                    recoveryCleanupCandidates.add(candidate);
                                }
                            } catch (IOException | RuntimeException unavailable) { reasons.add("RECOVERY_CLEANUP_PROOF_UNAVAILABLE"); }
                        }
                        if (record.cache != null || record.staging != null) { retained++; reasons.add("PUBLISHED_CACHE_RETAINED"); }
                        continue; // Preserve durable receipt and final output, including after restart.
                    }
                    if (record.state == SafReceiveTransaction.State.PUBLISHING && !publicationWitnesses.containsKey(id)
                            && publicationReconcileCandidates.size() < limit) {
                        try (Journal.IndexLock ignored = journal.recoveryLock()) {
                            SafReceiveTransaction.Record candidate = transactions.publicationReconcileCandidate(id);
                            if (candidate != null && hasPublicationReconcileProof(candidate)) {
                                Map<String, Object> item = new HashMap<>(); item.put("transactionId", id);
                                publicationReconcileCandidates.add(item);
                            }
                        } catch (IOException | RuntimeException unavailable) { reasons.add("PUBLICATION_PROOF_UNAVAILABLE"); }
                    }
                    if (record.recoverySupersededBy != null) {
                        retained++; reasons.add(record.cache == null ? "RECOVERY_STAGING_OWNERSHIP_UNPROVEN"
                            : record.recoveryLength >= 49 && record.recoverySha256 != null
                                ? "RECOVERY_CACHE_CLEANUP_DEFERRED" : "RECOVERY_CACHE_EXCLUSIVE_PROOF_REQUIRED"); continue;
                    }
                    if (record.lease != null || record.state == SafReceiveTransaction.State.RECEIVING
                            || record.state == SafReceiveTransaction.State.PUBLISHING || record.output != null) {
                        retained++;
                        reasons.add(record.state == SafReceiveTransaction.State.PUBLICATION_FAILED ? "OWNERSHIP_UNPROVEN"
                            : record.output != null || record.state == SafReceiveTransaction.State.PUBLISHING
                                ? "PUBLICATION_AMBIGUOUS" : "INTERRUPTED_RECEIVE");
                        continue;
                    }
                    SafReceiveTransaction.AbortResult result = transactions.abort(id);
                    deleted += result.deleted.size();
                    if (result.complete) removed++; else { retained++; reasons.addAll(result.reasons); }
                } catch (IOException | RuntimeException error) {
                    retained++; reasons.add("JOURNAL_OR_PROVIDER_UNAVAILABLE");
                }
            }
            Map<String, Object> result = new HashMap<>();
            result.put("examined", examined); result.put("removedRecords", removed);
            result.put("deletedDocuments", deleted); result.put("retainedTransactions", retained);
            result.put("activeTransactions", active); result.put("publishedReceipts", published);
            result.put("truncated", ids.size() > limit); result.put("reasons", reasons);
            // Private method-channel contract only. Dart consumes/removes lease candidates before any UI/API report.
            result.put("recoveryCleanupCandidates", recoveryCleanupCandidates);
            result.put("publicationReconcileCandidates", publicationReconcileCandidates);
            result.put("publishedStagingCleanupCandidates", publishedStagingCleanupCandidates);
            return result;
        }
    }
    private static Manager manager;
    public static synchronized Manager manager(Context context) {
        if (manager == null) manager = new Manager(context);
        return manager;
    }
    private void checkCreation() throws IOException { if (!allowCreation.getAsBoolean()) throw failure("CANCELLED", "Workspace write was cancelled"); }
    private static final class Live {
        final String id, lease;
        final ParcelFileDescriptor cache, staging;
        final String cacheUri, stagingUri;
        boolean released;
        boolean cacheDeleted, stagingDeleted;
        Live(SafReceiveTransaction.Record record, ParcelFileDescriptor cache, ParcelFileDescriptor staging) {
            id = record.id; lease = record.lease; this.cache = cache; this.staging = staging;
            cacheUri = record.cache.uri; stagingUri = record.staging.uri;
        }
    }
    private final Map<String, Live> live = new HashMap<>();
    private final Map<String, ParcelFileDescriptor> publicationFiles = new HashMap<>();

    private static final class StagingWitness {
        final SafReceiveTransaction.Record record;
        final String token;
        final ParcelFileDescriptor witness;
        final long[] stamp;
        boolean deleteAttempted;
        StagingWitness(SafReceiveTransaction.Record record, String token, ParcelFileDescriptor witness, long[] stamp) {
            this.record = record; this.token = token; this.witness = witness; this.stamp = stamp;
        }
        void requireUnchanged() throws IOException {
            if (!Arrays.equals(stamp, stageStamp(witness))) throw failure("OWNERSHIP_UNPROVEN", "Published staging changed after handoff");
        }
    }
    private static long[] stageStamp(ParcelFileDescriptor descriptor) throws IOException {
        // Nanosecond metadata is public only from API 27. Older platforms retain
        // staging rather than pretending second-resolution stamps detect rewrites.
        if (android.os.Build.VERSION.SDK_INT < 27) throw failure("CAPABILITY_UNSUPPORTED", "Precise staging metadata is unavailable");
        try {
            android.system.StructStat stat = regular(descriptor);
            if (stat.st_mtim == null || stat.st_ctim == null) throw failure("CAPABILITY_UNSUPPORTED", "Precise staging metadata is unavailable");
            return new long[] {stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtim.tv_sec, stat.st_mtim.tv_nsec, stat.st_ctim.tv_sec, stat.st_ctim.tv_nsec};
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    public static final class StagingPreparation implements java.io.Closeable {
        public final String transactionId, cleanupId, sha256;
        public final long length;
        public final ParcelFileDescriptor descriptor;
        StagingPreparation(String transactionId, String cleanupId, long length, String sha256, ParcelFileDescriptor descriptor) {
            this.transactionId = transactionId; this.cleanupId = cleanupId;
            this.length = length; this.sha256 = sha256; this.descriptor = descriptor;
        }
        @Override public void close() throws IOException { descriptor.close(); }
    }
    static boolean hasPublishedStagingProof(SafReceiveTransaction.Record record) throws IOException {
        if (!hasPublicationReconcileProof(record) || !hasDescriptorProof(record, record.staging)) return false;
        JSONObject stage = proof(record.staging.uri, record.staging.identity), output = proof(record.output.uri, record.output.identity);
        if (!(".legnasend-receive-" + record.id + ".part").equals(get(stage, "name")) || sameInodeProof(stage, output)) return false;
        if (record.cache != null) {
            if (!hasDescriptorProof(record, record.cache)) return false;
            if (sameInodeProof(stage, proof(record.cache.uri, record.cache.identity))) return false;
        }
        return true;
    }
    private static boolean sameInodeProof(JSONObject a, JSONObject b) throws IOException {
        try { return a.getLong("device") == b.getLong("device") && a.getLong("inode") == b.getLong("inode"); }
        catch (JSONException error) { throw new IOException("Invalid document identity", error); }
    }
    private void requireAccess(ParcelFileDescriptor descriptor, int expected) throws IOException {
        try {
            if ((Os.fcntlInt(descriptor.getFileDescriptor(), OsConstants.F_GETFL, 0) & OsConstants.O_ACCMODE) != expected)
                throw failure("CAPABILITY_UNSUPPORTED", "Descriptor access differs from cleanup contract");
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    private synchronized void validatePublishedStaging(SafReceiveTransaction.Record record, ParcelFileDescriptor witness) throws IOException {
        if (record.state != SafReceiveTransaction.State.PUBLISHED || !record.receiveReleased || live.containsKey(record.id)
                || !hasPublishedStagingProof(record)) throw failure("OWNERSHIP_UNPROVEN", "Published staging ownership is unavailable");
        authorize(record.tree, record.parent);
        revalidate(record.staging, record.parent, witness);
        requireRecoveryLength(witness, record.size);
        requireDifferentDocument(record.output, record.parent, witness);
        if (record.cache != null) requireDifferentDocument(record.cache, record.parent, witness);
    }
    private void requireDifferentDocument(SafReceiveTransaction.Document document, String parent, ParcelFileDescriptor staging) throws IOException {
        try (ParcelFileDescriptor other = openRead(document.uri)) {
            revalidate(document, parent, other);
            android.system.StructStat a = regular(staging), b = regular(other);
            if (a.st_dev == b.st_dev && a.st_ino == b.st_ino)
                throw failure("DOCUMENT_ALIAS", "Staging aliases a protected document");
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    private static final class PublicationWitness {
        final SafReceiveTransaction.Record record;
        final String token;
        final ParcelFileDescriptor witness;
        boolean confirmed;
        PublicationWitness(SafReceiveTransaction.Record record, String token, ParcelFileDescriptor witness) {
            this.record = record; this.token = token; this.witness = witness;
        }
    }
    public static final class PublicationPreparation implements java.io.Closeable {
        public final String transactionId, reconciliationId, sha256;
        public final long size;
        public final ParcelFileDescriptor descriptor;
        PublicationPreparation(String transactionId, String reconciliationId, long size, String sha256, ParcelFileDescriptor descriptor) {
            this.transactionId = transactionId; this.reconciliationId = reconciliationId;
            this.size = size; this.sha256 = sha256; this.descriptor = descriptor;
        }
        @Override public void close() throws IOException { descriptor.close(); }
    }
    /** Parse only the private proof: scanning never touches a provider. */
    static boolean hasPublicationReconcileProof(SafReceiveTransaction.Record record) throws IOException {
        return hasDescriptorProof(record, record.output);
    }
    private static boolean hasDescriptorProof(SafReceiveTransaction.Record record, SafReceiveTransaction.Document document) throws IOException {
        if (document == null || document.uri == null || document.identity == null) return false;
        JSONObject evidence = proof(document.uri, document.identity);
        try {
            Object version = evidence.get("version"), device = evidence.get("device"), inode = evidence.get("inode"), name = evidence.get("name");
            return (version instanceof Integer || version instanceof Long) && ((Number) version).longValue() == 2
                && record.id.equals(evidence.get("transactionId")) && document.uri.equals(evidence.get("uri"))
                && record.parent.equals(evidence.get("parent")) && name instanceof String && !((String) name).isEmpty()
                && ((String) name).indexOf('\0') < 0
                && (device instanceof Integer || device instanceof Long) && ((Number) device).longValue() >= 0
                && (inode instanceof Integer || inode instanceof Long) && ((Number) inode).longValue() > 0;
        } catch (JSONException error) { throw new IOException("Invalid publication evidence", error); }
    }
    private synchronized void validatePublicationReconcile(SafReceiveTransaction.Record record, ParcelFileDescriptor witness) throws IOException {
        if (live.containsKey(record.id) || !hasPublicationReconcileProof(record))
            throw failure("OWNERSHIP_UNPROVEN", "Publication ownership is unavailable");
        authorize(record.tree, record.parent);
        try {
            if ((Os.fcntlInt(witness.getFileDescriptor(), OsConstants.F_GETFL, 0) & OsConstants.O_ACCMODE) != OsConstants.O_RDONLY)
                throw failure("CAPABILITY_UNSUPPORTED", "Publication reconciliation requires read-only descriptors");
        } catch (ErrnoException error) { throw new IOException(error); }
        revalidate(record.output, record.parent, witness);
        requireRecoveryLength(witness, record.size);
    }
    private static final class CleanupWitness {
        final String sourceId, lease, sha256;
        final long length;
        final ParcelFileDescriptor witness;
        boolean deleteAttempted;
        CleanupWitness(String sourceId, String lease, long length, String sha256, ParcelFileDescriptor witness) {
            this.sourceId = sourceId; this.lease = lease; this.length = length; this.sha256 = sha256; this.witness = witness;
        }
    }
    public static final class CleanupPreparation implements java.io.Closeable {
        public final String transactionId, sourceTransactionId, sourceSha256;
        public final long sourceLength;
        public final ParcelFileDescriptor descriptor;
        CleanupPreparation(String transactionId, String sourceTransactionId, long sourceLength, String sourceSha256, ParcelFileDescriptor descriptor) {
            this.transactionId = transactionId; this.sourceTransactionId = sourceTransactionId;
            this.sourceLength = sourceLength; this.sourceSha256 = sourceSha256; this.descriptor = descriptor;
        }
        @Override public void close() throws IOException { descriptor.close(); }
    }
    private void requireRecoveryLength(ParcelFileDescriptor descriptor, long expected) throws IOException {
        try {
            if (regular(descriptor).st_size != expected) throw failure("OWNERSHIP_UNPROVEN", "Recovery container length changed");
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    public static final class IdentityBinding implements java.io.Closeable {
        public final String transactionId, coreAttemptId;
        public String sourceId, identityJson;
        public ParcelFileDescriptor source;
        IdentityBinding(String transactionId, String coreAttemptId) { this.transactionId = transactionId; this.coreAttemptId = coreAttemptId; }
        @Override public void close() throws IOException { if (source != null) source.close(); }
    }
    private static final class RecoveryWitness implements java.io.Closeable {
        final String sourceId, targetId;
        final ParcelFileDescriptor witness;
        ParcelFileDescriptor transport;
        boolean copied;
        RecoveryWitness(String sourceId, String targetId, ParcelFileDescriptor witness, ParcelFileDescriptor transport) {
            this.sourceId = sourceId; this.targetId = targetId; this.witness = witness; this.transport = transport;
        }
        @Override public void close() throws IOException {
            try { witness.close(); } finally { if (transport != null) transport.close(); }
        }
    }
    private synchronized RecoveryWitness openRecoverySource(SafReceiveTransaction.Record source, String targetId) throws IOException {
        if (live.containsKey(source.id)) throw failure("BUSY", "Source receive is active");
        ParcelFileDescriptor witness = openRead(source.cache.uri), transport = null;
        try {
            validateRecoverySource(source, witness);
            transport = openRead(source.cache.uri); sameFile(witness, transport);
            return new RecoveryWitness(source.id, targetId, witness, transport);
        } catch (IOException | RuntimeException error) {
            try { witness.close(); } finally { if (transport != null) transport.close(); }
            throw error;
        }
    }
    private synchronized void validateRecoverySource(SafReceiveTransaction.Record source, ParcelFileDescriptor witness) throws IOException {
        if (source.cache == null || source.recoveryIdentity == null || source.output != null || source.receiveReleased
                || source.state != SafReceiveTransaction.State.RECEIVING || live.containsKey(source.id))
            throw failure("STALE_HANDOFF", "Source is not an interrupted receive");
        authorize(source.tree, source.parent);
        revalidate(source.cache, source.parent, witness);
        try {
            Os.lseek(witness.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            String header;
            try (ParcelFileDescriptor.AutoCloseInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(witness.dup())) {
                header = SafCacheHeader.read(input);
            }
            SafReceiveTransaction.CacheIdentity expected = parseCacheIdentity(source.recoveryIdentity), actual = parseCacheIdentity(header);
            expected.validate(source.id); actual.validate(source.id);
            if (!expected.json.equals(actual.json)) throw failure("OWNERSHIP_UNPROVEN", "Recovery cache header differs from private identity");
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    public static final class OpenedPair implements java.io.Closeable {
        public final String transactionId, lease;
        public final ParcelFileDescriptor cache, staging;
        OpenedPair(String id, String lease, ParcelFileDescriptor cache, ParcelFileDescriptor staging) {
            transactionId = id; this.lease = lease; this.cache = cache; this.staging = staging;
        }
        @Override public void close() throws IOException {
            try { cache.close(); } finally { staging.close(); }
        }
    }
    public synchronized OpenedPair duplicatePair(SafReceiveTransaction.Record record) throws IOException {
        Live owned = live(record);
        // Independent opens, not dup(): a dup shares the open-file description
        // and would keep Rust's flock alive through the platform identity handle.
        checkCreation();
        ParcelFileDescriptor cache = open(record.cache.uri), staging = null;
        try {
            checkCreation(); staging = open(record.staging.uri); checkCreation();
            sameFile(owned.cache, cache); sameFile(owned.staging, staging);
            return new OpenedPair(record.id, record.lease, cache, staging);
        } catch (IOException | RuntimeException error) {
            try { cache.close(); } finally { if (staging != null) staging.close(); }
            throw error;
        }
    }
    private static void sameFile(ParcelFileDescriptor held, ParcelFileDescriptor current) throws IOException {
        try {
            android.system.StructStat a = regular(held), b = regular(current);
            if (a.st_dev != b.st_dev || a.st_ino != b.st_ino) throw failure("OWNERSHIP_UNPROVEN", "Provider changed descriptor identity");
        } catch (ErrnoException e) { throw new IOException(e); }
    }
    private Live live(SafReceiveTransaction.Record record) throws IOException {
        Live owned = live.get(record.id);
        if (owned == null || !java.util.Objects.equals(owned.lease, record.lease)) {
            throw failure("OWNERSHIP_UNPROVEN", "Receive descriptor ownership is unavailable; transaction retained");
        }
        return owned;
    }
    @Override public synchronized void prepareReceive(SafReceiveTransaction.Record record) throws IOException {
        checkCreation();
        if (live.size() >= 64 || live.containsKey(record.id)) throw failure("BUSY", "Receive descriptor budget is exhausted");
        authorize(record.tree, record.parent);
        JSONObject cacheProof = proof(record.cache.uri, record.cache.identity);
        JSONObject stagingProof = proof(record.staging.uri, record.staging.identity);
        requireDocument(record.cache.uri, record.parent, get(cacheProof, "name"));
        requireDocument(record.staging.uri, record.parent, get(stagingProof, "name"));
        ParcelFileDescriptor cache = open(record.cache.uri), staging = null;
        boolean owned = false;
        try {
            checkCreation(); staging = open(record.staging.uri); checkCreation();
            android.system.StructStat a = regular(cache), b = regular(staging);
            if (a.st_dev == b.st_dev && a.st_ino == b.st_ino) throw failure("DOCUMENT_ALIAS", "Cache and staging share one file");
            verifyMarker(cache, get(cacheProof, "marker").getBytes(StandardCharsets.UTF_8));
            verifyMarker(staging, get(stagingProof, "marker").getBytes(StandardCharsets.UTF_8));
            live.put(record.id, new Live(record, cache, staging)); owned = true;
            record.cache = new SafReceiveTransaction.Document(record.cache.uri, descriptorProof(record.id, record.cache.uri, cacheProof, a));
            record.staging = new SafReceiveTransaction.Document(record.staging.uri, descriptorProof(record.id, record.staging.uri, stagingProof, b));
            // No Rust writer exists yet. The markers were revalidated under this
            // process's serialized transaction manager before the one-time handoff.
            Os.ftruncate(cache.getFileDescriptor(), 0); Os.lseek(cache.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            Os.ftruncate(staging.getFileDescriptor(), 0); Os.lseek(staging.getFileDescriptor(), 0, OsConstants.SEEK_SET);
        } catch (ErrnoException | JSONException e) { throw failure("CAPABILITY_UNSUPPORTED", "Receive marker handoff failed", e); }
        finally { if (!owned) { try { cache.close(); } finally { if (staging != null) staging.close(); } } }
    }
    @Override public SafReceiveTransaction.CacheIdentity parseCacheIdentity(String json) throws IOException {
        if (json == null || json.getBytes(StandardCharsets.UTF_8).length > 16384) throw failure("INVALID_ARGUMENT", "Oversized cache identity");
        try {
            JSONObject value = new JSONObject(json);
            String[] strings = {"taskId", "sourceId", "resourceId", "version", "fileName", "sha256"};
            String[] numbers = {"size", "chunkSize", "createdUnixMs"};
            if (value.length() != strings.length + numbers.length) throw new JSONException("Unexpected identity fields");
            JSONObject canonical = new JSONObject();
            for (String key : strings) {
                Object item = value.get(key);
                if (!(item instanceof String)) throw new JSONException("Expected identity string");
                canonical.put(key, item);
            }
            for (String key : numbers) {
                Object item = value.get(key);
                if (!(item instanceof Integer) && !(item instanceof Long)) throw new JSONException("Expected identity integer");
                canonical.put(key, item);
            }
            return new SafReceiveTransaction.CacheIdentity(canonical.toString(), value.getString("taskId"), value.getString("sourceId"),
                value.getString("resourceId"), value.getString("version"), value.getString("fileName"), value.getLong("size"),
                value.getLong("chunkSize"), value.getLong("createdUnixMs"), value.getString("sha256"));
        } catch (JSONException invalid) { throw failure("INVALID_ARGUMENT", "Invalid cache identity JSON", invalid); }
    }
    @Override public synchronized void validateIdentityBinding(SafReceiveTransaction.Record record, boolean requireEmpty) throws IOException {
        Live owned = live(record);
        if (owned.released || record.receiveReleased || record.state != SafReceiveTransaction.State.RECEIVING)
            throw failure("STALE_HANDOFF", "Receive identity references were released");
        revalidate(record.cache, record.parent, owned.cache);
        revalidate(record.staging, record.parent, owned.staging);
        try {
            android.system.StructStat cache = regular(owned.cache), staging = regular(owned.staging);
            if (cache.st_dev == staging.st_dev && cache.st_ino == staging.st_ino)
                throw failure("DOCUMENT_ALIAS", "Receive documents share one file");
            if (requireEmpty && (cache.st_size != 0 || staging.st_size != 0))
                throw failure("STALE_HANDOFF", "Cache identity must be bound before writing");
        } catch (ErrnoException error) { throw new IOException(error); }
    }
    @Override public synchronized void verifyStaging(SafReceiveTransaction.Record record, long size, String sha256) throws IOException {
        authorize(record.tree, record.parent);
        Live owned = live(record);
        revalidate(record.cache, record.parent, owned.cache);
        revalidate(record.staging, record.parent, owned.staging);
        verifyCacheHeader(owned.cache, record.id, size, false);
        verifyBytes(owned.staging, size, sha256);
        // This method is reachable only from the trusted core publication event,
        // emitted after both Rust descriptors have closed. Java fcntl locks are
        // not a substitute for Rust flock and never authorize receiving cleanup.
        owned.released = true;
    }
    @Override public synchronized String createPublication(SafReceiveTransaction.Record record) throws IOException {
        authorize(record.tree, record.parent);
        live(record);
        return create(record.parent, record.desiredName);
    }
    @Override public synchronized String publicationIdentity(SafReceiveTransaction.Record record, String uri) throws IOException {
        String name = createdNames.remove(uri), parent = createdParents.remove(uri);
        if (name == null || parent == null || !record.parent.equals(parent)) throw failure("OWNERSHIP_UNPROVEN", "Publication is not a fresh document");
        // Providers may choose a collision-safe display name. Accept the actual
        // name only for a fresh provider ID, never by reopening a guessed name.
        SafDirectoryResolver.Document actual = directories.stat(uri);
        if (actual == null || actual.directory) throw failure("OWNERSHIP_UNPROVEN", "Publication document is unavailable");
        SafDirectoryResolver.validateName(actual.name);
        if (exactPublicationName && !record.desiredName.equals(actual.name)) {
            throw failure("NAME_CONFLICT", "Provider renamed the workspace publication");
        }
        name = actual.name;
        requireDocument(uri, parent, name);
        if (uri.equals(record.cache.uri) || uri.equals(record.staging.uri)) throw failure("DOCUMENT_ALIAS", "Publication aliases receive staging");
        ParcelFileDescriptor fd = open(uri);
        boolean retained = false;
        try {
            android.system.StructStat stat = regular(fd);
            Live owned = live(record);
            android.system.StructStat cache = regular(owned.cache), staging = regular(owned.staging);
            if ((stat.st_dev == cache.st_dev && stat.st_ino == cache.st_ino)
                    || (stat.st_dev == staging.st_dev && stat.st_ino == staging.st_ino) || stat.st_size != 0) {
                throw failure("OWNERSHIP_UNPROVEN", "Publication file is nonempty or aliases transaction data");
            }
            JSONObject proof = new JSONObject().put("parent", parent).put("name", name);
            String identity = descriptorProof(record.id, uri, proof, stat);
            publicationFiles.put(record.id, fd); retained = true;
            return identity;
        } catch (ErrnoException | JSONException e) { throw new IOException(e); }
        finally { if (!retained) fd.close(); }
    }
    @Override public synchronized void copyPublication(SafReceiveTransaction.Record record, long size, String sha256) throws IOException {
        Live owned = live(record);
        ParcelFileDescriptor output = publicationFiles.get(record.id);
        if (output == null || !owned.released) throw failure("OWNERSHIP_UNPROVEN", "Publication descriptor is unavailable");
        try {
            authorize(record.tree, record.parent);
            revalidate(record.staging, record.parent, owned.staging);
            revalidate(record.output, record.parent, output);
            if (regular(output).st_size != 0) throw failure("OWNERSHIP_UNPROVEN", "Publication file changed before copy");
        } catch (IOException | ErrnoException | RuntimeException uncertain) {
            throw new SafReceiveTransaction.PublicationUncertain("Publication ownership changed before copy", uncertain);
        }
        try {
            Os.lseek(owned.staging.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            Os.lseek(output.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            // Hash the bytes while copying instead of rereading the entire
            // writable output. Staging was fully validated before output creation;
            // a full independent provider read-back still follows writer close.
            SafVerifiedCopy.copy(
                (buffer, offset, length) -> {
                    try { return Os.read(owned.staging.getFileDescriptor(), buffer, offset, length); }
                    catch (ErrnoException error) { throw new IOException(error); }
                },
                (buffer, offset, length) -> {
                    try { return Os.write(output.getFileDescriptor(), buffer, offset, length); }
                    catch (ErrnoException error) { throw new IOException(error); }
                }, size, sha256);
            if (regular(output).st_size != size) throw failure("CHECKSUM_MISMATCH", "Publication size differs from verified content");
            Os.fsync(output.getFileDescriptor());
            revalidate(record.output, record.parent, output);
        } catch (SafVerifiedCopy.Mismatch error) {
            throw failure("CHECKSUM_MISMATCH", error.getMessage(), error);
        } catch (ErrnoException e) { throw new IOException(e); }
        // Some providers publish on writer close. Pin identity with a read-only
        // reference, close the writer, then independently reopen and verify the
        // provider-visible document before allowing a durable success receipt.
        // Failure from this point may be an already-committed publication: retain.
        try (ParcelFileDescriptor witness = openRead(record.output.uri)) {
            sameFile(output, witness);
            output.close();
            ParcelFileDescriptor visible = openRead(record.output.uri);
            boolean retained = false;
            try {
                sameFile(witness, visible);
                revalidate(record.output, record.parent, visible);
                verifyBytes(visible, size, sha256);
                publicationFiles.put(record.id, visible); retained = true;
            } finally { if (!retained) visible.close(); }
        } catch (IOException | RuntimeException uncertain) {
            throw new SafReceiveTransaction.PublicationUncertain("Publication close or read-back is uncertain; document retained", uncertain);
        }
        // Only the read-only identity reference remains through receipt persistence.
    }
    @Override public synchronized void releaseReceive(SafReceiveTransaction.Record record) throws IOException {
        Live owned = live.get(record.id);
        if (owned == null) return; // No live proof after restart: version-2 cleanup retains documents.
        if (!java.util.Objects.equals(owned.lease, record.lease)) throw failure("STALE_HANDOFF", "Receive lease differs");
        owned.released = true;
    }
    @Override public synchronized boolean deleteFailedPublication(SafReceiveTransaction.Record record) throws IOException {
        if (record.state != SafReceiveTransaction.State.PUBLICATION_FAILED || record.output == null
                || record.output.identity == null) return false;
        Live owned = live.get(record.id);
        ParcelFileDescriptor held = publicationFiles.get(record.id);
        if (owned == null || !owned.released || held == null) return false;
        if (record.output.uri.equals(owned.cacheUri) || record.output.uri.equals(owned.stagingUri)) return false;
        JSONObject evidence = proof(record.output.uri, record.output.identity);
        if (!record.id.equals(get(evidence, "transactionId"))) return false;
        authorize(record.tree, record.parent);
        revalidate(record.output, record.parent, held);
        // Only a durably recorded explicit copy/hash failure can reach here.
        // PUBLISHING crash ambiguity and every PUBLISHED receipt retain output.
        // Close the failed writer BEFORE deletion: a provider may commit on
        // close. A read-only witness pins its inode across the independent reopen.
        // Any close/reopen/identity failure retains the output, never guesses.
        try (ParcelFileDescriptor witness = openRead(record.output.uri)) {
            sameFile(held, witness);
            held.close();
            try (ParcelFileDescriptor visible = openRead(record.output.uri)) {
                sameFile(witness, visible);
                revalidate(record.output, record.parent, visible);
                boolean deleted = DocumentsContract.deleteDocument(resolver, Uri.parse(record.output.uri));
                if (deleted) publicationFiles.remove(record.id);
                return deleted;
            }
        }
    }
    @Override public synchronized void closeReceive(SafReceiveTransaction.Record record) throws IOException {
        Live owned = live.get(record.id);
        if (owned == null) return;
        if (!owned.released) throw failure("ACTIVE_RECEIVE", "Core descriptor release is not confirmed");
        // Called in the transaction manager's finally AFTER trusted release and
        // one cleanup attempt. Unknown/revoked documents remain on disk; closing
        // identity references does not authorize future deletion after restart.
        live.remove(record.id);
        ParcelFileDescriptor output = publicationFiles.remove(record.id);
        try {
            try { owned.cache.close(); } finally { owned.staging.close(); }
        } finally { if (output != null) output.close(); }
    }
    private static android.system.StructStat regular(ParcelFileDescriptor fd) throws ErrnoException, IOException {
        android.system.StructStat stat = Os.fstat(fd.getFileDescriptor());
        if (!OsConstants.S_ISREG(stat.st_mode)) throw failure("CAPABILITY_UNSUPPORTED", "A regular seekable document is required");
        Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_CUR);
        return stat;
    }
    private static String descriptorProof(String id, String uri, JSONObject old, android.system.StructStat stat) throws JSONException, IOException {
        return new JSONObject().put("version", 2).put("transactionId", id).put("uri", uri)
            .put("parent", get(old, "parent")).put("name", get(old, "name"))
            .put("device", stat.st_dev).put("inode", stat.st_ino).toString();
    }
    private void revalidate(SafReceiveTransaction.Document document, String parent, ParcelFileDescriptor held) throws IOException {
        JSONObject evidence = proof(document.uri, document.identity);
        requireDocument(document.uri, parent, get(evidence, "name"));
        try (ParcelFileDescriptor current = openRead(document.uri)) {
            android.system.StructStat a = regular(held), b = regular(current);
            if (a.st_dev != b.st_dev || a.st_ino != b.st_ino
                    || a.st_dev != evidence.getLong("device") || a.st_ino != evidence.getLong("inode")) {
                throw failure("OWNERSHIP_UNPROVEN", "Provider document identity changed");
            }
        } catch (ErrnoException | JSONException e) { throw new IOException(e); }
    }
    private static void verifyCacheHeader(ParcelFileDescriptor fd, String transactionId, long expectedSize, boolean allowEmpty) throws IOException {
        try {
            long length = regular(fd).st_size;
            if (allowEmpty && length == 0) return; // Trusted release before any Rust payload write.
            Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            final String json;
            try (ParcelFileDescriptor.AutoCloseInputStream input = new ParcelFileDescriptor.AutoCloseInputStream(fd.dup())) {
                json = SafCacheHeader.read(input);
            }
            JSONObject identity = new JSONObject(json);
            if (!transactionId.equals(identity.getString("taskId"))
                    || (expectedSize >= 0 && expectedSize != identity.getLong("size"))) {
                throw failure("OWNERSHIP_UNPROVEN", "Receive cache belongs to another transaction");
            }
        } catch (ErrnoException | JSONException e) { throw new IOException(e); }
    }
    private static void verifyBytes(ParcelFileDescriptor fd, long size, String expected) throws IOException {
        if (size < 0 || expected == null || !expected.matches("[a-fA-F0-9]{64}")) throw failure("INVALID_ARGUMENT", "Missing verified content receipt");
        try {
            if (regular(fd).st_size != size) throw failure("CHECKSUM_MISMATCH", "Verified document size differs");
            java.security.MessageDigest digest = java.security.MessageDigest.getInstance("SHA-256");
            Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            byte[] buffer = new byte[64 * 1024]; long total = 0;
            while (true) {
                int count = Os.read(fd.getFileDescriptor(), buffer, 0, buffer.length);
                if (count == 0) break;
                if (count < 0 || count > size - total) throw failure("CHECKSUM_MISMATCH", "Verified document changed while reading");
                digest.update(buffer, 0, count); total += count;
            }
            StringBuilder actual = new StringBuilder(64);
            for (byte b : digest.digest()) actual.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            if (total != size || !actual.toString().equalsIgnoreCase(expected)) throw failure("CHECKSUM_MISMATCH", "Verified document checksum differs");
        } catch (ErrnoException | java.security.NoSuchAlgorithmException e) { throw new IOException(e); }
    }

    @Override public void authorize(String tree, String parent) throws IOException {
        String root = directories.writableRoot(tree);
        Uri rootUri = Uri.parse(root);
        Uri parentUri = Uri.parse(parent);
        requireSameTree(rootUri, parentUri);
        if (!root.equals(parent)) {
            // Provider-owned membership, never infer descendant document IDs from path text.
            if (!DocumentsContract.isChildDocument(resolver, rootUri, parentUri)) {
                throw failure("PERMISSION_DENIED", "Parent is outside the selected document tree");
            }
        }
        SafDirectoryResolver.Document document = directories.stat(parent);
        if (document == null || !document.directory || !document.canCreate) {
            throw failure("DIRECTORY_UNAVAILABLE", "The destination is not a writable directory");
        }
    }

    @Override public String create(String parent, String name) throws IOException {
        checkCreation();
        Set<String> before = childIds(parent);
        checkCreation();
        Uri result = DocumentsContract.createDocument(resolver, Uri.parse(parent), "application/octet-stream", name);
        if (result == null) throw failure("CREATE_FAILED", "Provider returned no created document");
        // Return every actual URI for durable accounting, even an unexpected provider result.
        // Only validated fresh IDs can acquire proof. Unknown results are retained, never opened/deleted.
        try {
            requireSameTree(Uri.parse(parent), result);
            String id = DocumentsContract.getDocumentId(result);
            if (!before.contains(id)) {
                createdNames.put(result.toString(), name);
                createdParents.put(result.toString(), parent);
            }
        } catch (IOException | IllegalArgumentException ignored) {
            // identity() will reject it after the transaction records the actual provider URI.
        }
        return result.toString();
    }

    @Override public String identity(String value) throws IOException {
        String expectedName = createdNames.remove(value);
        String parent = createdParents.remove(value);
        if (expectedName == null || parent == null) throw failure("OWNERSHIP_UNPROVEN", "No fresh creation evidence");
        requireDocument(value, parent, expectedName);
        String marker = "LegnaSend SAF probe 1 " + UUID.randomUUID() + "\n";
        byte[] bytes = marker.getBytes(StandardCharsets.UTF_8);
        try (ParcelFileDescriptor fd = open(value);
             ParcelFileDescriptor.AutoCloseOutputStream lockStream = new ParcelFileDescriptor.AutoCloseOutputStream(fd.dup());
             FileLock lock = lockStream.getChannel().tryLock()) {
            if (lock == null) throw failure("CAPABILITY_UNSUPPORTED", "Exclusive locking is unavailable");
            if (Os.fstat(fd.getFileDescriptor()).st_size != 0) throw failure("OWNERSHIP_UNPROVEN", "Created document was not empty");
            Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_SET);
            writeAll(fd, bytes);
            Os.fsync(fd.getFileDescriptor());
        } catch (ErrnoException | RuntimeException e) {
            throw failure("CAPABILITY_UNSUPPORTED", "A seekable writable descriptor is required", e);
        }
        try {
            return new JSONObject().put("version", 1).put("uri", value).put("parent", parent)
                .put("name", expectedName).put("marker", marker).toString();
        } catch (JSONException e) { throw new IOException(e); }
    }

    @Override public void probe(String value, String identity) throws IOException {
        JSONObject proof = proof(value, identity);
        requireDocument(value, get(proof, "parent"), get(proof, "name"));
        byte[] marker = get(proof, "marker").getBytes(StandardCharsets.UTF_8);
        try (ParcelFileDescriptor fd = open(value);
             ParcelFileDescriptor.AutoCloseOutputStream lockStream = new ParcelFileDescriptor.AutoCloseOutputStream(fd.dup());
             FileLock lock = lockStream.getChannel().tryLock()) {
            if (lock == null) throw failure("CAPABILITY_UNSUPPORTED", "Exclusive locking is unavailable");
            verifyMarker(fd, marker);
            Os.lseek(fd.getFileDescriptor(), marker.length, OsConstants.SEEK_SET);
            writeAll(fd, new byte[] { 42 });
            if (Os.fstat(fd.getFileDescriptor()).st_size != marker.length + 1) {
                throw failure("CAPABILITY_UNSUPPORTED", "Provider length query did not reflect writes");
            }
            Os.ftruncate(fd.getFileDescriptor(), marker.length);
            Os.fsync(fd.getFileDescriptor());
            verifyMarker(fd, marker);
        } catch (ErrnoException | RuntimeException e) {
            throw failure("CAPABILITY_UNSUPPORTED", "Provider must support read/write, seek, truncate, length and exclusive locks", e);
        }
    }

    @Override public boolean deleteOwned(String tree, String parent, String value, String identity) throws IOException {
        authorize(tree, parent);
        JSONObject proof = proof(value, identity);
        if (!parent.equals(get(proof, "parent"))) return false;
        requireDocument(value, parent, get(proof, "name"));
        if (proof.optInt("version") == 2) {
            Live owned = live.get(get(proof, "transactionId"));
            if (owned == null || !owned.released) return false;
            boolean cache = value.equals(owned.cacheUri), staging = value.equals(owned.stagingUri);
            if (!cache && !staging) return false; // Final publications are never cleanup targets.
            ParcelFileDescriptor held = cache ? owned.cache : owned.staging;
            revalidate(new SafReceiveTransaction.Document(value, identity), parent, held);
            if (cache) verifyCacheHeader(held, owned.id, -1, true);
            boolean deleted = DocumentsContract.deleteDocument(resolver, Uri.parse(value));
            if (deleted) {
                held.close();
                if (cache) owned.cacheDeleted = true; else owned.stagingDeleted = true;
                // Keep the transaction authority until closeReceive: a known
                // failed publication may still need its independently held output.

            }
            return deleted;
        }
        try (ParcelFileDescriptor fd = open(value);
             ParcelFileDescriptor.AutoCloseOutputStream lockStream = new ParcelFileDescriptor.AutoCloseOutputStream(fd.dup());
             FileLock lock = lockStream.getChannel().tryLock()) {
            if (lock == null) return false;
            verifyMarker(fd, get(proof, "marker").getBytes(StandardCharsets.UTF_8));
            return DocumentsContract.deleteDocument(resolver, Uri.parse(value));
        } catch (ErrnoException | RuntimeException e) {
            throw failure("CLEANUP_PENDING", "Ownership or provider capability could not be revalidated", e);
        }
    }

    /** App-private durable records; no directory scan and no cleanup by extension. */
    public static final class Journal implements SafReceiveTransaction.Journal {
        private final File directory;
        public Journal(Context context) { this(context, "saf-receive-transactions-v1"); }
        Journal(Context context, String namespace) {
            if (!namespace.matches("[a-z0-9-]+")) throw new IllegalArgumentException("namespace");
            directory = new File(context.getFilesDir(), namespace);
        }
        static final class IndexLock implements java.io.Closeable {
            final java.io.RandomAccessFile file;
            final FileLock lock;
            IndexLock(java.io.RandomAccessFile file, FileLock lock) { this.file = file; this.lock = lock; }
            @Override public void close() throws IOException { try { lock.release(); } finally { file.close(); } }
        }
        IndexLock recoveryLock() throws IOException {
            if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) throw new IOException("Recovery index unavailable");
            java.io.RandomAccessFile file = new java.io.RandomAccessFile(new File(directory, ".recovery-index.lock"), "rw");
            try {
                FileLock lock = file.getChannel().tryLock();
                if (lock == null) throw new IOException("Recovery index busy");
                return new IndexLock(file, lock);
            } catch (IOException | RuntimeException error) { file.close(); throw error; }
        }
        /** Enumerate only private journal filenames, never destination documents. */
        java.util.List<String> ids(int limit, String after) throws IOException {
            java.util.List<String> result = new java.util.ArrayList<>();
            if (!directory.exists()) return result;
            String[] names = directory.list();
            if (names == null) throw new IOException("Transaction journal listing is unavailable");
            // Keep only bounded candidates on either side of the process cursor.
            // AtomicFile .bak and primary names deduplicate to one transaction.
            java.util.TreeSet<String> next = new java.util.TreeSet<>(), wrapped = new java.util.TreeSet<>();
            for (String name : names) {
                String id = name.endsWith(".json.bak") ? name.substring(0, name.length() - 9)
                    : name.endsWith(".json") ? name.substring(0, name.length() - 5) : null;
                if (id == null) continue;
                try { if (!UUID.fromString(id).toString().equals(id)) continue; }
                catch (IllegalArgumentException invalid) { continue; }
                java.util.TreeSet<String> bucket = after == null || id.compareTo(after) > 0 ? next : wrapped;
                bucket.add(id);
                if (bucket.size() > limit) bucket.pollLast();
            }
            for (String id : next) { result.add(id); if (result.size() >= limit) return result; }
            for (String id : wrapped) { result.add(id); if (result.size() >= limit) return result; }
            return result;
        }
        private AtomicFile file(String id) throws IOException {
            try { if (!UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException(); }
            catch (IllegalArgumentException | NullPointerException e) { throw failure("INVALID_ARGUMENT", "Invalid transaction identifier", e); }
            if (!directory.isDirectory()) {
                if (!directory.mkdirs() && !directory.isDirectory()) throw new IOException("Cannot create transaction journal directory");
                syncDirectory(directory.getParentFile());
            }
            return new AtomicFile(new File(directory, id + ".json"));
        }
        @Override public void save(SafReceiveTransaction.Record record) throws IOException {
            AtomicFile target = file(record.id);
            FileOutputStream stream = null;
            try {
                JSONObject json = new JSONObject().put("version", 2).put("id", record.id).put("tree", record.tree)
                    .put("parent", record.parent).put("desiredName", record.desiredName).put("sessionId", record.sessionId)
                    .put("fileId", record.fileId).put("attemptId", record.attemptId).put("state", record.state.name())
                    .put("lease", record.lease == null ? JSONObject.NULL : record.lease)
                    .put("cache", documentJson(record.cache)).put("staging", documentJson(record.staging))
                    .put("output", documentJson(record.output)).put("size", record.size)
                    .put("sha256", record.sha256 == null ? JSONObject.NULL : record.sha256)
                    .put("coreAttempt", record.coreAttempt == null ? JSONObject.NULL : record.coreAttempt)
                    .put("receiveReleased", record.receiveReleased).put("stagingCleanupPending", record.stagingCleanupPending)
                    .put("recoveryIdentity", record.recoveryIdentity == null ? JSONObject.NULL : record.recoveryIdentity)
                    .put("recoverySourceId", record.recoverySourceId == null ? JSONObject.NULL : record.recoverySourceId)
                    .put("recoveryClaimId", record.recoveryClaimId == null ? JSONObject.NULL : record.recoveryClaimId)
                    .put("recoverySupersededBy", record.recoverySupersededBy == null ? JSONObject.NULL : record.recoverySupersededBy)
                    .put("recoveryCompleted", record.recoveryCompleted).put("recoveryRejected", record.recoveryRejected)
                    .put("recoveryRetentionMs", SafReceiveTransaction.recoveryRetentionMillis(record.recoveryRetentionMs))
                    .put("recoveryLength", record.recoveryLength)
                    .put("recoverySha256", record.recoverySha256 == null ? JSONObject.NULL : record.recoverySha256);
                byte[] bytes = json.toString().getBytes(StandardCharsets.UTF_8);
                stream = target.startWrite();
                stream.write(bytes);
                stream.getFD().sync();
                target.finishWrite(stream);
                stream = null;
                if (!Arrays.equals(target.readFully(), bytes)) throw new IOException("Transaction journal persistence mismatch");
                syncDirectory();
            } catch (IOException | JSONException | RuntimeException e) {
                if (stream != null) target.failWrite(stream);
                throw new IOException("Transaction journal write failed", e);
            }
        }
        @Override public SafReceiveTransaction.Record load(String id) throws IOException {
            AtomicFile target = file(id);
            if (!target.getBaseFile().exists() && !new File(target.getBaseFile().getPath() + ".bak").exists()) return null;
            try {
                if (target.getBaseFile().length() > 131072) throw new IOException("Transaction journal is oversized");
                byte[] bytes = target.readFully();
                if (bytes.length > 131072) throw new IOException("Transaction journal is oversized");
                JSONObject json = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
                if ((json.getInt("version") != 1 && json.getInt("version") != 2) || !id.equals(json.getString("id"))) throw new IOException("Transaction journal identity mismatch");
                SafReceiveTransaction.Record record = new SafReceiveTransaction.Record(id, json.getString("tree"), json.getString("parent"),
                    json.getString("desiredName"), json.getString("sessionId"), json.getString("fileId"), json.getString("attemptId"));
                record.recoveryRetentionMs = SafReceiveTransaction.recoveryRetentionMillis(
                    json.has("recoveryRetentionMs") ? json.get("recoveryRetentionMs") : null);
                record.state = SafReceiveTransaction.State.valueOf(json.getString("state"));
                record.lease = json.isNull("lease") ? null : json.getString("lease");
                record.cache = document(json, "cache"); record.staging = document(json, "staging");
                if (json.getInt("version") >= 2) {
                    record.output = document(json, "output"); record.size = json.getLong("size");
                    record.sha256 = json.isNull("sha256") ? null : json.getString("sha256");
                    record.coreAttempt = json.isNull("coreAttempt") ? null : json.getString("coreAttempt");
                    record.receiveReleased = json.getBoolean("receiveReleased");
                    if (json.has("stagingCleanupPending")) {
                        Object pending = json.get("stagingCleanupPending");
                        if (!(pending instanceof Boolean)) throw new JSONException("Invalid staging cleanup intent");
                        record.stagingCleanupPending = (Boolean) pending;
                    }
                    record.recoveryIdentity = json.isNull("recoveryIdentity") ? null : json.getString("recoveryIdentity");
                    record.recoverySourceId = json.isNull("recoverySourceId") ? null : json.getString("recoverySourceId");
                    record.recoveryClaimId = json.isNull("recoveryClaimId") ? null : json.getString("recoveryClaimId");
                    record.recoverySupersededBy = json.isNull("recoverySupersededBy") ? null : json.getString("recoverySupersededBy");
                    record.recoveryCompleted = json.optBoolean("recoveryCompleted", false);
                    record.recoveryRejected = json.optBoolean("recoveryRejected", false);
                    record.recoveryLength = json.optLong("recoveryLength", -1);
                    record.recoverySha256 = json.isNull("recoverySha256") ? null : json.getString("recoverySha256");
                }
                return record;
            } catch (JSONException | IllegalArgumentException e) { throw new IOException("Invalid transaction journal; retained for reconciliation", e); }
        }
        @Override public void remove(String id) throws IOException {
            AtomicFile target = file(id);
            target.delete();
            if (target.getBaseFile().exists() || new File(target.getBaseFile().getPath() + ".bak").exists()) {
                throw new IOException("Transaction journal deletion did not complete");
            }
            syncDirectory();
        }
        private void syncDirectory() throws IOException { syncDirectory(directory); }
        private static void syncDirectory(File directory) throws IOException {
            java.io.FileDescriptor descriptor = null;
            try {
                descriptor = Os.open(directory.getPath(), OsConstants.O_RDONLY, 0);
                Os.fsync(descriptor);
            } catch (ErrnoException e) { throw new IOException("Transaction journal directory sync failed", e); }
            finally {
                if (descriptor != null) try { Os.close(descriptor); } catch (ErrnoException e) { throw new IOException(e); }
            }
        }
        private static Object documentJson(SafReceiveTransaction.Document document) throws JSONException {
            if (document == null) return JSONObject.NULL;
            return new JSONObject().put("uri", document.uri).put("identity", document.identity == null ? JSONObject.NULL : document.identity);
        }
        private static SafReceiveTransaction.Document document(JSONObject json, String key) throws JSONException {
            if (json.isNull(key)) return null;
            JSONObject value = json.getJSONObject(key);
            return new SafReceiveTransaction.Document(value.getString("uri"), value.isNull("identity") ? null : value.getString("identity"));
        }
    }

    private ParcelFileDescriptor openRead(String value) throws IOException {
        ParcelFileDescriptor fd = resolver.openFileDescriptor(Uri.parse(value), "r");
        if (fd == null) throw failure("OPEN_FAILED", "Provider returned no readable descriptor");
        return fd;
    }
    private ParcelFileDescriptor open(String value) throws IOException {
        ParcelFileDescriptor fd = resolver.openFileDescriptor(Uri.parse(value), "rw");
        if (fd == null) throw failure("OPEN_FAILED", "Provider returned no read/write descriptor");
        return fd;
    }
    private void requireDocument(String value, String parent, String name) throws IOException {
        Uri uri = Uri.parse(value);
        requireSameTree(Uri.parse(parent), uri);
        SafDirectoryResolver.Document document = directories.stat(value);
        if (document == null || document.directory || !name.equals(document.name)
                || !childIds(parent).contains(DocumentsContract.getDocumentId(uri))) {
            throw failure("OWNERSHIP_UNPROVEN", "Created document identity or membership changed");
        }
    }
    private Set<String> childIds(String parent) throws IOException {
        Uri uri = Uri.parse(parent);
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getDocumentId(uri));
        Set<String> ids = new HashSet<>();
        try (Cursor cursor = resolver.query(children, new String[] { DocumentsContract.Document.COLUMN_DOCUMENT_ID }, null, null, null)) {
            if (cursor == null) throw failure("DIRECTORY_UNAVAILABLE", "Provider did not list the destination");
            requireComplete(cursor);
            int count = 0;
            long retainedBytes = 0;
            while (cursor.moveToNext()) {
                String id = cursor.getString(0);
                if (exactPublicationName && id != null) {
                    retainedBytes += 64L + id.length() * 2L;
                    if (id.length() > 8192 || retainedBytes > 16 * 1024 * 1024) throw failure("BUSY", "Workspace listing budget exceeded");
                }
                if (++count > 100000 || id == null || id.isEmpty() || !ids.add(id)) {
                    throw failure("DIRECTORY_UNAVAILABLE", "Incomplete or ambiguous destination listing");
                }
            }
            requireComplete(cursor);
        }
        return ids;
    }
    private static void requireComplete(Cursor cursor) throws IOException {
        Bundle extras = cursor.getExtras();
        SafDirectoryResolver.requireCompleteListing(extras != null && extras.getBoolean(DocumentsContract.EXTRA_LOADING, false),
            extras != null && extras.containsKey(DocumentsContract.EXTRA_ERROR));
    }
    private static void requireSameTree(Uri parent, Uri child) throws IOException {
        if (!ContentResolver.SCHEME_CONTENT.equals(child.getScheme()) || !DocumentsContract.isTreeUri(child)
                || !parent.getAuthority().equals(child.getAuthority()) || child.getQuery() != null || child.getFragment() != null
                || !DocumentsContract.getTreeDocumentId(parent).equals(DocumentsContract.getTreeDocumentId(child))) {
            throw failure("OWNERSHIP_UNPROVEN", "Provider returned a different document tree");
        }
        try { DocumentsContract.getDocumentId(child); }
        catch (IllegalArgumentException e) { throw failure("INVALID_ARGUMENT", "Expected an actual document URI", e); }
    }
    private static void writeAll(ParcelFileDescriptor fd, byte[] bytes) throws ErrnoException, IOException {
        int offset = 0;
        while (offset < bytes.length) {
            int written = Os.write(fd.getFileDescriptor(), bytes, offset, bytes.length - offset);
            if (written <= 0) throw new IOException("Provider stopped writing");
            offset += written;
        }
    }
    private static void verifyMarker(ParcelFileDescriptor fd, byte[] expected) throws ErrnoException, IOException {
        if (Os.fstat(fd.getFileDescriptor()).st_size != expected.length) throw failure("OWNERSHIP_UNPROVEN", "Document content length changed");
        Os.lseek(fd.getFileDescriptor(), 0, OsConstants.SEEK_SET);
        byte[] actual = new byte[expected.length];
        int offset = 0;
        while (offset < actual.length) {
            int count = Os.read(fd.getFileDescriptor(), actual, offset, actual.length - offset);
            if (count <= 0) throw failure("OWNERSHIP_UNPROVEN", "Document content is unavailable");
            offset += count;
        }
        if (!Arrays.equals(actual, expected)) throw failure("OWNERSHIP_UNPROVEN", "Document ownership marker changed");
    }
    private static JSONObject proof(String value, String identity) throws IOException {
        try {
            JSONObject result = new JSONObject(identity);
            if ((result.getInt("version") != 1 && result.getInt("version") != 2) || !value.equals(result.getString("uri"))) throw new IOException("Ownership proof mismatch");
            return result;
        } catch (JSONException | NullPointerException e) { throw new IOException("Invalid ownership proof", e); }
    }
    private static String get(JSONObject value, String key) throws IOException {
        try { return value.getString(key); } catch (JSONException e) { throw new IOException(e); }
    }
    private static SafDirectoryResolver.Failure failure(String code, String message) { return new SafDirectoryResolver.Failure(code, message); }
    private static IOException failure(String code, String message, Exception cause) {
        IOException error = failure(code, message); error.initCause(cause); return error;
    }
}
