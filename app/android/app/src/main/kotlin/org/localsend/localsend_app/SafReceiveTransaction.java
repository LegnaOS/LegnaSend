package org.localsend.localsend_app;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/** Durable SAF receive ownership and publication state machine. Original wire bytes stay unchanged. */
public final class SafReceiveTransaction {
    public enum State { PREPARING, READY, LEASED, RECEIVING, VERIFIED, PUBLISHING, PUBLICATION_FAILED, PUBLISHED, ABORT_PENDING, ABORTED }
    public static final class Failure extends IOException {
        private static final long serialVersionUID = 1L;
        public final String code;
        public Failure(String code, String message) { super(message); this.code = code; }
    }
    /** Publication may have succeeded; retain output until explicit reconciliation. */
    public static final class PublicationUncertain extends IOException {
        private static final long serialVersionUID = 1L;
        public PublicationUncertain(String message) { super(message); }
        public PublicationUncertain(String message, Throwable cause) { super(message, cause); }
    }
    public static final class Document {
        public final String uri;
        public final String identity;
        public Document(String uri, String identity) { this.uri = uri; this.identity = identity; }
    }
    /** Journals must persist a snapshot, never retain this mutable object by reference. */
    public static final class Record {
        public final String id, tree, parent, desiredName, sessionId, fileId, attemptId;
        public State state;
        public Document cache, staging, output;
        public long size = -1;
        public String sha256, coreAttempt, recoveryIdentity;
        public String recoverySourceId, recoveryClaimId, recoverySupersededBy;
        public boolean recoveryCompleted, recoveryRejected;
        public long recoveryLength = -1;
        public String recoverySha256;
        public boolean receiveReleased, stagingCleanupPending;
        public String lease;
        public Record(String id, String tree, String parent, String desiredName, String sessionId, String fileId, String attemptId) {
            this.id = id; this.tree = tree; this.parent = parent; this.desiredName = desiredName;
            this.sessionId = sessionId; this.fileId = fileId; this.attemptId = attemptId; state = State.PREPARING;
        }
        public Record copy() {
            Record copy = new Record(id, tree, parent, desiredName, sessionId, fileId, attemptId);
            copy.state = state; copy.cache = cache; copy.staging = staging; copy.lease = lease;
            copy.recoveryIdentity = recoveryIdentity;
            copy.recoverySourceId = recoverySourceId; copy.recoveryClaimId = recoveryClaimId;
            copy.recoverySupersededBy = recoverySupersededBy; copy.recoveryCompleted = recoveryCompleted; copy.recoveryRejected = recoveryRejected;
            copy.recoveryLength = recoveryLength; copy.recoverySha256 = recoverySha256;
            copy.stagingCleanupPending = stagingCleanupPending;
            copy.output = output; copy.size = size; copy.sha256 = sha256; copy.coreAttempt = coreAttempt; copy.receiveReleased = receiveReleased;
            return copy;
        }
    }
    /** Parsed by the platform JSON adapter, validated without Android dependencies. */
    public static final class CacheIdentity {
        public final String json, taskId, sourceId, resourceId, version, fileName, sha256;
        public final long size, chunkSize, createdUnixMs;
        public CacheIdentity(String json, String taskId, String sourceId, String resourceId, String version,
                String fileName, long size, long chunkSize, long createdUnixMs, String sha256) {
            this.json = json; this.taskId = taskId; this.sourceId = sourceId; this.resourceId = resourceId;
            this.version = version; this.fileName = fileName; this.size = size; this.chunkSize = chunkSize;
            this.createdUnixMs = createdUnixMs; this.sha256 = sha256;
        }
        void validate(String transactionId) throws IOException {
            if (json == null || json.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 16384
                    || !transactionId.equals(taskId) || size < 1048576L || size > 1099511627776L || chunkSize != 1048576L
                    || createdUnixMs <= 0 || createdUnixMs > 9007199254740991L
                    || sha256 == null || !sha256.matches("[0-9a-f]{64}")
                    || !sha256.equals(resourceId) || !sha256.equals(version)
                    || fileName == null || fileName.isEmpty() || fileName.indexOf('\0') >= 0
                    || fileName.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > 4096 || !validSource(sourceId)) {
                throw new Failure("INVALID_ARGUMENT", "Invalid stable receive cache identity");
            }
        }
        private static boolean validSource(String source) {
            if (source == null) return false;
            if (source.matches("cert:[0-9a-fA-F]{64}")) return true;
            if (!source.startsWith("http:")) return false;
            String ip = source.substring(5);
            if (!ip.contains(":")) {
                String[] parts = ip.split("\\.", -1);
                if (parts.length != 4) return false;
                for (String part : parts) {
                    if (!part.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(part) > 255) return false;
                }
                return true;
            }
            String[] scoped = ip.split("%", -1);
            if (scoped.length > 2 || (scoped.length == 2 && !scoped[1].matches("[1-9][0-9]{0,9}"))
                    || !scoped[0].matches("[0-9a-fA-F:.]+")) return false;
            if (scoped.length == 2 && Long.parseLong(scoped[1]) > 4294967295L) return false;
            try { java.net.InetAddress.getByName(scoped[0]); return true; }
            catch (java.net.UnknownHostException invalid) { return false; }
        }
    }
    public interface Backend {
        /** Revalidate read/write authorization and actual parent membership. */
        void authorize(String tree, String parent) throws IOException;
        /** Return the actual provider URI. Do not derive a document ID from its name. */
        String create(String parent, String randomName) throws IOException;
        /** Establish durable ownership evidence, excluding every pre-existing document. */
        String identity(String actualUri) throws IOException;
        /** Validate read/write, seek, length and exclusive lock without destroying ownership evidence. */
        void probe(String actualUri, String identity) throws IOException;
        /** Revalidate authorization and evidence immediately before deletion. False means retain. */
        boolean deleteOwned(String tree, String parent, String actualUri, String identity) throws IOException;
        default CacheIdentity parseCacheIdentity(String json) throws IOException { throw unsupported(); }
        default void validateIdentityBinding(Record record, boolean requireEmpty) throws IOException { throw unsupported(); }
        default void prepareReceive(Record record) throws IOException { throw unsupported(); }
        default void verifyStaging(Record record, long size, String sha256) throws IOException { throw unsupported(); }
        default String createPublication(Record record) throws IOException { throw unsupported(); }
        default String publicationIdentity(Record record, String uri) throws IOException { throw unsupported(); }
        default void copyPublication(Record record, long size, String sha256) throws IOException { throw unsupported(); }
        /** Delete only a freshly owned output whose copy explicitly failed; never an ambiguous receipt. */
        default boolean deleteFailedPublication(Record record) throws IOException { return false; }
        /** Caller has closed all Rust handles. Backend must reject still-active writers. */
        default void releaseReceive(Record record) throws IOException { throw unsupported(); }
        /** Drop platform ownership references only after release proved all core writers have stopped. */
        default void closeReceive(Record record) throws IOException {}
        static Failure unsupported() { return new Failure("CAPABILITY_UNSUPPORTED", "Receive publication is not implemented by this provider"); }
    }
    public interface Journal {
        void save(Record record) throws IOException;
        Record load(String transactionId) throws IOException;
        void remove(String transactionId) throws IOException;
    }
    public static final class AbortResult {
        public final String transactionId;
        public final List<String> deleted;
        public final List<String> retained;
        public final List<String> reasons;
        public final boolean complete;
        AbortResult(String id, List<String> deleted, List<String> retained, List<String> reasons, boolean complete) {
            transactionId = id; this.deleted = Collections.unmodifiableList(new ArrayList<>(deleted));
            this.retained = Collections.unmodifiableList(new ArrayList<>(retained));
            this.reasons = Collections.unmodifiableList(new ArrayList<>(reasons)); this.complete = complete;
        }
    }
    private final Backend backend;
    private final Journal journal;
    public SafReceiveTransaction(Backend backend, Journal journal) { this.backend = backend; this.journal = journal; }

    public synchronized Record begin(String tree, String parent, String desiredName, String sessionId, String fileId, String attemptId) throws IOException {
        require(tree); require(parent); require(sessionId); require(fileId); require(attemptId);
        SafDirectoryResolver.validateName(desiredName);
        backend.authorize(tree, parent);
        Record record = new Record(UUID.randomUUID().toString(), tree, parent, desiredName, sessionId, fileId, attemptId);
        journal.save(record.copy()); // No provider mutation without an initial durable record.
        try {
            prepare(record, true);
            prepare(record, false);
            record.state = State.READY;
            journal.save(record.copy());
            return record.copy();
        } catch (IOException | RuntimeException error) {
            // Preserve the primary capability failure; cleanup errors are secondary evidence.
            try { abortRecord(record); } catch (IOException | RuntimeException cleanup) { error.addSuppressed(cleanup); }
            throw error;
        }
    }
    private void prepare(Record record, boolean cache) throws IOException {
        backend.authorize(record.tree, record.parent);
        String uri = backend.create(record.parent, ".legnasend-receive-" + record.id + (cache ? ".ls" : ".part"));
        if (uri == null || uri.isEmpty()) throw new Failure("CREATE_FAILED", "Provider did not return a document");
        if (!cache && record.cache != null && uri.equals(record.cache.uri)) {
            // The returned URI is already durably recorded with its original proof.
            // Never initialize a second marker or overwrite that proof through an alias.
            throw new Failure("DOCUMENT_ALIAS", "Provider reused the cache document for staging");
        }
        Document document = new Document(uri, null);
        if (cache) record.cache = document; else record.staging = document;
        journal.save(record.copy()); // Account for created documents even if opening or proving ownership fails.
        String identity = backend.identity(uri);
        if (identity == null || identity.isEmpty()) throw new Failure("OWNERSHIP_UNPROVEN", "Document ownership is not established");
        document = new Document(uri, identity);
        if (cache) record.cache = document; else record.staging = document;
        journal.save(record.copy());
        backend.probe(uri, identity);
    }
    /** Future handoff gate. No descriptors are transferred by this foundation API. */
    public synchronized String acquireLease(String id, String sessionId, String fileId, String attemptId) throws IOException {
        Record record = requiredRecord(id);
        if (record.state != State.READY || record.lease != null || !record.sessionId.equals(sessionId)
                || !record.fileId.equals(fileId) || !record.attemptId.equals(attemptId)) {
            throw new Failure("STALE_HANDOFF", "Transaction is not available for this receive attempt");
        }
        backend.authorize(record.tree, record.parent);
        record.lease = UUID.randomUUID().toString(); record.state = State.LEASED;
        journal.save(record.copy());
        return record.lease;
    }
    /** Caller must first close every writer. A stale lease cannot release a newer lease. */
    public synchronized void releaseLease(String id, String lease) throws IOException {
        Record record = requiredRecord(id);
        if (record.state != State.LEASED || lease == null || !Objects.equals(record.lease, lease)) {
            throw new Failure("STALE_HANDOFF", "Lease does not own this transaction");
        }
        record.lease = null; record.state = State.READY; journal.save(record.copy());
    }
    /** Persist the writer lease before removing probe markers or offering descriptors. */
    public synchronized Record openReceive(String id, String sessionId, String fileId, String attemptId) throws IOException {
        String lease = acquireLease(id, sessionId, fileId, attemptId);
        try {
            Record record = requiredRecord(id);
            record.state = State.RECEIVING;
            journal.save(record.copy());
            backend.prepareReceive(record);
            journal.save(record.copy());
            return record.copy();
        } catch (IOException | RuntimeException error) {
            try { abortReceiving(id, lease); } catch (IOException | RuntimeException cleanup) { error.addSuppressed(cleanup); }
            throw error;
        }
    }
    /** Persist the complete core identity before its first header/body write. */
    public synchronized void bindCacheIdentity(String id, String lease, String coreAttempt, String json) throws IOException {
        require(coreAttempt);
        Record record = leasedRecord(id, lease);
        if (record.state != State.RECEIVING || record.receiveReleased) {
            throw new Failure("STALE_HANDOFF", "Receive is not available for identity binding");
        }
        CacheIdentity identity = backend.parseCacheIdentity(json);
        identity.validate(record.id);
        if (record.recoveryIdentity != null) {
            if (!record.recoveryIdentity.equals(identity.json) || !coreAttempt.equals(record.coreAttempt)
                    || record.size != identity.size || !identity.sha256.equals(record.sha256)) {
                throw new Failure("STALE_HANDOFF", "Receive identity is already bound to a different attempt or content");
            }
            backend.authorize(record.tree, record.parent);
            backend.validateIdentityBinding(record.copy(), false);
            return;
        }
        if (record.coreAttempt != null || record.output != null) throw new Failure("STALE_HANDOFF", "Publication identity is already bound");
        backend.authorize(record.tree, record.parent);
        backend.validateIdentityBinding(record.copy(), true);
        record.recoveryIdentity = identity.json; record.coreAttempt = coreAttempt;
        record.size = identity.size; record.sha256 = identity.sha256;
        journal.save(record.copy());
    }
    /** Called under the platform's private recovery-index lock. No provider mutation. */
    public synchronized boolean claimRecovery(String id, String lease, String attempt, String sourceId, long now) throws IOException {
        Record target = bindingRecord(id, lease, attempt), source = requiredRecord(sourceId);
        if (id.equals(sourceId) || target.recoverySourceId != null || source.recoveryClaimId != null
                || source.recoverySupersededBy != null || source.recoveryRejected || source.state != State.RECEIVING || source.receiveReleased
                || source.output != null || source.cache == null || source.recoveryIdentity == null || source.coreAttempt == null
                || !target.tree.equals(source.tree) || !target.parent.equals(source.parent)
                || !target.desiredName.equals(source.desiredName)) return false;
        CacheIdentity oldIdentity = backend.parseCacheIdentity(source.recoveryIdentity);
        CacheIdentity newIdentity = backend.parseCacheIdentity(target.recoveryIdentity);
        oldIdentity.validate(source.id); newIdentity.validate(target.id);
        if (source.size != oldIdentity.size || !Objects.equals(source.sha256, oldIdentity.sha256)
                || now < oldIdentity.createdUnixMs || now - oldIdentity.createdUnixMs >= 86400000L
                || !oldIdentity.sourceId.equals(newIdentity.sourceId) || !oldIdentity.resourceId.equals(newIdentity.resourceId)
                || !oldIdentity.version.equals(newIdentity.version) || oldIdentity.size != newIdentity.size
                || !oldIdentity.sha256.equals(newIdentity.sha256) || oldIdentity.chunkSize != newIdentity.chunkSize) return false;
        // Two AtomicFile records cannot be committed as one filesystem operation.
        // Persist exclusion first; a crash half-way conservatively keeps the old claim.
        source.recoveryClaimId = id; journal.save(source.copy());
        target.recoverySourceId = sourceId;
        try { journal.save(target.copy()); }
        catch (IOException | RuntimeException error) {
            source.recoveryClaimId = null;
            try { journal.save(source.copy()); } catch (IOException | RuntimeException rollback) { error.addSuppressed(rollback); }
            throw error;
        }
        return true;
    }
    public synchronized boolean hasProtectedRecovery(String id, String sourceId, long now) throws IOException {
        Record target = requiredRecord(id), source = requiredRecord(sourceId);
        if (id.equals(sourceId) || source.state == State.PUBLISHED || source.recoveryIdentity == null || target.recoveryIdentity == null
                || !target.tree.equals(source.tree) || !target.parent.equals(source.parent) || !target.desiredName.equals(source.desiredName)
                || (source.output == null && source.state != State.PUBLISHING)) return false;
        CacheIdentity oldIdentity = backend.parseCacheIdentity(source.recoveryIdentity), current = backend.parseCacheIdentity(target.recoveryIdentity);
        oldIdentity.validate(source.id); current.validate(target.id);
        return now >= oldIdentity.createdUnixMs && now - oldIdentity.createdUnixMs < 86400000L
            && oldIdentity.sourceId.equals(current.sourceId) && oldIdentity.resourceId.equals(current.resourceId)
            && oldIdentity.version.equals(current.version) && oldIdentity.sha256.equals(current.sha256) && oldIdentity.size == current.size;
    }
    private Record bindingRecord(String id, String lease, String attempt) throws IOException {
        Record target = leasedRecord(id, lease);
        if (target.state != State.RECEIVING || target.receiveReleased || !Objects.equals(target.coreAttempt, attempt)
                || target.recoveryIdentity == null || target.output != null)
            throw new Failure("STALE_HANDOFF", "Recovery target is no longer the approved receive attempt");
        return target;
    }
    public synchronized void completeRecovery(String id, String lease, String attempt, String sourceId, long sourceLength, String sourceSha256) throws IOException {
        validateRecoveryProof(sourceLength, sourceSha256);
        Record target = bindingRecord(id, lease, attempt), source = requiredRecord(sourceId);
        if (!Objects.equals(target.recoverySourceId, sourceId) || !Objects.equals(source.recoveryClaimId, id)
                || (source.recoverySupersededBy != null && !id.equals(source.recoverySupersededBy)))
            throw new Failure("STALE_HANDOFF", "Recovery claim differs");
        if (source.recoveryLength != -1 || source.recoverySha256 != null) {
            if (source.recoveryLength != sourceLength || !Objects.equals(source.recoverySha256, sourceSha256))
                throw new Failure("STALE_HANDOFF", "Recovery container proof differs");
        }
        if (target.recoveryCompleted && id.equals(source.recoverySupersededBy)) return;
        source.recoveryLength = sourceLength; source.recoverySha256 = sourceSha256;
        source.recoverySupersededBy = id; journal.save(source.copy());
        target.recoveryCompleted = true; journal.save(target.copy());
    }
    static void validateRecoveryProof(long length, String sha256) throws IOException {
        // Includes header and any uncommitted tail, not the original file size.
        if (length < 49 || length > 2199023255552L || sha256 == null || !sha256.matches("[0-9a-f]{64}"))
            throw new Failure("INVALID_ARGUMENT", "Invalid recovery container proof");
    }
    /** This only validates the journal authority; caller must hold the real core cleanup lock. */
    public synchronized Record recoveryCleanupSource(String id, String lease, String sourceId) throws IOException {
        Record target = leasedRecord(id, lease);
        if (target.state != State.PUBLISHED || !target.recoveryCompleted || target.recoverySourceId == null
                || (sourceId != null && !target.recoverySourceId.equals(sourceId)))
            throw new Failure("STALE_HANDOFF", "Recovery target has no durable published receipt");
        Record source = requiredRecord(target.recoverySourceId);
        if (!id.equals(source.recoveryClaimId) || !id.equals(source.recoverySupersededBy) || source.output != null
                || source.state != State.RECEIVING || source.receiveReleased)
            throw new Failure("STALE_HANDOFF", "Recovery cleanup lineage differs");
        validateRecoveryProof(source.recoveryLength, source.recoverySha256);
        CacheIdentity oldIdentity = backend.parseCacheIdentity(source.recoveryIdentity), identity = backend.parseCacheIdentity(target.recoveryIdentity);
        oldIdentity.validate(source.id); identity.validate(target.id);
        if (!source.tree.equals(target.tree) || !source.parent.equals(target.parent) || !source.desiredName.equals(target.desiredName)
                || !oldIdentity.sourceId.equals(identity.sourceId) || !oldIdentity.sha256.equals(identity.sha256)
                || oldIdentity.size != identity.size || source.size != oldIdentity.size || !oldIdentity.sha256.equals(source.sha256)
                || target.size != identity.size || !identity.sha256.equals(target.sha256)
                || target.output == null)
            throw new Failure("STALE_HANDOFF", "Published recovery content or target differs");
        return source.copy();
    }
    /** Only a proven drained failed target may release its matching source claim. */
    public synchronized void releaseRecoveryClaim(Record target) throws IOException { releaseRecoveryClaim(target, false); }
    public synchronized void releaseRecoveryClaim(Record target, boolean rejectCandidate) throws IOException {
        if (target.recoverySourceId == null || target.state == State.PUBLISHED || target.state == State.PUBLISHING || target.output != null) return;
        Record source = journal.load(target.recoverySourceId);
        if (source == null || !target.id.equals(source.recoveryClaimId)) return;
        if (source.recoverySupersededBy != null && !target.id.equals(source.recoverySupersededBy)) return;
        source.recoveryClaimId = null; source.recoverySupersededBy = null;
        source.recoveryLength = -1; source.recoverySha256 = null;
        if (rejectCandidate) source.recoveryRejected = true;
        journal.save(source.copy());
        Record current = journal.load(target.id);
        if (current != null && Objects.equals(current.recoverySourceId, source.id)) {
            current.recoverySourceId = null; current.recoveryCompleted = false; journal.save(current.copy());
        }
    }
    /** Only a completed, released receipt may retire its independently verified staging document. */
    public synchronized Record publishedStagingCandidate(String id) throws IOException {
        requireTransactionId(id);
        Record record = journal.load(id);
        if (record == null) return null;
        verifyRecordId(id, record);
        if (record.state != State.PUBLISHED || !record.receiveReleased || record.stagingCleanupPending
                || record.staging == null || record.staging.uri == null || record.staging.uri.isEmpty()
                || record.staging.identity == null || record.staging.identity.isEmpty()
                || record.output == null || record.output.uri == null || record.output.uri.isEmpty()
                || record.output.identity == null || record.output.identity.isEmpty()
                || record.staging.uri.equals(record.output.uri)
                || (record.cache != null && (record.staging.uri.equals(record.cache.uri) || record.output.uri.equals(record.cache.uri)))
                || record.size < 0 || record.sha256 == null || !record.sha256.matches("[0-9a-f]{64}")
                || record.coreAttempt == null || record.coreAttempt.isEmpty()) return null;
        return record.copy();
    }
    @FunctionalInterface public interface PublishedStagingValidate { void validate(Record pending) throws IOException; }
    @FunctionalInterface public interface PublishedStagingDelete { boolean delete(Record pending) throws IOException; }
    public static final class StagingCleanupResult {
        public final boolean deleted, recorded;
        StagingCleanupResult(boolean deleted, boolean recorded) { this.deleted = deleted; this.recorded = recorded; }
    }
    /** The adapter keeps the strict core EX guard and revalidates all documents in the callback. */
    public synchronized StagingCleanupResult deletePublishedStaging(Record expected, PublishedStagingValidate validate, PublishedStagingDelete delete) throws IOException {
        Record current = publishedStagingCandidate(expected.id);
        if (current == null || !samePublicationRecord(current, expected))
            throw new Failure("STALE_HANDOFF", "Published staging evidence changed");
        // Persist an intent before the non-transactional provider mutation. Crash,
        // provider exception or failed acknowledgement retains an ambiguous intent,
        // never a second automatic deletion or duplicate success count.
        current.stagingCleanupPending = true;
        journal.save(current.copy());
        try { validate.validate(current.copy()); }
        catch (IOException | RuntimeException beforeProviderCall) {
            // No delete call was made: a permission/identity/stamp failure may be
            // retried after recovery, but only if clearing its intent is durable.
            current.stagingCleanupPending = false;
            try { journal.save(current.copy()); }
            catch (IOException | RuntimeException uncertain) { beforeProviderCall.addSuppressed(uncertain); }
            throw beforeProviderCall;
        }
        // From here on an exception may hide a committed provider mutation.
        boolean deleted = delete.delete(current.copy());
        current.stagingCleanupPending = false;
        if (!deleted) { journal.save(current.copy()); return new StagingCleanupResult(false, true); }
        current.staging = null;
        try { journal.save(current.copy()); return new StagingCleanupResult(true, true); }
        catch (IOException | RuntimeException uncertain) { return new StagingCleanupResult(true, false); }
    }
    /** Private receipt evidence only: provider access and no-live checks belong to the adapter. */
    public synchronized Record publicationReconcileCandidate(String id) throws IOException {
        requireTransactionId(id);
        Record record = journal.load(id);
        if (record == null) return null;
        verifyRecordId(id, record);
        if (record.state != State.PUBLISHING || record.output == null || record.output.uri == null || record.output.uri.isEmpty()
                || record.output.identity == null || record.output.identity.isEmpty() || record.size < 0
                || record.sha256 == null || !record.sha256.matches("[0-9a-f]{64}")
                || record.coreAttempt == null || record.coreAttempt.isEmpty()
                || (record.cache != null && record.output.uri.equals(record.cache.uri))
                || (record.staging != null && record.output.uri.equals(record.staging.uri))) return null;
        return record.copy();
    }
    /** Trusted adapter has revalidated the pinned output while the core full-hash SH guard remains held. */
    public synchronized Record confirmPublicationReconcile(Record expected) throws IOException {
        Record current = publicationReconcileCandidate(expected.id);
        if (current == null || !samePublicationRecord(current, expected))
            throw new Failure("STALE_PUBLICATION", "Publication evidence changed during reconciliation");
        // No lease is reissued and no writable descriptor is reopened. Keep the old
        // private lease solely for existing migrated-cache cleanup lineage checks.
        current.state = State.PUBLISHED;
        current.receiveReleased = true;
        journal.save(current.copy());
        return current.copy();
    }
    private static boolean sameDocument(Document a, Document b) {
        return a == b || (a != null && b != null && Objects.equals(a.uri, b.uri) && Objects.equals(a.identity, b.identity));
    }
    static boolean samePublicationRecord(Record a, Record b) {
        return a.state == b.state && Objects.equals(a.id, b.id) && Objects.equals(a.tree, b.tree)
            && Objects.equals(a.parent, b.parent) && Objects.equals(a.desiredName, b.desiredName)
            && Objects.equals(a.sessionId, b.sessionId) && Objects.equals(a.fileId, b.fileId) && Objects.equals(a.attemptId, b.attemptId)
            && sameDocument(a.output, b.output) && sameDocument(a.cache, b.cache) && sameDocument(a.staging, b.staging)
            && a.size == b.size && Objects.equals(a.sha256, b.sha256) && Objects.equals(a.coreAttempt, b.coreAttempt)
            && Objects.equals(a.lease, b.lease) && a.receiveReleased == b.receiveReleased && a.stagingCleanupPending == b.stagingCleanupPending
            && Objects.equals(a.recoveryIdentity, b.recoveryIdentity) && Objects.equals(a.recoverySourceId, b.recoverySourceId)
            && Objects.equals(a.recoveryClaimId, b.recoveryClaimId) && Objects.equals(a.recoverySupersededBy, b.recoverySupersededBy)
            && a.recoveryCompleted == b.recoveryCompleted && a.recoveryRejected == b.recoveryRejected
            && a.recoveryLength == b.recoveryLength && Objects.equals(a.recoverySha256, b.recoverySha256);
    }
    /** A matching durable receipt is idempotent; ambiguous in-flight publication is never repeated. */
    public synchronized Record publish(String id, String lease, String coreAttempt, long size, String sha256) throws IOException {
        require(coreAttempt);
        if (size < 0 || sha256 == null || !sha256.matches("[0-9a-fA-F]{64}")) {
            throw new Failure("INVALID_ARGUMENT", "Invalid verified content identity");
        }
        sha256 = sha256.toLowerCase(java.util.Locale.ROOT);
        Record record = leasedRecord(id, lease);
        if (record.state == State.PUBLISHED) {
            if (!coreAttempt.equals(record.coreAttempt) || size != record.size || !sha256.equals(record.sha256)) {
                throw new Failure("STALE_PUBLICATION", "Publication receipt belongs to different content or attempt");
            }
            return record.copy();
        }
        if (record.state != State.RECEIVING || record.receiveReleased) {
            throw new Failure("STALE_PUBLICATION", "Transaction is not available for publication");
        }
        if (record.coreAttempt != null && (!coreAttempt.equals(record.coreAttempt) || size != record.size || !sha256.equals(record.sha256))) {
            throw new Failure("STALE_PUBLICATION", "Receive lease is already bound to different content or attempt");
        }
        // Bind the trusted core request before verification; a failed request cannot be retargeted.
        record.coreAttempt = coreAttempt; record.size = size; record.sha256 = sha256;
        journal.save(record.copy());
        backend.authorize(record.tree, record.parent);
        backend.verifyStaging(record.copy(), size, sha256);
        record.state = State.VERIFIED; journal.save(record.copy());
        record.state = State.PUBLISHING; journal.save(record.copy());
        String uri = backend.createPublication(record.copy());
        if (uri == null || uri.isEmpty()) throw new Failure("CREATE_FAILED", "Provider returned no output document");
        record.output = new Document(uri, null);
        journal.save(record.copy()); // Account for actual output even if ownership/open/copy fails.
        if (uri.equals(record.cache.uri) || uri.equals(record.staging.uri)) {
            throw new Failure("DOCUMENT_ALIAS", "Provider returned a receive-cache document as final output");
        }
        String identity = backend.publicationIdentity(record.copy(), uri);
        if (identity == null || identity.isEmpty()) throw new Failure("OWNERSHIP_UNPROVEN", "Final output ownership is unproven");
        record.output = new Document(uri, identity); journal.save(record.copy());
        try {
            backend.copyPublication(record.copy(), size, sha256);
        } catch (PublicationUncertain uncertain) {
            throw uncertain; // Keep durable PUBLISHING: close/reopen outcome is not an explicit failed copy.
        } catch (IOException | RuntimeException error) {
            // Only an explicit copy/verification failure is eligible for owned-output cleanup.
            // Once copy returned, a failed receipt write is ambiguous and must remain protected.
            record.state = State.PUBLICATION_FAILED;
            try { journal.save(record.copy()); } catch (IOException | RuntimeException persistence) { error.addSuppressed(persistence); }
            throw error;
        }
        record.state = State.PUBLISHED; journal.save(record.copy());
        return record.copy();
    }
    /** Successful publication remains successful even when leftover removal is deferred. */
    public synchronized AbortResult finalizeReceive(String id, String lease) throws IOException {
        Record record = leasedRecord(id, lease);
        if (record.state != State.PUBLISHED) throw new Failure("STALE_PUBLICATION", "No durable publication receipt");
        if (!record.receiveReleased) backend.releaseReceive(record.copy());
        try {
            record.receiveReleased = true; journal.save(record.copy());
            return cleanupDocuments(record, true);
        } finally {
            backend.closeReceive(record.copy());
        }
    }
    /** Called only after the receiving core has released its owned descriptors. */
    public synchronized AbortResult abortReceiving(String id, String lease) throws IOException {
        Record record = leasedRecord(id, lease);
        if (record.state == State.PUBLISHED) return finalizeReceive(id, lease);
        if (!record.receiveReleased) backend.releaseReceive(record.copy());
        try {
            record.receiveReleased = true; journal.save(record.copy());
            if (record.state == State.PUBLICATION_FAILED) return cleanupDocuments(record, false, true);
            if (record.state == State.PUBLISHING || record.output != null) {
                // A provider mutation may already have succeeded. Retain output and journal for reconciliation.
                List<String> retained = new ArrayList<>();
                if (record.cache != null) retained.add(record.cache.uri);
                if (record.staging != null) retained.add(record.staging.uri);
                if (record.output != null) retained.add(record.output.uri);
                return new AbortResult(id, Collections.emptyList(), retained, Collections.singletonList("PUBLICATION_AMBIGUOUS"), false);
            }
            record.lease = null;
            return abortRecord(record);
        } finally {
            // Revoked grants or changed documents must not keep unbounded process-owned descriptors alive.
            backend.closeReceive(record.copy());
        }
    }
    private Record leasedRecord(String id, String lease) throws IOException {
        Record record = requiredRecord(id);
        if (lease == null || !lease.equals(record.lease)) throw new Failure("STALE_HANDOFF", "Lease does not own this transaction");
        return record;
    }
    public synchronized AbortResult abort(String id) throws IOException {
        requireTransactionId(id);
        Record record = journal.load(id);
        if (record == null) return new AbortResult(id, Collections.emptyList(), Collections.emptyList(), Collections.emptyList(), true);
        verifyRecordId(id, record);
        return abortRecord(record);
    }
    private AbortResult abortRecord(Record record) throws IOException {
        List<String> retained = new ArrayList<>(), reasons = new ArrayList<>();
        if (record.lease != null || record.state == State.LEASED) {
            if (record.cache != null) retained.add(record.cache.uri);
            if (record.staging != null) retained.add(record.staging.uri);
            reasons.add("ACTIVE_LEASE");
            return new AbortResult(record.id, Collections.emptyList(), retained, reasons, false);
        }
        if (record.state == State.PUBLISHING || record.state == State.PUBLISHED || record.output != null) {
            if (record.output != null) retained.add(record.output.uri);
            reasons.add("PUBLICATION_PROTECTED");
            return new AbortResult(record.id, Collections.emptyList(), retained, reasons, false);
        }
        return cleanupDocuments(record, false);
    }
    private AbortResult cleanupDocuments(Record record, boolean published) throws IOException {
        return cleanupDocuments(record, published, false);
    }
    private AbortResult cleanupDocuments(Record record, boolean published, boolean failedPublication) throws IOException {
        List<String> retained = new ArrayList<>(), reasons = new ArrayList<>();
        if (!published && !failedPublication) record.state = State.ABORT_PENDING;
        journal.save(record.copy());
        List<String> deleted = new ArrayList<>();
        // Validate the failed output while both cache identity references still exist.
        for (int slot : failedPublication ? new int[] {2, 0, 1} : new int[] {0, 1}) {
            Document document = slot == 0 ? record.cache : slot == 1 ? record.staging : record.output;
            if (document == null) continue;
            if (published && slot == 1) {
                // Published staging now requires the independent core EX/hash
                // guard, after live receive references have fully closed.
                retained.add(document.uri); reasons.add("PUBLISHED_STAGING_CLEANUP_RETAINED"); continue;
            }
            boolean removed = false;
            if (document.identity == null) {
                reasons.add("OWNERSHIP_UNPROVEN");
            } else {
                try {
                    backend.authorize(record.tree, record.parent);
                    removed = slot == 2 ? backend.deleteFailedPublication(record.copy())
                        : backend.deleteOwned(record.tree, record.parent, document.uri, document.identity);
                    if (!removed) reasons.add("OWNERSHIP_CHANGED_OR_UNAVAILABLE");
                } catch (IOException | RuntimeException error) {
                    reasons.add(error instanceof Failure ? ((Failure) error).code
                        : error instanceof SafDirectoryResolver.Failure ? ((SafDirectoryResolver.Failure) error).code : "CLEANUP_FAILED");
                }
            }
            if (removed) {
                deleted.add(document.uri);
                if (slot == 0) record.cache = null; else if (slot == 1) record.staging = null; else record.output = null;
                journal.save(record.copy());
            } else retained.add(document.uri);
        }
        boolean complete = retained.isEmpty();
        if (complete && !published) {
            record.state = State.ABORTED;
            journal.save(record.copy());
            journal.remove(record.id);
        }
        return new AbortResult(record.id, deleted, retained, reasons, complete);
    }
    private Record requiredRecord(String id) throws IOException {
        requireTransactionId(id); Record record = journal.load(id);
        if (record == null) throw new Failure("STALE_HANDOFF", "Unknown transaction");
        verifyRecordId(id, record);
        return record;
    }
    private static void requireTransactionId(String id) throws Failure {
        require(id);
        try {
            if (!UUID.fromString(id).toString().equals(id)) throw new IllegalArgumentException();
        } catch (IllegalArgumentException invalid) {
            throw new Failure("INVALID_ARGUMENT", "Invalid transaction ID");
        }
    }
    private static void verifyRecordId(String id, Record record) throws Failure {
        if (!id.equals(record.id)) throw new Failure("JOURNAL_INVALID", "Journal identity does not match transaction");
    }
    private static void require(String value) throws Failure {
        if (value == null || value.isEmpty() || value.length() > 8192) throw new Failure("INVALID_ARGUMENT", "Missing or oversized transaction identity");
    }
}
