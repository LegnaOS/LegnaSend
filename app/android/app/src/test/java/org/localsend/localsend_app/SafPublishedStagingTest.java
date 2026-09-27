package org.localsend.localsend_app;

import java.io.IOException;
import java.util.UUID;
import java.util.function.Consumer;

/** Portable journal/state checks. No provider or descriptor behavior is simulated as device acceptance. */
public final class SafPublishedStagingTest {
    static int checks;
    static void check(boolean value) { checks++; if (!value) throw new AssertionError(); }
    interface Work { void run() throws IOException; }
    static void fails(Work work) throws IOException {
        try { work.run(); throw new AssertionError("Expected failure"); } catch (IOException expected) { checks++; }
    }
    static final class Fixture implements SafReceiveTransaction.Journal {
        final SafReceiveTransactionTest.Fake backend = new SafReceiveTransactionTest.Fake();
        final SafReceiveTransaction manager = new SafReceiveTransaction(backend, this);
        SafReceiveTransaction.Record record;
        int saves, failSaveAt, deletes;
        Fixture() {
            record = new SafReceiveTransaction.Record(UUID.randomUUID().toString(), "tree", "parent", "name", "session", "file", "attempt");
            record.state = SafReceiveTransaction.State.PUBLISHED; record.receiveReleased = true;
            record.cache = new SafReceiveTransaction.Document("cache", "cache-proof");
            record.staging = new SafReceiveTransaction.Document("staging", "stage-proof");
            record.output = new SafReceiveTransaction.Document("output", "output-proof");
            record.size = 42; record.sha256 = "a".repeat(64); record.coreAttempt = "core"; record.lease = "old-lease";
        }
        public void save(SafReceiveTransaction.Record value) throws IOException {
            if (++saves == failSaveAt) throw new IOException("Journal unavailable");
            record = value.copy();
        }
        public SafReceiveTransaction.Record load(String id) { return record == null || !record.id.equals(id) ? null : record.copy(); }
        public void remove(String id) { throw new AssertionError("Published receipt is permanent"); }
        SafReceiveTransaction.Record candidate() throws IOException { return manager.publishedStagingCandidate(record.id); }
        boolean delete(SafReceiveTransaction.Record pending, boolean outcome) {
            check(record.stagingCleanupPending && pending.stagingCleanupPending);
            check(record.copy().stagingCleanupPending);
            check(record.state == SafReceiveTransaction.State.PUBLISHED && record.receiveReleased);
            check(record.output.uri.equals("output") && record.cache.uri.equals("cache"));
            deletes++; return outcome;
        }
        void noGenericWrites() { check(backend.events.isEmpty() && backend.deletes == 0 && backend.creates == 0); }
    }
    static void ineligible(Consumer<SafReceiveTransaction.Record> mutate) throws IOException {
        Fixture f = new Fixture(); mutate.accept(f.record); check(f.candidate() == null); check(f.saves == 0); f.noGenericWrites();
    }
    static void changed(Consumer<SafReceiveTransaction.Record> mutate) throws IOException {
        Fixture f = new Fixture(); SafReceiveTransaction.Record expected = f.candidate(); mutate.accept(f.record);
        fails(() -> f.manager.deletePublishedStaging(expected, ignored -> {}, pending -> f.delete(pending, true)));
        check(f.deletes == 0 && f.saves == 0); f.noGenericWrites();
    }
    public static void main(String[] args) throws IOException {
        for (SafReceiveTransaction.State state : SafReceiveTransaction.State.values())
            if (state != SafReceiveTransaction.State.PUBLISHED) ineligible(r -> r.state = state);
        ineligible(r -> r.receiveReleased = false); ineligible(r -> r.stagingCleanupPending = true);
        ineligible(r -> r.staging = null); ineligible(r -> r.staging = new SafReceiveTransaction.Document("staging", null));
        ineligible(r -> r.staging = new SafReceiveTransaction.Document("output", "proof"));
        ineligible(r -> r.staging = new SafReceiveTransaction.Document("cache", "proof"));
        ineligible(r -> r.output = new SafReceiveTransaction.Document("cache", "proof"));
        ineligible(r -> r.output = null); ineligible(r -> r.output = new SafReceiveTransaction.Document("output", ""));
        ineligible(r -> r.size = -1); ineligible(r -> r.sha256 = null); ineligible(r -> r.sha256 = "A".repeat(64));
        ineligible(r -> r.coreAttempt = null); ineligible(r -> r.coreAttempt = "");
        changed(r -> r.size++); changed(r -> r.coreAttempt = "other"); changed(r -> r.lease = "other");
        changed(r -> r.sha256 = "b".repeat(64)); changed(r -> r.recoverySourceId = "other");
        changed(r -> r.staging = new SafReceiveTransaction.Document("replacement", "stage-proof"));
        changed(r -> r.staging = new SafReceiveTransaction.Document("staging", "replacement-proof"));
        changed(r -> r.output = new SafReceiveTransaction.Document("replacement-output", "output-proof"));
        changed(r -> r.cache = null); changed(r -> r.stagingCleanupPending = true);
        for (long length : new long[] {0, 42}) {
            Fixture f = new Fixture(); f.record.size = length; SafReceiveTransaction.Record expected = f.candidate();
            SafReceiveTransaction.StagingCleanupResult result = f.manager.deletePublishedStaging(expected, ignored -> {}, p -> f.delete(p, true));
            check(result.deleted && result.recorded); check(f.deletes == 1 && f.saves == 2);
            check(f.record.staging == null && !f.record.stagingCleanupPending && f.record.receiveReleased);
            check(f.record.output == expected.output && f.record.cache == expected.cache && f.record.lease.equals(expected.lease));
            check(f.record.state == SafReceiveTransaction.State.PUBLISHED && f.candidate() == null);
            fails(() -> f.manager.deletePublishedStaging(expected, ignored -> {}, p -> f.delete(p, true))); check(f.deletes == 1); f.noGenericWrites();
        }
        Fixture before = new Fixture(); before.failSaveAt = 1;
        fails(() -> before.manager.deletePublishedStaging(before.candidate(), ignored -> {}, p -> before.delete(p, true)));
        check(before.deletes == 0 && !before.record.stagingCleanupPending); before.noGenericWrites();
        Fixture ack = new Fixture(); ack.failSaveAt = 2; SafReceiveTransaction.Record original = ack.candidate();
        SafReceiveTransaction.StagingCleanupResult deleted = ack.manager.deletePublishedStaging(original, ignored -> {}, p -> ack.delete(p, true));
        check(deleted.deleted && !deleted.recorded); check(ack.deletes == 1 && ack.record.stagingCleanupPending);
        check(ack.record.staging == original.staging && ack.record.output == original.output); check(ack.candidate() == null);
        SafReceiveTransaction restarted = new SafReceiveTransaction(ack.backend, ack);
        check(restarted.publishedStagingCandidate(ack.record.id) == null);
        fails(() -> restarted.deletePublishedStaging(original, ignored -> {}, p -> ack.delete(p, true))); check(ack.deletes == 1); ack.noGenericWrites();
        Fixture revoked = new Fixture();
        fails(() -> revoked.manager.deletePublishedStaging(revoked.candidate(), p -> {
            check(revoked.record.stagingCleanupPending); throw new IOException("Permission revoked before delete");
        }, p -> revoked.delete(p, true)));
        check(!revoked.record.stagingCleanupPending && revoked.candidate() != null && revoked.deletes == 0);
        SafReceiveTransaction retry = new SafReceiveTransaction(revoked.backend, revoked);
        check(retry.publishedStagingCandidate(revoked.record.id) != null);
        check(retry.deletePublishedStaging(revoked.candidate(), p -> {}, p -> revoked.delete(p, true)).deleted);
        check(revoked.deletes == 1); revoked.noGenericWrites();
        Fixture changedBeforeDelete = new Fixture();
        try {
            changedBeforeDelete.manager.deletePublishedStaging(changedBeforeDelete.candidate(), p -> {
                throw new IllegalStateException("Stamp changed before provider call");
            }, p -> changedBeforeDelete.delete(p, true));
            throw new AssertionError("Expected validation failure");
        } catch (IllegalStateException expectedFailure) { checks++; }
        check(!changedBeforeDelete.record.stagingCleanupPending && changedBeforeDelete.deletes == 0);
        check(changedBeforeDelete.candidate() != null); changedBeforeDelete.noGenericWrites();
        Fixture rollbackFailed = new Fixture(); rollbackFailed.failSaveAt = 2;
        fails(() -> rollbackFailed.manager.deletePublishedStaging(rollbackFailed.candidate(), p -> {
            throw new IOException("Grant unavailable");
        }, p -> rollbackFailed.delete(p, true)));
        check(rollbackFailed.record.stagingCleanupPending && rollbackFailed.candidate() == null && rollbackFailed.deletes == 0);
        check(new SafReceiveTransaction(rollbackFailed.backend, rollbackFailed).publishedStagingCandidate(rollbackFailed.record.id) == null);
        rollbackFailed.noGenericWrites();
        Fixture ambiguous = new Fixture();
        fails(() -> ambiguous.manager.deletePublishedStaging(ambiguous.candidate(), ignored -> {}, p -> { ambiguous.delete(p, false); throw new IOException("Provider result unknown"); }));
        check(ambiguous.record.stagingCleanupPending && ambiguous.candidate() == null); ambiguous.noGenericWrites();
        Fixture rejected = new Fixture();
        SafReceiveTransaction.StagingCleanupResult no = rejected.manager.deletePublishedStaging(rejected.candidate(), ignored -> {}, p -> rejected.delete(p, false));
        check(!no.deleted && no.recorded); check(!rejected.record.stagingCleanupPending && rejected.candidate() != null); rejected.noGenericWrites();
        Fixture retryAck = new Fixture(); retryAck.failSaveAt = 2;
        fails(() -> retryAck.manager.deletePublishedStaging(retryAck.candidate(), ignored -> {}, p -> retryAck.delete(p, false)));
        check(retryAck.record.stagingCleanupPending && retryAck.candidate() == null); retryAck.noGenericWrites();
        Fixture missing = new Fixture(); SafReceiveTransaction.Record expected = missing.candidate(); missing.record = null;
        fails(() -> missing.manager.deletePublishedStaging(expected, ignored -> {}, p -> missing.delete(p, true))); check(missing.deletes == 0);
        System.out.println("SAF published staging: " + checks + " assertions passed (host journal/state machine, not provider/device)");
    }
}
